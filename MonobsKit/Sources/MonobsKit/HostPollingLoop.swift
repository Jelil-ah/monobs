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

    /// CAP-10 / T9: the observed list is no longer fixed at construction — it is
    /// mutable state guarded by `lock`, swapped only from the serial poll-queue
    /// (see `reconfigure(hosts:)`). Every read goes through the lock.
    private var hosts: [ObservedHost]
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
    /// CAP-10 / T9: reconfigurations enqueued on the serial queue and not yet
    /// applied. Only purpose: keep the "identical list ⇒ do nothing" fast path
    /// honest. Comparing a request against `hosts` while another swap is still
    /// in flight would compare against a list that is already obsolete, so the
    /// fast path is disabled while this is non-zero.
    private var pendingReconfigurations = 0
    /// CAP-10 / T9: the list the most recent request wants. Recorded UNDER the
    /// lock so concurrent requests resolve to LAST-WRITER-WINS: two callers
    /// racing could otherwise reach `scheduler.schedule` in the opposite order
    /// and let the older list win permanently.
    private var requestedHosts: [ObservedHost]
    /// CAP-10 / T9: `true` between a `start()` and the matching `stop()` — set
    /// even when `start()` found zero hosts and stayed idle. It is what lets a
    /// reconfiguration introducing the FIRST host activate the cadence (empty
    /// first launch → add a host in-app → polling starts, no relaunch), while
    /// keeping an explicit `stop()` final: a reconfiguration after `stop()`
    /// updates the list but never resurrects the loop.
    private var startRequested = false

    public convenience init(
        hosts: [ObservedHost],
        snapshotStore: SnapshotStore,
        cadence: TimeInterval = defaultCadence,
        now: @escaping @Sendable () -> Date = { Date() },
        pollHost: @escaping @Sendable (ObservedHost) -> PollOutcome = {
            SSHPollRunner.poll(host: $0)
        },
        onCycleComplete: (@Sendable () -> Void)? = nil
    ) {
        // CONTRACT: this queue MUST be serial — a concurrent queue reintroduces
        // DEBT.md#D-1. The no-double-in-flight guarantee rests entirely on
        // serial execution: the `cycleExecuting` gate only holds when at most one
        // `performCycle` runs at a time. It is constructed here (not injected) so
        // the invariant is enforced by construction and cannot be broken silently
        // by a caller passing `.concurrent`. Tests inject a serial-by-construction
        // scheduler through the internal designated init instead.
        let serialQueue = DispatchQueue(label: "monobs.host-polling")
        self.init(hosts: hosts,
                  snapshotStore: snapshotStore,
                  cadence: cadence,
                  now: now,
                  scheduler: DispatchHostPollingScheduler(queue: serialQueue),
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
        self.requestedHosts = hosts
        self.snapshotStore = snapshotStore
        self.cadence = cadence
        self.now = now
        self.scheduler = scheduler
        self.pollHost = pollHost
        self.onCycleComplete = onCycleComplete
    }

    /// The host list the next cycle will visit. A reconfiguration is visible
    /// here only once it has been APPLIED on the serial poll-queue — never
    /// while it is still enqueued, and never mid-cycle.
    public var observedHosts: [ObservedHost] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    /// Starts with an immediate cycle. Zero configured hosts remain cleanly
    /// idle. Repeated starts are ignored.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        guard !running else {
            lock.unlock()
            return false
        }
        // CAP-10: latch the intent BEFORE the empty-list bail. The observable
        // contract is unchanged (zero hosts still returns false and enqueues
        // nothing); the latch only tells a later `reconfigure(hosts:)` that this
        // loop is meant to be polling, so adding the first host starts it.
        startRequested = true
        guard !hosts.isEmpty else {
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
        startRequested = false
        generation &+= 1
        lock.unlock()
    }

    /// CAP-10 — replaces the observed host list while the loop is running.
    ///
    /// SERIALIZATION: this reuses the EXACT mechanism `requestImmediateCycle()`
    /// uses — the swap is ENQUEUED on the same serial `scheduler` seam that
    /// cadences the planned poller. No second mechanism is introduced. Because
    /// that queue is serial (enforced by construction in the convenience init),
    /// the swap is ORDERED with respect to every cycle: it runs strictly between
    /// two cycles, never inside one and never concurrently with one. A cycle in
    /// flight therefore finishes on the list it started with — no half-visited
    /// list, no host polled against a store that has just been purged.
    ///
    /// The list swap and the snapshot purge of the removed hosts happen under
    /// the same critical section, so no reader can observe the new list with the
    /// old residue still in the store.
    ///
    /// Concurrent requests resolve LAST-WRITER-WINS by the order in which they
    /// took the lock — not by the order in which their queue entries happen to
    /// run — so a settings window that fires two edits in quick succession can
    /// never end up pinned to the earlier one.
    ///
    /// A removed host stops being polled at the next cycle and its snapshot is
    /// dropped; an added host enters the next cycle without restarting the app;
    /// an empty list leaves the loop cadencing cleanly with nothing to poll.
    ///
    /// Deliberately does NOT fire `onCycleComplete` and does NOT force a cycle:
    /// that hook is documented as "a poll cycle finished" and its consumer feeds
    /// the rising-edge notification coordinator, which must only ever see real
    /// poll cycles. A caller that wants fresh data immediately after a
    /// reconfiguration calls `requestImmediateCycle()` — the existing, already
    /// serialized path.
    ///
    /// - Returns: `true` if a reconfiguration was enqueued; `false` if the
    ///   requested list is already the observed one and nothing is in flight, in
    ///   which case the loop is left strictly undisturbed (no queue traffic, no
    ///   purge, no cadence change).
    @discardableResult
    public func reconfigure(hosts newHosts: [ObservedHost]) -> Bool {
        lock.lock()
        if pendingReconfigurations == 0, newHosts == hosts {
            lock.unlock()
            return false
        }
        requestedHosts = newHosts
        pendingReconfigurations += 1
        lock.unlock()
        // Same seam, same queue, same ordering guarantees as enqueueImmediateCycle.
        // The block carries no payload: it reads `requestedHosts` when it runs, so
        // the enqueue order below is irrelevant to which list ultimately wins.
        scheduler.schedule(at: scheduler.nowNanoseconds()) { [weak self] in
            self?.applyReconfiguration()
        }
        return true
    }

    /// Runs on the serial poll-queue, so by construction no cycle is executing.
    /// Not gated on the generation: a host list is configuration, not a cycle —
    /// dropping it on a stop/restart would silently lose the operator's edit.
    /// The running-gate is honored for the CADENCE only (see `startRequested`).
    private func applyReconfiguration() {
        lock.lock()
        pendingReconfigurations -= 1
        let target = requestedHosts
        guard target != hosts else {
            // Already there — e.g. an edit undone before either request was
            // applied: nothing to swap, and crucially nothing to purge, so the
            // undone edit costs no snapshot.
            lock.unlock()
            return
        }
        hosts = target
        // Under the SAME lock as the swap: new list and purged store become
        // visible as one transition. Lock order is loop → store and never the
        // reverse (the store never calls back into the loop), so this cannot
        // deadlock.
        snapshotStore.retainOnly(hostIDs: Set(target.map(\.host)))
        // Empty-first-launch activation: `start()` was called but bailed on an
        // empty list, so no cadence exists yet. Adding the first host starts it
        // here. After an explicit `stop()` the latch is false ⇒ the list is
        // updated but the loop stays stopped.
        let shouldActivate = startRequested && !running && !target.isEmpty
        if shouldActivate {
            running = true
            generation &+= 1
        }
        let activeGeneration = generation
        lock.unlock()
        if shouldActivate {
            scheduleCycle(at: scheduler.nowNanoseconds(), generation: activeGeneration)
        }
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
        let activeGeneration = generation
        lock.unlock()
        enqueueImmediateCycle(generation: activeGeneration)
    }

    /// Posts one immediate cycle on the internal serial queue (via the same
    /// `scheduler` seam as the planned cadence), so it is ordered behind any cycle
    /// currently in flight. Carries the generation captured at request time so the
    /// deferred cycle honors the running-gate symmetrically to the planned path.
    private func enqueueImmediateCycle(generation: UInt64) {
        scheduler.schedule(at: scheduler.nowNanoseconds()) { [weak self] in
            self?.performCycle(generation: generation)
        }
    }

    /// The single funnel through which every cycle (planned or manual) runs, so
    /// `cycleExecuting` is authoritative and a refresh mid-cycle is always
    /// deferred to a trailing cycle rather than reentered.
    private func performCycle(generation: UInt64) {
        // Symmetric to the scheduled path (`scheduleCycle` guards the same way):
        // a manual/trailing cycle owed before a stop() or restart must NOT poll,
        // notify, or re-enqueue once the generation has moved on. Without this the
        // manual path would bypass the running-gate — a refresh after stop() (or
        // before start()), and the owed trailing cycle, would run anyway (D-1).
        guard isRunning(generation: generation) else {
            // The gate dropped this cycle, so clear the owed-refresh flag with
            // it: a request that will never be serviced would otherwise stay
            // latched and make every LATER `requestImmediateCycle()` coalesce
            // into a cycle that does not exist. Dropping it here is exactly the
            // documented gate semantics (a refresh owed across a stop() is not
            // owed any more). T9 makes this reachable on a normal path: an empty
            // first launch stays idle, so a refresh clicked before the first host
            // is added lands on this branch.
            lock.lock()
            immediateCyclePending = false
            lock.unlock()
            return
        }
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
        if owed { enqueueImmediateCycle(generation: generation) }
    }

    /// Synchronous cycle seam used by focused tests and future manual refresh.
    public func runOneCycle() {
        // The list is read ONCE, under the lock, at the start of the cycle. What
        // the lock buys is memory safety, not cycle consistency: `hosts` is now
        // mutable and is written from the poll-queue, so an unsynchronized read
        // here would be a data race for the direct callers of this public seam
        // (which do not go through the queue). Consistency of the cycle itself
        // already comes from the serialization plus array value semantics.
        // An empty list visits nothing and still completes the cycle cleanly.
        lock.lock()
        let cycleHosts = hosts
        lock.unlock()
        for host in cycleHosts {
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
            self.performCycle(generation: generation)
        }
    }

    private func isRunning(generation expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && generation == expected
    }
}
