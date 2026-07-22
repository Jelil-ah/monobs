import XCTest
@testable import MonobsKit

// Story 2.4, Task 1 (AC1/AC2/AC3): the PURE rising-edge decision, tested
// EXHAUSTIVELY. Emit SSI `previous ∈ {vert, stale} ∧ current ∈ {rougeSeuil,
// rougeInjoignable}`; `previous == nil` (cold start / host never seen) ⇒ never.
//
// The oracle is a HARD-CODED whitelist of the 4 OUI transitions, INDEPENDENT of
// the production `switch` (which uses `isRed`) — so a single-line regression in
// production makes a row mismatch (non-vacuous). No `default`, no shared logic
// with production: the test would still fail if `shouldNotify` were mutated.
final class RisingEdgeNotificationTests: XCTestCase {

    /// The 4 (and only 4) rising-edge transitions that MUST emit — hard-coded,
    /// not derived from `isRed`. Rows 7, 8, 11, 12 of the story's decision table.
    private struct Transition: Hashable { let previous: HostState; let current: HostState }
    private let ouiTransitions: Set<Transition> = [
        Transition(previous: .vert,  current: .rougeSeuil),        // row 7  (générique 2.3)
        Transition(previous: .vert,  current: .rougeInjoignable),  // row 8  (produced in 2.4)
        Transition(previous: .stale, current: .rougeSeuil),        // row 11 (générique 2.3)
        Transition(previous: .stale, current: .rougeInjoignable),  // row 12 (grey→red, CA-5)
    ]

    /// Independent oracle: emit iff previous is non-nil AND (previous, current)
    /// is one of the 4 whitelisted rising transitions.
    private func expected(previous: HostState?, current: HostState) -> Bool {
        guard let previous else { return false }  // cold start ⇒ never
        return ouiTransitions.contains(Transition(previous: previous, current: current))
    }

    // All 20 rows: previous ∈ {nil} + 4 states, current ∈ 4 states. Iterated via
    // CaseIterable so a future 5th state widens the table automatically.
    private var allPrevious: [HostState?] { [nil] + HostState.allCases.map(Optional.some) }
    private var allCurrent: [HostState] { HostState.allCases }

    func testDecisionTableExhaustive() {
        var ouiCount = 0
        var nonCount = 0
        for previous in allPrevious {
            for current in allCurrent {
                let got = RisingEdge.shouldNotify(previous: previous, current: current)
                let want = expected(previous: previous, current: current)
                XCTAssertEqual(got, want,
                    "shouldNotify(previous: \(String(describing: previous)), current: \(current)) = \(got), expected \(want)")
                if want { ouiCount += 1 } else { nonCount += 1 }
            }
        }
        // Non-vacuous count invariants: exactly 4 OUI, 16 NON over the 20 rows.
        XCTAssertEqual(ouiCount, 4, "exactly 4 rising-edge transitions must emit")
        XCTAssertEqual(nonCount, 16, "the other 16 rows must be silent")
        XCTAssertEqual(allPrevious.count * allCurrent.count, 20, "table is 5×4 = 20 rows")
    }

    // Rows 1–4: cold start (previous nil) is ALWAYS silent, even if the host is
    // already red (rows 3–4) — AD-13 baseline muette.
    func testColdStartNilIsAlwaysSilentEvenWhenRed() {
        for current in HostState.allCases {
            XCTAssertFalse(RisingEdge.shouldNotify(previous: nil, current: current),
                "previous == nil must never emit (current: \(current))")
        }
    }

    // Rows 16 & 19: red→red change of LABEL emits ZERO (both directions).
    func testRedToRedLabelChangeIsSilent() {
        XCTAssertFalse(RisingEdge.shouldNotify(previous: .rougeSeuil, current: .rougeInjoignable)) // row 16
        XCTAssertFalse(RisingEdge.shouldNotify(previous: .rougeInjoignable, current: .rougeSeuil)) // row 19
        XCTAssertFalse(RisingEdge.shouldNotify(previous: .rougeSeuil, current: .rougeSeuil))       // row 15
        XCTAssertFalse(RisingEdge.shouldNotify(previous: .rougeInjoignable, current: .rougeInjoignable)) // row 20
    }

    // Rows 7 & 11: `rougeSeuil` is treated as red GENERICALLY (so 2.3 rewires
    // nothing), on CONSTRUCTED states — 2.4's reducer never produces it.
    func testRougeSeuilTreatedAsRedGenerically() {
        XCTAssertTrue(RisingEdge.shouldNotify(previous: .vert,  current: .rougeSeuil))  // row 7
        XCTAssertTrue(RisingEdge.shouldNotify(previous: .stale, current: .rougeSeuil))  // row 11
        XCTAssertTrue(RisingEdge.isRed(.rougeSeuil))
        XCTAssertTrue(RisingEdge.isRed(.rougeInjoignable))
        XCTAssertFalse(RisingEdge.isRed(.vert))
        XCTAssertFalse(RisingEdge.isRed(.stale))
    }

    // Transitions toward a non-red state emit ZERO (rows 13, 14, 17, 18).
    func testTransitionToNonRedIsSilent() {
        XCTAssertFalse(RisingEdge.shouldNotify(previous: .rougeInjoignable, current: .vert))  // row 17
        XCTAssertFalse(RisingEdge.shouldNotify(previous: .rougeInjoignable, current: .stale)) // row 18 (override)
        XCTAssertFalse(RisingEdge.shouldNotify(previous: .rougeSeuil, current: .vert))        // row 13
        XCTAssertFalse(RisingEdge.shouldNotify(previous: .rougeSeuil, current: .stale))       // row 14
    }
}
