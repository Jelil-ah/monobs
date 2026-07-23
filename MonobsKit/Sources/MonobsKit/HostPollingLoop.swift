import Foundation

protocol HostPollingScheduling: Sendable {
    func nowNanoseconds() -> UInt64
    func schedule(at deadline: UInt64,
                  action: @escaping @Sendable () -> Void)
}

private struct DispatchHostPollingScheduler: HostPollingScheduling {
    let queue: DispatchQueue

    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func schedule(at deadline: UInt64,
                  action: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline),
                         execute: action)
    }
}

/// Owns the application process' polling cadence. One cycle visits every
/// configured host sequentially with an ephemeral SSH connection. The cadence
/// and sequencing remain provisional (Q4.2).
public final class HostPollingLoop: @unchecked Sendable {
    public static let defaultCadence: TimeInterval = 60

    private let hosts: [ObservedHost]
    private let snapshotStore: SnapshotStore
    private let cadence: TimeInterval
    private let pollHost: @Sendable (ObservedHost) -> PollOutcome
    private let now: @Sendable () -> Date
    /// Story 1.4: fired at the end of every cycle so the surface projection can
    /// recompute at the loop's own cadence — no second cadence parameter is
    /// introduced (the 60 s cadence stays the single isolated cadence of 1.3).
    private let onCycleComplete: (@Sendable () -> Void)?
    private let scheduler: any HostPollingScheduling
    private let lock = NSLock()
    private var running = false
    private var generation: UInt64 = 0
    /// Story 3.1 / D-1: `true` while a cycle (planned or manual) is executing on
    /// the serial queue. A refresh arriving while this is `true` is deferred to a
    /// trailing cycle rather than run reentrantly.
    private var cycleExecuting = false
    /// Story 3.1 / D-1: a manual refresh is owed. Coalesces multiple refresh
    /// requests into a single immediate cycle — set true on request, cleared when
    /// the servicing cycle STARTS. Never dropped silently (F-W3 trailing).
    private var immediateCyclePending = false

    public convenience init(
        hosts: [ObservedHost],
        snapshotStore: SnapshotStore,
        cadence: TimeInterval = defaultCadence,
        queue: DispatchQueue = DispatchQueue(label: "monobs.host-polling"),
        now: @escaping @Sendable () -> Date = { Date() },
        pollHost: @escaping @Sendable (ObservedHost) -> PollOutcome = {
            SSHPollRunner.poll(host: $0)
        },
        onCycleComplete: (@Sendable () -> Void)? = nil
    ) {
        self.init(hosts: hosts,
                  snapshotStore: snapshotStore,
                  cadence: cadence,
                  now: now,
                  scheduler: DispatchHostPollingScheduler(queue: queue),
                  pollHost: pollHost,
                  onCycleComplete: onCycleComplete)
    }

    init(hosts: [ObservedHost],
         snapshotStore: SnapshotStore,
         cadence: TimeInterval = defaultCadence,
         now: @escaping @Sendable () -> Date = { Date() },
         scheduler: any HostPollingScheduling,
         pollHost: @escaping @Sendable (ObservedHost) -> PollOutcome = {
             SSHPollRunner.poll(host: $0)
         },
         onCycleComplete: (@Sendable () -> Void)? = nil) {
        precondition(cadence > 0, "poll cadence must be positive")
        self.hosts = hosts
        self.snapshotStore = snapshotStore
        self.cadence = cadence
        self.now = now
        self.scheduler = scheduler
        self.pollHost = pollHost
        self.onCycleComplete = onCycleComplete
    }

    /// Starts with an immediate cycle. Zero configured hosts remain cleanly
    /// idle. Repeated starts are ignored.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        guard !running, !hosts.isEmpty else {
            lock.unlock()
            return false
        }
        running = true
        generation &+= 1
        let activeGeneration = generation
        lock.unlock()
        scheduleCycle(at: scheduler.nowNanoseconds(), generation: activeGeneration)
        return true
    }

    public func stop() {
        lock.lock()
        running = false
        generation &+= 1
        lock.unlock()
    }

    /// Story 3.1 (AD-16) — manual refresh. Closes DEBT.md#D-1: it NEVER calls
    /// `runOneCycle()`/`processCycle` directly from the caller (UI) thread. It
    /// ENQUEUES an immediate cycle on the SAME serial internal queue that cadences
    /// the scheduled poller, so a manual refresh and a scheduled cycle are fully
    /// ORDERED — never two `processCycle` in flight, so no double-emission and no
    /// stale write-back can overwrite a fresher red cycle. The `NSLock` in
    /// `NotificationCoordinator` gives mutual exclusion but NOT ordering; this
    /// serialization is what actually makes AD-16 safe.
    ///
    /// Coalescing (F-W3): if a cycle is already in flight, the refresh is absorbed
    /// into a single TRAILING cycle guaranteed to run AFTER the current one —
    /// multiple requests collapse to one, and none is ever dropped silently (the
    /// operator always gets a fresh poll following their click, AD-16).
    public func requestImmediateCycle() {
        lock.lock()
        if cycleExecuting {
            // A cycle is running on the serial queue: owe a trailing cycle. Reruns
            // of this branch coalesce (the flag is already set).
            immediateCyclePending = true
            lock.unlock()
            return
        }
        if immediateCyclePending {
            // An immediate cycle is already enqueued and waiting on the serial
            // queue — coalesce rather than stack a redundant one.
            lock.unlock()
            return
        }
        immediateCyclePending = true
        lock.unlock()
        enqueueImmediateCycle()
    }

    /// Posts one immediate cycle on the internal serial queue (via the same
    /// `scheduler` seam as the planned cadence), so it is ordered behind any cycle
    /// currently in flight.
    private func enqueueImmediateCycle() {
        scheduler.schedule(at: scheduler.nowNanoseconds()) { [weak self] in
            self?.performCycle()
        }
    }

    /// The single funnel through which every cycle (planned or manual) runs, so
    /// `cycleExecuting` is authoritative and a refresh mid-cycle is always
    /// deferred to a trailing cycle rather than reentered.
    private func performCycle() {
        lock.lock()
        // Any request outstanding at the moment this cycle STARTS is serviced by
        // this cycle (it happens-after the request). Requests arriving during
        // execution set the flag again ⇒ a trailing cycle.
        immediateCyclePending = false
        cycleExecuting = true
        lock.unlock()

        runOneCycle()

        lock.lock()
        cycleExecuting = false
        let owed = immediateCyclePending
        lock.unlock()
        if owed { enqueueImmediateCycle() }
    }

    /// Synchronous cycle seam used by focused tests and future manual refresh.
    public func runOneCycle() {
        for host in hosts {
            let outcome = pollHost(host)
            snapshotStore.record(outcome, forHost: host.host, receivedAt: now())
        }
        // End-of-cycle hook: the surface projection recomputes here, at the
        // loop's cadence (Story 1.4). The reducer/projection stay the single
        // source of derived state — this only signals "a cycle finished".
        onCycleComplete?()
    }

    /// Provisional Q4.2 overrun policy: cycle starts are anchored to monotonic
    /// cadence deadlines. The next tick is enqueued before work begins; when a
    /// cycle overruns one or more deadlines, missed ticks coalesce into one
    /// immediate cycle and the following deadline remains on the original grid.
    private func scheduleCycle(at deadline: UInt64, generation: UInt64) {
        scheduler.schedule(at: deadline) { [weak self] in
            guard let self, self.isRunning(generation: generation) else { return }
            let now = self.scheduler.nowNanoseconds()
            let cadenceNanoseconds = max(1, UInt64(self.cadence * 1_000_000_000))
            let elapsed = now > deadline
                ? now - deadline
                : 0
            let intervalsToNext = elapsed / cadenceNanoseconds + 1
            let nextUptime = deadline
                &+ intervalsToNext &* cadenceNanoseconds
            self.scheduleCycle(at: nextUptime, generation: generation)
            // Route through the shared funnel so `cycleExecuting` is authoritative
            // and a manual refresh arriving mid-cycle is deferred (D-1), never
            // reentered. No refresh outstanding ⇒ behaviour identical to before.
            self.performCycle()
        }
    }

    private func isRunning(generation expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && generation == expected
    }
}
