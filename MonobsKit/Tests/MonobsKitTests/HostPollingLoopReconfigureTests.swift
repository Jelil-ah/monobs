import XCTest
@testable import MonobsKit

/// T9 / CAP-10 — hot reconfiguration of the observed host list.
///
/// The owner must be able to add a host from the app and see it polled without
/// relaunching. That means the list stops being fixed at construction, which is
/// exactly the kind of change that reintroduces DEBT.md#D-1 if done carelessly.
/// The reconfiguration therefore reuses the SAME serial-queue seam as the manual
/// refresh (`requestImmediateCycle`), never a second mechanism.
///
/// [F-W1, same discipline as ManualRefreshSerializationTests] Everything here is
/// DETERMINISTIC through an injected scheduler — never real-thread timing, so
/// nothing is flaky and nothing is vacuous:
///   • the polls are OBSERVED through a spy `pollHost`, so "stops being polled"
///     is proven by absence of a recorded call, not assumed from the list;
///   • test 4 asserts INSIDE the running cycle that the swap is not visible yet
///     — the negative control against an in-place mutation mid-cycle;
///   • test 5 asserts on the store, so a purge that silently kept the removed
///     host's facts would fail.
///
/// Hosts are RFC 2606 / RFC 5737 reserved names only (AD-15).
final class HostPollingLoopReconfigureTests: XCTestCase {
    private let web = ObservedHost(name: "web", host: "vps-web.example.com", user: "deploy")
    private let db = ObservedHost(name: "db", host: "vps-db.example.com", user: "deploy")
    private let api = ObservedHost(name: "api", host: "vps-api.example.com", user: "deploy")

    private let facts = ReportFacts(metrics: ["sample": .number(1)],
                                    serverTimestamp: "2026-01-01T12:00:00Z")

    // MARK: - A removed host stops being polled (proven by observing the polls)

    func testRemovedHostStopsBeingPolledOnTheNextCycle() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let polled = ReconfigureEventLog()
        let loop = HostPollingLoop(
            hosts: [web, db],
            snapshotStore: SnapshotStore(),
            cadence: 60,                       // far planned re-tick — isolates the reconfiguration
            scheduler: scheduler,
            pollHost: { host in
                polled.append(host.host)
                return .reportAbsent(exitCode: 3)
            }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())     // cycle #1 — both hosts
        XCTAssertEqual(polled.values, ["vps-web.example.com", "vps-db.example.com"])

        XCTAssertTrue(loop.reconfigure(hosts: [web]))
        // ENQUEUED, not applied in place: the swap is invisible until the serial
        // queue reaches it — the same ordering guarantee as a manual refresh.
        XCTAssertEqual(loop.observedHosts, [web, db],
                       "the reconfiguration must be deferred to the poll-queue, never applied on the caller's thread")

        XCTAssertTrue(scheduler.runNext())     // applies the new list (deadline now < planned re-tick)
        XCTAssertEqual(loop.observedHosts, [web])

        XCTAssertTrue(scheduler.runNext())     // cycle #2 — the planned re-tick
        XCTAssertEqual(polled.values,
                       ["vps-web.example.com", "vps-db.example.com", "vps-web.example.com"],
                       "the removed host was NOT polled again — cycle #2 visited web only")
    }

    // MARK: - An added host enters the next cycle, no restart

    func testAddedHostIsPolledOnTheNextCycleWithoutRestart() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let polled = ReconfigureEventLog()
        let loop = HostPollingLoop(
            hosts: [web],
            snapshotStore: SnapshotStore(),
            cadence: 60,
            scheduler: scheduler,
            pollHost: { host in
                polled.append(host.host)
                return .reportAbsent(exitCode: 3)
            }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())     // cycle #1 — web only
        XCTAssertEqual(polled.values, ["vps-web.example.com"])

        XCTAssertTrue(loop.reconfigure(hosts: [web, db]))
        XCTAssertTrue(scheduler.runNext())     // applies the new list
        XCTAssertEqual(loop.observedHosts, [web, db])

        XCTAssertTrue(scheduler.runNext())     // cycle #2
        XCTAssertEqual(polled.values,
                       ["vps-web.example.com", "vps-web.example.com", "vps-db.example.com"],
                       "the added host entered the very next cycle — the loop was never stopped or restarted")

        // The loop kept its own cadence grid: no extra cycle was injected by the
        // reconfiguration, only the planned re-tick remains pending.
        XCTAssertEqual(scheduler.pendingCount, 1)
        loop.stop()
    }

    // MARK: - Empty list: sane, silent, still cadencing

    func testReconfigurationToAnEmptyListPollsNothingAndDoesNotCrash() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let polled = ReconfigureEventLog()
        let cycles = ReconfigureCounter()
        let loop = HostPollingLoop(
            hosts: [web, db],
            snapshotStore: SnapshotStore(),
            cadence: 60,
            scheduler: scheduler,
            pollHost: { host in
                polled.append(host.host)
                return .reportAbsent(exitCode: 3)
            },
            onCycleComplete: { cycles.increment() }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())     // cycle #1 — both hosts
        XCTAssertEqual(cycles.value, 1)

        XCTAssertTrue(loop.reconfigure(hosts: []))
        XCTAssertTrue(scheduler.runNext())     // applies the empty list
        XCTAssertEqual(loop.observedHosts, [])

        XCTAssertTrue(scheduler.runNext())     // cycle #2 — nothing to visit
        XCTAssertEqual(polled.values, ["vps-web.example.com", "vps-db.example.com"],
                       "no host was polled after the list went empty")
        XCTAssertEqual(cycles.value, 2,
                       "the cycle still COMPLETED — the projection recomputes to an empty surface instead of freezing")
        XCTAssertEqual(scheduler.pendingCount, 1,
                       "the cadence stays alive on an empty list, so re-adding a host resumes polling")

        // Re-adding after the empty state resumes polling at the next cycle.
        XCTAssertTrue(loop.reconfigure(hosts: [api]))
        XCTAssertTrue(scheduler.runNext())     // applies
        XCTAssertTrue(scheduler.runNext())     // cycle #3
        XCTAssertEqual(polled.values,
                       ["vps-web.example.com", "vps-db.example.com", "vps-api.example.com"])
        loop.stop()
    }

    // MARK: - Reconfiguration requested DURING a cycle: deferred, never concurrent

    func testReconfigurationDuringAnInFlightCycleIsDeferredAndLeavesCoherentState() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let events = ReconfigureEventLog()
        let overlap = ReconfigureOverlapDetector()
        let once = OneShotLatch()
        // Local copies: the poll closure is `@Sendable` and must not capture the
        // (non-Sendable) XCTestCase through its stored hosts.
        let web = self.web
        let db = self.db
        var loop: HostPollingLoop!
        loop = HostPollingLoop(
            hosts: [web, db],
            snapshotStore: SnapshotStore(),
            cadence: 60,
            scheduler: scheduler,
            pollHost: { host in
                events.append("poll:\(host.host)")
                // The operator removes `db` from the settings window WHILE the
                // cycle that is currently visiting `web` is in flight.
                if once.fireOnce() {
                    loop.reconfigure(hosts: [web])
                    events.append("reconfigure-requested")
                    // NEGATIVE CONTROL: an in-place mutation would make the new
                    // list visible right here and truncate the running cycle.
                    XCTAssertEqual(loop.observedHosts, [web, db],
                                   "the swap must NOT land inside the cycle already in flight")
                }
                return .reportAbsent(exitCode: 3)
            },
            onCycleComplete: {
                overlap.enter()
                events.append("complete")
                overlap.leave()
            }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())     // cycle #1, with the reconfiguration requested mid-cycle

        // The cycle in flight finished on the list it STARTED with — `db` was
        // still visited — and no nested cycle ran between the request and the
        // completion. That is the whole no-concurrent-cycle guarantee.
        XCTAssertEqual(events.values,
                       ["poll:vps-web.example.com",
                        "reconfigure-requested",
                        "poll:vps-db.example.com",
                        "complete"],
                       "the in-flight cycle was neither truncated nor reentered")
        XCTAssertFalse(overlap.overlapped, "cycles never overlapped — serialized on the poll-queue")

        // The reconfiguration was enqueued behind cycle #1, not dropped.
        XCTAssertEqual(scheduler.pendingCount, 2, "planned re-tick + the deferred reconfiguration")
        XCTAssertTrue(scheduler.runNext())     // applies the deferred swap
        XCTAssertEqual(loop.observedHosts, [web])

        XCTAssertTrue(scheduler.runNext())     // cycle #2 — coherent final state
        XCTAssertEqual(events.values.filter { $0 == "poll:vps-db.example.com" }.count, 1,
                       "the removed host was polled only by the cycle that predated the reconfiguration")
        XCTAssertEqual(Array(events.values.suffix(2)),
                       ["poll:vps-web.example.com", "complete"])
        XCTAssertFalse(overlap.overlapped)
        loop.stop()
    }

    // MARK: - Residual state of a removed host does not survive

    func testRemovedHostSnapshotIsPurgedSoResidualStateCannotSurface() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let store = SnapshotStore()
        let receivedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let facts = self.facts
        let loop = HostPollingLoop(
            hosts: [web, db],
            snapshotStore: store,
            cadence: 60,
            now: { receivedAt },
            scheduler: scheduler,
            pollHost: { _ in .validReport(facts) }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())     // cycle #1 records real facts for both hosts
        XCTAssertEqual(Set(store.allSnapshots().keys),
                       ["vps-web.example.com", "vps-db.example.com"])

        XCTAssertTrue(loop.reconfigure(hosts: [web]))
        XCTAssertTrue(scheduler.runNext())     // applies the swap AND purges the removed host

        XCTAssertEqual(Set(store.allSnapshots().keys), ["vps-web.example.com"],
                       "the removed host's snapshot was dropped from the store — every reader goes through allSnapshots()")
        XCTAssertEqual(store.snapshot(for: "vps-db.example.com"), HostSnapshot(),
                       "no residual facts, no residual freshness, no residual SSH failure for the removed host")
        // The retained host is untouched: the purge is surgical, not a wipe.
        XCTAssertEqual(store.snapshot(for: "vps-web.example.com"),
                       HostSnapshot(lastValidFacts: facts,
                                    lastValidReceivedAt: receivedAt,
                                    sshFailureActive: false))
        loop.stop()
    }

    // MARK: - Identical list: no perturbation at all

    func testReconfigurationToAnIdenticalListIsAStrictNoOp() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let store = SnapshotStore()
        let facts = self.facts
        let cycles = ReconfigureCounter()
        let loop = HostPollingLoop(
            hosts: [web, db],
            snapshotStore: store,
            cadence: 60,
            scheduler: scheduler,
            pollHost: { _ in .validReport(facts) },
            onCycleComplete: { cycles.increment() }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())     // cycle #1
        XCTAssertEqual(scheduler.pendingCount, 1, "only the planned re-tick is pending")

        XCTAssertFalse(loop.reconfigure(hosts: [web, db]),
                       "an identical list reports that nothing was enqueued")
        XCTAssertEqual(scheduler.pendingCount, 1,
                       "no queue traffic — the loop is left strictly undisturbed")
        XCTAssertEqual(cycles.value, 1, "no cycle was injected")
        XCTAssertEqual(Set(store.allSnapshots().keys),
                       ["vps-web.example.com", "vps-db.example.com"],
                       "no snapshot was purged")

        // Order matters: the same hosts in a different order IS a change (the
        // list drives the visiting order), so it is not swallowed by the fast path.
        XCTAssertTrue(loop.reconfigure(hosts: [db, web]))
        loop.stop()
    }

    // MARK: - An edit undone while a swap is still in flight

    func testSecondRequestWhileOneIsInFlightWinsAndIsNeverSwallowed() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let store = SnapshotStore()
        let facts = self.facts
        let loop = HostPollingLoop(
            hosts: [web, db],
            snapshotStore: store,
            cadence: 60,
            scheduler: scheduler,
            pollHost: { _ in .validReport(facts) }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())     // cycle #1 records facts for both hosts

        // The operator removes `db`, then puts it back before the first request
        // has been applied. The second request is byte-identical to the CURRENT
        // list, so a fast path comparing against `hosts` alone would swallow it
        // and leave the loop pinned on the obsolete `[web]`.
        XCTAssertTrue(loop.reconfigure(hosts: [web]))
        XCTAssertTrue(loop.reconfigure(hosts: [web, db]),
                      "a request must not be compared against a list that a still-pending swap is about to invalidate")

        XCTAssertTrue(scheduler.runNext())     // first enqueued apply
        XCTAssertTrue(scheduler.runNext())     // second enqueued apply
        XCTAssertEqual(loop.observedHosts, [web, db],
                       "last request wins — the undo was honoured, not the obsolete removal")
        XCTAssertEqual(Set(store.allSnapshots().keys),
                       ["vps-web.example.com", "vps-db.example.com"])
        XCTAssertEqual(store.snapshot(for: "vps-db.example.com").lastValidFacts, facts,
                       "an edit undone before it landed costs no snapshot — no purge/re-add round trip")
        loop.stop()
    }

    // MARK: - The direct `runOneCycle()` seam finishes on the list it started with

    /// Honest scope: this pins the OBSERVABLE behaviour of the public synchronous
    /// seam when a reconfiguration is applied in the middle of it. It does NOT
    /// prove the lock around the list read in `runOneCycle` — that guards against
    /// a data race, which no deterministic test can exhibit. Array value semantics
    /// are what make the visited list stable here.
    func testDirectCycleSeamVisitsTheListItStartedWithEvenIfASwapLandsMidCycle() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let polled = ReconfigureEventLog()
        let once = OneShotLatch()
        var loop: HostPollingLoop!
        loop = HostPollingLoop(
            hosts: [web, db],
            snapshotStore: SnapshotStore(),
            cadence: 60,
            scheduler: scheduler,
            pollHost: { host in
                polled.append(host.host)
                if once.fireOnce() {
                    loop.reconfigure(hosts: [])
                    scheduler.runNext()        // force the swap to land MID-cycle
                }
                return .reportAbsent(exitCode: 3)
            }
        )

        loop.runOneCycle()                     // direct seam — never started, no queue involved
        XCTAssertEqual(polled.values, ["vps-web.example.com", "vps-db.example.com"],
                       "the cycle was not truncated by the swap that landed while it ran")
        XCTAssertEqual(loop.observedHosts, [])

        loop.runOneCycle()                     // the next cycle honours the new list
        XCTAssertEqual(polled.values, ["vps-web.example.com", "vps-db.example.com"])
        XCTAssertEqual(scheduler.pendingCount, 0,
                       "reconfiguring a loop that was never started enqueues no cycle")
    }

    // MARK: - Empty first launch: adding the first host starts polling, no relaunch

    func testAddingTheFirstHostAfterAnEmptyStartActivatesTheCadence() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let polled = ReconfigureEventLog()
        let loop = HostPollingLoop(
            hosts: [],
            snapshotStore: SnapshotStore(),
            cadence: 60,
            scheduler: scheduler,
            pollHost: { host in
                polled.append(host.host)
                return .reportAbsent(exitCode: 3)
            }
        )

        // Unchanged contract: zero hosts stays cleanly idle and enqueues nothing.
        XCTAssertFalse(loop.start())
        XCTAssertEqual(scheduler.pendingCount, 0)

        XCTAssertTrue(loop.reconfigure(hosts: [web]))
        XCTAssertEqual(scheduler.pendingCount, 1, "only the reconfiguration is enqueued")
        XCTAssertTrue(scheduler.runNext())     // applies the list and activates the cadence
        XCTAssertEqual(polled.values, [], "applying a configuration polls nothing by itself")
        XCTAssertEqual(scheduler.pendingCount, 1, "the first cycle is now enqueued")

        XCTAssertTrue(scheduler.runNext())     // the first real cycle
        XCTAssertEqual(polled.values, ["vps-web.example.com"],
                       "the app started polling the newly added host without being relaunched")
        loop.stop()
    }

    // MARK: - Negative control: a reconfiguration never resurrects a stopped loop

    func testReconfigurationAfterStopUpdatesTheListButDoesNotRestartPolling() {
        let scheduler = VirtualReconfigureScheduler(now: 10_000_000_000)
        let polled = ReconfigureEventLog()
        let loop = HostPollingLoop(
            hosts: [web],
            snapshotStore: SnapshotStore(),
            cadence: 60,
            scheduler: scheduler,
            pollHost: { host in
                polled.append(host.host)
                return .reportAbsent(exitCode: 3)
            }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())     // cycle #1
        loop.stop()

        XCTAssertTrue(loop.reconfigure(hosts: [web, db]))
        XCTAssertTrue(scheduler.runNext())     // applies the swap
        XCTAssertEqual(loop.observedHosts, [web, db],
                       "the operator's edit is never silently discarded, even while stopped")

        // Drain: the planned re-tick bails on the generation and nothing else was
        // enqueued — the reconfiguration did not restart the loop behind stop().
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(polled.values, ["vps-web.example.com"],
                       "no poll happened after stop()")
    }
}

// MARK: - Deterministic test doubles (reserved hosts only — AD-15)

/// Single-threaded virtual scheduler standing in for the serial polling queue.
/// `runNext()` runs the earliest-deadline action to completion, so an action
/// that was ENQUEUED (deferred) is observably distinct from one executed inline
/// on the caller.
private final class VirtualReconfigureScheduler: HostPollingScheduling, @unchecked Sendable {
    private struct Scheduled { let deadline: UInt64; let order: UInt64; let action: @Sendable () -> Void }
    private let lock = NSLock()
    private var currentTime: UInt64
    private var nextOrder: UInt64 = 0
    private var actions: [Scheduled] = []

    init(now: UInt64) { currentTime = now }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return actions.count }

    func nowNanoseconds() -> UInt64 { lock.lock(); defer { lock.unlock() }; return currentTime }

    func schedule(at deadline: UInt64, action: @escaping @Sendable () -> Void) {
        lock.lock()
        actions.append(Scheduled(deadline: deadline, order: nextOrder, action: action))
        nextOrder &+= 1
        lock.unlock()
    }

    @discardableResult
    func runNext() -> Bool {
        lock.lock()
        guard let index = actions.indices.min(by: {
            (actions[$0].deadline, actions[$0].order) < (actions[$1].deadline, actions[$1].order)
        }) else { lock.unlock(); return false }
        let scheduled = actions.remove(at: index)
        currentTime = max(currentTime, scheduled.deadline)
        lock.unlock()
        scheduled.action()
        return true
    }
}

private final class ReconfigureEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
}

private final class ReconfigureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}

/// Flags if two cycles are ever active at once — deterministic reentrancy guard.
private final class ReconfigureOverlapDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var depth = 0
    private var _overlapped = false
    var overlapped: Bool { lock.lock(); defer { lock.unlock() }; return _overlapped }
    func enter() { lock.lock(); depth += 1; if depth > 1 { _overlapped = true }; lock.unlock() }
    func leave() { lock.lock(); depth -= 1; lock.unlock() }
}

/// Lock-protected one-shot flag — a mutable captured `var` inside a `@Sendable`
/// poll closure would not survive strict concurrency checking.
private final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fireOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
