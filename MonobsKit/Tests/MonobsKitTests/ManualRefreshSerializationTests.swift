import XCTest
@testable import MonobsKit

/// Story 3.1, AC6 — closes DEBT.md#D-1: the manual refresh (AD-16) must be
/// SERIALIZED on the same poll-queue as the scheduled poller, never a concurrent
/// `runOneCycle`/`processCycle` from the UI thread.
///
/// [F-W1, non-negotiable] These tests exercise the `HostPollingLoop` layer via an
/// INJECTED scheduler spy — NOT `NotificationCoordinator.processCycle` called
/// twice. A sequential double-`processCycle` test would be VACUOUS: the
/// coordinator's `NSLock` already serializes sequential calls, so it would pass
/// GREEN even without `requestImmediateCycle()`, proving nothing. The negative
/// control here is DETERMINISTIC through the injected scheduler (proving the
/// refresh is ENQUEUED on the serial queue, not executed reentrantly on the
/// calling thread) — never real-thread timing (flaky).
final class ManualRefreshSerializationTests: XCTestCase {
    private let host = ObservedHost(name: "web", host: "vps-web.example", user: "deploy")

    // MARK: - AC6 core: a refresh requested during an in-flight cycle is ENQUEUED
    // (deferred to the serial queue), never run reentrantly on the caller.

    func testRequestImmediateCycleDuringInFlightCycleIsDeferredNotReentrant() {
        let scheduler = VirtualRefreshScheduler(now: 10_000_000_000)
        let events = EventLog()
        var loop: HostPollingLoop!
        var didRequest = false
        loop = HostPollingLoop(
            hosts: [host],
            snapshotStore: SnapshotStore(),
            cadence: 60,                       // far planned re-tick — isolates the refresh
            scheduler: scheduler,
            pollHost: { host in
                events.append("poll:\(host.host)")
                // First cycle only: a manual refresh arrives WHILE this cycle is
                // in flight (mirrors a popover click during a scheduled poll).
                if !didRequest {
                    didRequest = true
                    loop.requestImmediateCycle()
                    events.append("requested")
                }
                return .reportAbsent(exitCode: 3)
            },
            onCycleComplete: { events.append("complete") }
        )

        XCTAssertTrue(loop.start())
        XCTAssertEqual(scheduler.pendingCount, 1, "start enqueues one immediate cycle")

        // Run cycle #1. The nested requestImmediateCycle() must NOT execute a
        // second cycle reentrantly: the event order proves it was deferred.
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(events.values, ["poll:vps-web.example", "requested", "complete"],
                       "NEGATIVE CONTROL: no second 'poll' between 'requested' and 'complete' — a direct runOneCycle would nest one here")

        // The refresh was ENQUEUED on the serial queue, not dropped: cycle #1
        // re-scheduled its planned tick AND enqueued the trailing immediate cycle.
        XCTAssertEqual(scheduler.pendingCount, 2, "planned re-tick + deferred trailing refresh both enqueued")

        // Draining the queue runs the trailing refresh cycle (F-W3: not dropped).
        loop.stop()                            // silence the planned cadence tick
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(events.values.filter { $0 == "poll:vps-web.example" }.count, 2,
                       "the trailing refresh cycle ran exactly once, after cycle #1")
    }

    // MARK: - F-W3: TRAILING coalescing — N requests during one in-flight cycle
    // collapse to exactly ONE trailing cycle (never dropped, never stacked).

    func testMultipleRequestsDuringCycleCoalesceToSingleTrailingCycle() {
        let scheduler = VirtualRefreshScheduler(now: 10_000_000_000)
        let cycles = Counter()
        var loop: HostPollingLoop!
        var burstDone = false
        loop = HostPollingLoop(
            hosts: [host],
            snapshotStore: SnapshotStore(),
            cadence: 60,
            scheduler: scheduler,
            pollHost: { _ in
                if !burstDone {
                    burstDone = true
                    loop.requestImmediateCycle()
                    loop.requestImmediateCycle()
                    loop.requestImmediateCycle()   // three clicks, one cycle in flight
                }
                return .reportAbsent(exitCode: 3)
            },
            onCycleComplete: { cycles.increment() }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())       // cycle #1 (+ burst of 3 requests)
        // Exactly ONE trailing cycle owed, not three: planned re-tick + one
        // immediate — pendingCount is 2, never 4.
        XCTAssertEqual(scheduler.pendingCount, 2,
                       "planned re-tick + exactly one coalesced trailing refresh (three requests → one)")
        loop.stop()                              // stop the cadence; the planned tick will no-op
        XCTAssertTrue(scheduler.runNext())       // the single trailing refresh cycle (earliest deadline)
        XCTAssertEqual(cycles.value, 2, "one planned + one coalesced trailing cycle")
        XCTAssertEqual(scheduler.pendingCount, 1,
                       "only the now-stopped planned tick remains — no second immediate cycle was enqueued")
    }

    // MARK: - AC6 harm: a single rising edge with an interleaved refresh emits
    // EXACTLY ONCE — no double-notification, no stale write-back overwrite.

    func testInterleavedRefreshNeverDoubleNotifiesForOneRisingEdge() {
        let scheduler = VirtualRefreshScheduler(now: 10_000_000_000)
        let spy = CountingEmitter()
        let coordinator = NotificationCoordinator(emitter: spy.emitter)
        let overlap = OverlapDetector()          // fails if two cycles ever overlap

        // Scripted per-cycle states fed to the coordinator via onCycleComplete —
        // the SAME path the app wires (AD-16, identical semantics). A manual
        // refresh is injected during the red rising-edge cycle.
        let states: [[String: HostState]] = [
            ["vps-web.example": .stale],           // cycle 1: baseline, 0
            ["vps-web.example": .rougeInjoignable],// cycle 2: rising edge, +1 (+refresh)
            ["vps-web.example": .rougeInjoignable],// cycle 3 (trailing refresh): red→red, +0
        ]
        let cycleIndex = Counter()
        var loop: HostPollingLoop!
        loop = HostPollingLoop(
            hosts: [host],
            snapshotStore: SnapshotStore(),
            cadence: 60,
            scheduler: scheduler,
            pollHost: { _ in .reportAbsent(exitCode: 3) },
            onCycleComplete: {
                overlap.enter()                    // deterministic non-reentrancy guard
                let i = cycleIndex.value
                let current = states[min(i, states.count - 1)]
                if i == 1 { loop.requestImmediateCycle() }   // refresh during the red cycle
                coordinator.processCycle(currentStates: current)
                cycleIndex.increment()
                overlap.leave()
            }
        )

        XCTAssertTrue(loop.start())
        XCTAssertTrue(scheduler.runNext())         // cycle 1: baseline stale, 0
        XCTAssertEqual(spy.count, 0)
        XCTAssertTrue(scheduler.runNext())         // cycle 2: stale→red rising edge, +1 (+refresh queued)
        XCTAssertEqual(spy.count, 1, "one rising edge ⇒ exactly one emission")
        loop.stop()                                // drop the planned cadence tick
        XCTAssertTrue(scheduler.runNext())         // cycle 3: trailing refresh, red→red, +0
        XCTAssertEqual(spy.count, 1,
                       "the interleaved refresh did NOT double-notify the single rising edge (D-1 closed)")
        XCTAssertFalse(overlap.overlapped, "cycles never overlapped — serialized on the poll-queue")
    }
}

// MARK: - Deterministic test doubles (RFC 2606 hosts only — AD-15)

/// A single-threaded virtual scheduler standing in for the serial polling queue.
/// `runNext()` runs the earliest-deadline action to completion, exposing whether
/// a refresh was ENQUEUED (deferred) vs executed reentrantly on the caller.
private final class VirtualRefreshScheduler: HostPollingScheduling, @unchecked Sendable {
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

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}

private final class CountingEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, HostState)] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    var emitter: RisingEdgeEmitter {
        { id, state in self.lock.lock(); self.storage.append((id, state)); self.lock.unlock() }
    }
}

/// Flags if two cycles are ever active at once — a deterministic reentrancy guard.
private final class OverlapDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var depth = 0
    private var _overlapped = false
    var overlapped: Bool { lock.lock(); defer { lock.unlock() }; return _overlapped }
    func enter() { lock.lock(); depth += 1; if depth > 1 { _overlapped = true }; lock.unlock() }
    func leave() { lock.lock(); depth -= 1; lock.unlock() }
}
