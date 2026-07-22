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
            self.runOneCycle()
        }
    }

    private func isRunning(generation expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && generation == expected
    }
}
