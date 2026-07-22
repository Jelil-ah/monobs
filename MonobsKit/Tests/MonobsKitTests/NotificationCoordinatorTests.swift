import XCTest
@testable import MonobsKit

// Story 2.4, Task 2 (AC1/AC2/AC3/AC4/AC5): the pure cycle step + the coordinator
// (write-back + injected emitter). A SPY that COUNTS emissions is injected —
// NEVER a real `UNUserNotificationCenter` (it needs a `.app` bundle absent in
// `swift test`). Assertions are non-vacuous: the count CHANGES (0 vs 1 vs K) and
// a negative control proves the 0.
final class NotificationCoordinatorTests: XCTestCase {

    /// Counting spy conforming to the `RisingEdgeEmitter` seam. Thread-safe so it
    /// can also back the F-1 concurrency test without racing its own array.
    private final class EmitterSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _emitted: [(String, HostState)] = []
        var emitted: [(String, HostState)] { lock.lock(); defer { lock.unlock() }; return _emitted }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _emitted.count }
        var emitter: RisingEdgeEmitter {
            { id, state in
                self.lock.lock(); self._emitted.append((id, state)); self.lock.unlock()
            }
        }
    }

    private let h = "vps-web.example"

    // MARK: - Pure cycle step

    func testStepWriteBackEqualsCurrentAndEmitSorted() {
        // Three hosts rising grey→red in one step ⇒ emit is ALL three, sorted;
        // next == current exactly (write-back := current).
        let previous: [String: HostState] = ["vps-b.example": .stale, "vps-a.example": .stale, "vps-c.example": .stale]
        let current: [String: HostState] = ["vps-b.example": .rougeInjoignable, "vps-a.example": .rougeInjoignable, "vps-c.example": .rougeInjoignable]
        let (emit, next) = RisingEdge.step(previous: previous, current: current)
        XCTAssertEqual(emit, ["vps-a.example", "vps-b.example", "vps-c.example"], "emit is sorted, deterministic")
        XCTAssertEqual(next, current, "write-back := current, exactly")
    }

    func testStepDropsAbsentHostsAndSilencesNewHosts() {
        // A host absent from `current` is dropped from `next`; a host new this
        // cycle (previous nil) is silent even if red.
        let previous: [String: HostState] = ["gone.example": .rougeInjoignable]
        let current: [String: HostState] = ["new.example": .rougeInjoignable]
        let (emit, next) = RisingEdge.step(previous: previous, current: current)
        XCTAssertEqual(emit, [], "new host (previous nil) is silent even if red")
        XCTAssertEqual(next, current, "absent host dropped, next == current")
        XCTAssertNil(next["gone.example"])
    }

    // MARK: - Coordinator + spy

    // AC3: cold start muet — a brand-new coordinator seeing an already-red host
    // emits ZERO and lays the baseline.
    func testColdStartSilentEvenIfAlreadyRed() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        coord.processCycle(currentStates: [h: .rougeInjoignable])
        XCTAssertEqual(spy.count, 0, "cold start is muet even if the host is already red")
        // Baseline was written: staying red the next cycle also emits 0.
        coord.processCycle(currentStates: [h: .rougeInjoignable])
        XCTAssertEqual(spy.count, 0, "red persists ⇒ no emission (baseline was laid at cold start)")
    }

    // AC1: rising edge stale→red ⇒ exactly one.
    func testRisingEdgeEmitsExactlyOnce() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        coord.processCycle(currentStates: [h: .stale])            // baseline, 0
        XCTAssertEqual(spy.count, 0)
        coord.processCycle(currentStates: [h: .rougeInjoignable]) // rising edge, +1
        XCTAssertEqual(spy.count, 1, "one rising edge ⇒ exactly one emission")
    }

    // AC2: red persistent ⇒ zero further emissions.
    func testRedPersistentNoSecondEmit() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        coord.processCycle(currentStates: [h: .vert])             // baseline, 0
        coord.processCycle(currentStates: [h: .rougeInjoignable]) // +1
        coord.processCycle(currentStates: [h: .rougeInjoignable]) // +0 (persistent)
        coord.processCycle(currentStates: [h: .rougeInjoignable]) // +0
        XCTAssertEqual(spy.count, 1, "red persists across cycles ⇒ still exactly one")
    }

    // AC2: red→red change of LABEL ⇒ zero (both directions).
    func testRedToRedLabelChangeEmitsZero() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        coord.processCycle(currentStates: [h: .vert])              // baseline, 0
        coord.processCycle(currentStates: [h: .rougeInjoignable])  // +1
        coord.processCycle(currentStates: [h: .rougeSeuil])        // label change, +0
        coord.processCycle(currentStates: [h: .rougeInjoignable])  // label change back, +0
        XCTAssertEqual(spy.count, 1, "red→red label change (both directions) ⇒ 0")
    }

    // AC2: transition toward non-red ⇒ zero.
    func testTransitionToNonRedEmitsZero() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        coord.processCycle(currentStates: [h: .stale])            // baseline, 0
        coord.processCycle(currentStates: [h: .rougeInjoignable]) // +1
        coord.processCycle(currentStates: [h: .vert])             // red→vert, +0
        XCTAssertEqual(spy.count, 1, "transition to non-red emits nothing")
    }

    // AC4: K hosts grey→red in one cycle ⇒ exactly K emissions (FR9 to the
    // letter, R1 not amortized).
    func testKHostsGreyToRedEmitsK() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        let ids = (1...5).map { "vps-\($0).example" }
        let stale = Dictionary(uniqueKeysWithValues: ids.map { ($0, HostState.stale) })
        let red = Dictionary(uniqueKeysWithValues: ids.map { ($0, HostState.rougeInjoignable) })
        coord.processCycle(currentStates: stale) // baseline, 0
        XCTAssertEqual(spy.count, 0)
        coord.processCycle(currentStates: red)   // K rising edges
        XCTAssertEqual(spy.count, ids.count, "K hosts grey→red ⇒ exactly K emissions (no debounce)")
        XCTAssertEqual(Set(spy.emitted.map { $0.0 }), Set(ids), "one emission per rising host")
    }

    // AC4 core: write-back on the Tailscale-override cycle is what enables the
    // recovery emission. Cycle A red (cold baseline, 0) ; cycle B all-stale
    // (override, red→stale, +0, write-back := stale) ; cycle C red again
    // (stale→red = fresh rising edge, +1).
    func testWriteBackOnTailscaleOverrideEnablesRecovery() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        coord.processCycle(currentStates: [h: .rougeInjoignable]) // A: cold baseline, 0
        XCTAssertEqual(spy.count, 0)
        coord.processCycle(currentStates: [h: .stale])            // B: override, +0, write-back := stale
        XCTAssertEqual(spy.count, 0, "no notification while Tailscale is down (U-3/CA-5)")
        coord.processCycle(currentStates: [h: .rougeInjoignable]) // C: recovery stale→red, +1
        XCTAssertEqual(spy.count, 1, "recovery after override emits — write-back reset the baseline")
    }

    // Write-back inconditionnel provable via the NEXT cycle: after a silent
    // vert cycle, previous == vert (not nil), so a following red is a rising edge.
    func testUnconditionalWriteBackAfterSilentCycle() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        coord.processCycle(currentStates: [h: .stale]) // cold baseline, 0
        coord.processCycle(currentStates: [h: .vert])  // silent (stale→vert), write-back := vert
        XCTAssertEqual(spy.count, 0)
        coord.processCycle(currentStates: [h: .rougeInjoignable]) // vert→red = rising, +1
        XCTAssertEqual(spy.count, 1, "silent cycle still wrote the baseline (vert), so the next red fires")
    }

    // F-2 (Mary): prove UNICITY — exactly one emission per rising transition, and
    // it carries exactly the rising host + its current state.
    func testUnicityExactlyOneEmissionPerRisingEdge() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        coord.processCycle(currentStates: [h: .vert])
        coord.processCycle(currentStates: [h: .rougeInjoignable])
        XCTAssertEqual(spy.count, 1, "exactly one emission")
        XCTAssertEqual(spy.emitted.count, 1)
        XCTAssertEqual(spy.emitted.first?.0, h)
        XCTAssertEqual(spy.emitted.first?.1, .rougeInjoignable)
    }

    // F-1 (Mary): thread-safety. Hammer `processCycle` from many threads with the
    // SAME map. The NSLock serializes decide→emit→write-back; without it the
    // shared dictionary mutation would data-race (crash under TSan). Because every
    // concurrent call writes the SAME map, the final previous state is
    // deterministic (== that map) regardless of interleaving, so the test asserts
    // integrity WITHOUT flakiness: a follow-up rising edge on a consistent
    // baseline emits exactly once.
    func testConcurrentProcessCycleKeepsStateConsistent() {
        let spy = EmitterSpy()
        let coord = NotificationCoordinator(emitter: spy.emitter)
        let baseline: [String: HostState] = ["vps-a.example": .stale, "vps-b.example": .stale]
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            coord.processCycle(currentStates: baseline)
        }
        // All concurrent cycles are stale→stale (or cold nil→stale) ⇒ silent.
        XCTAssertEqual(spy.count, 0, "concurrent stale→stale cycles emit nothing")
        // State is intact (not corrupted by a race): a rising edge now fires once.
        coord.processCycle(currentStates: ["vps-a.example": .rougeInjoignable, "vps-b.example": .stale])
        XCTAssertEqual(spy.emitted.filter { $0.0 == "vps-a.example" && $0.1 == .rougeInjoignable }.count, 1,
            "baseline stayed consistent under concurrency; rising edge emits exactly once")
    }
}
