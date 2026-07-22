import XCTest
@testable import MonobsKit

// Story 1.4, Task 3 (AC2/AC3): the AD-17 ranking module — the complete total
// order (tested on the four states constructed DIRECTLY, not via the reducer,
// to prepare 2.2/2.3), the ascending host-ID tie-break, the worst-state
// aggregate applied to the {vert, stale} subset, and the fail-closed zero-host
// degenerate case.
final class StateRankingTests: XCTestCase {

    // Complete total order: rougeInjoignable > rougeSeuil > stale > vert.
    // States are constructed directly — the reducer never emits reds, so this
    // exercises the order the ranking module must encode for 2.2/2.3.
    func testCompleteTotalOrderOnFourStates() {
        let ranked = [HostState.vert, .stale, .rougeSeuil, .rougeInjoignable]
            .sorted { StateRanking.severity($0) > StateRanking.severity($1) }
        XCTAssertEqual(ranked, [.rougeInjoignable, .rougeSeuil, .stale, .vert])
    }

    func testSeverityIsStrictlyMonotonic() {
        XCTAssertGreaterThan(StateRanking.severity(.rougeInjoignable), StateRanking.severity(.rougeSeuil))
        XCTAssertGreaterThan(StateRanking.severity(.rougeSeuil), StateRanking.severity(.stale))
        XCTAssertGreaterThan(StateRanking.severity(.stale), StateRanking.severity(.vert))
    }

    // Aggregate = worst state, applied to the reachable {vert, stale} subset.
    func testWorstPicksStaleOverVert() {
        XCTAssertEqual(StateRanking.worst([.vert, .stale, .vert]), .stale)
    }

    func testWorstAllVertIsVert() {
        XCTAssertEqual(StateRanking.worst([.vert, .vert]), .vert)
    }

    // Worst honours the full order too (future 2.2/2.3 aggregates).
    func testWorstPicksMostSevereAcrossAllStates() {
        XCTAssertEqual(StateRanking.worst([.vert, .stale, .rougeSeuil]), .rougeSeuil)
        XCTAssertEqual(StateRanking.worst([.stale, .rougeInjoignable, .rougeSeuil]), .rougeInjoignable)
    }

    // Zero hosts ⇒ degenerate, fail-closed: nil, NEVER vert.
    func testWorstOnEmptyIsNilNeverVert() {
        let aggregate = StateRanking.worst([])
        XCTAssertNil(aggregate)
        XCTAssertNotEqual(aggregate, .vert)
    }

    private struct Row { let hostID: String; let state: HostState }

    // Tie-break: two hosts in the same state order by host ID ascending,
    // deterministically, independent of input order.
    func testTieBreakByHostIDAscending() {
        let a = Row(hostID: "vps-a.example", state: .vert)
        let b = Row(hostID: "vps-b.example", state: .vert)
        let forward = StateRanking.ordered([a, b], hostID: { $0.hostID }, state: { $0.state })
        let reversed = StateRanking.ordered([b, a], hostID: { $0.hostID }, state: { $0.state })
        XCTAssertEqual(forward.map { $0.hostID }, ["vps-a.example", "vps-b.example"])
        XCTAssertEqual(reversed.map { $0.hostID }, ["vps-a.example", "vps-b.example"])
    }

    // Severity dominates the tie-break: worse state first even when its host ID
    // sorts later.
    func testOrderingPutsWorstFirstThenHostID() {
        let rows = [
            Row(hostID: "vps-a.example", state: .vert),
            Row(hostID: "vps-z.example", state: .stale),
            Row(hostID: "vps-b.example", state: .vert),
        ]
        let ordered = StateRanking.ordered(rows, hostID: { $0.hostID }, state: { $0.state })
        XCTAssertEqual(ordered.map { $0.hostID },
                       ["vps-z.example", "vps-a.example", "vps-b.example"])
    }

    func testOrderingIsDeterministicUnderInputPermutation() {
        let base = [
            Row(hostID: "vps-b.example", state: .stale),
            Row(hostID: "vps-a.example", state: .stale),
            Row(hostID: "vps-c.example", state: .vert),
        ]
        let expected = ["vps-a.example", "vps-b.example", "vps-c.example"]
        XCTAssertEqual(StateRanking.ordered(base, hostID: { $0.hostID }, state: { $0.state }).map { $0.hostID }, expected)
        XCTAssertEqual(StateRanking.ordered(base.reversed(), hostID: { $0.hostID }, state: { $0.state }).map { $0.hostID }, expected)
    }

    // F3 defence in depth: uniqueness of host IDs is a precondition (guaranteed
    // upstream by HostConfig dedup), but `ordered` must not depend on the
    // undefined stability of `sorted(by:)` if a caller ever violates it. Two
    // rows sharing a host ID and the same state, tagged so input order is
    // observable, must come out in input order — a plain unstable sort could
    // permute them. The `tag` distinguishes them by value; ranking ignores it.
    func testDuplicateHostIDPreservesInputOrderDeterministically() {
        let rows: [(hostID: String, state: HostState, tag: Int)] = [
            ("vps-dup.example", .stale, 0),
            ("vps-a.example",   .stale, 1),
            ("vps-dup.example", .stale, 2),
        ]
        let ordered = StateRanking.ordered(rows, hostID: { $0.hostID }, state: { $0.state })
        // vps-a sorts before vps-dup; the two duplicates keep their input order
        // (tags 0 then 2), never permuted.
        XCTAssertEqual(ordered.map { $0.hostID },
                       ["vps-a.example", "vps-dup.example", "vps-dup.example"])
        XCTAssertEqual(ordered.map { $0.tag }, [1, 0, 2])
    }
}
