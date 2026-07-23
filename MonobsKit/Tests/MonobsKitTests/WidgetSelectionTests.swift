import XCTest
@testable import MonobsKit

// Story 3.2 (AC1/AC2): the widget's 6-worst selection + explicit overflow.
// Ordering is the single shared AD-17 `StateRanking` (reused, not re-ranked).
// Exact boundary: N=6 ⇒ all shown, no overflow; N=7 ⇒ 6 worst + overflow of 1.
final class WidgetSelectionTests: XCTestCase {

    private let ts = Date(timeIntervalSince1970: 1_750_000_000)

    private func entry(_ id: String, _ state: HostState) -> SharedHostEntry {
        SharedHostEntry(hostID: id, state: state, freshnessTimestamp: ts)
    }

    // AC1: ≥7 hosts ⇒ 6 worst (AD-17 order) + overflow of the remainder.
    func testSevenHostsShowSixWorstPlusOverflow() {
        let hosts = [
            entry("vps-a.example", .vert),
            entry("vps-b.example", .vert),
            entry("vps-c.example", .vert),
            entry("vps-d.example", .stale),
            entry("vps-e.example", .rougeSeuil),
            entry("vps-f.example", .rougeInjoignable),
            entry("vps-g.example", .vert),
        ]
        let selection = WidgetSelector.select(hosts)
        XCTAssertTrue(selection.hasOverflow)
        XCTAssertEqual(selection.overflowCount, 1)
        XCTAssertEqual(selection.shown.count, 6)
        // Worst first (AD-17): rougeInjoignable > rougeSeuil > stale > vert, then
        // vert hosts by host ID ascending. The last vert (vps-g) overflows.
        XCTAssertEqual(selection.shown.map { $0.hostID },
                       ["vps-f.example", "vps-e.example", "vps-d.example",
                        "vps-a.example", "vps-b.example", "vps-c.example"])
    }

    // AC2 boundary: exactly 6 hosts ⇒ all shown, NO overflow.
    func testSixHostsShowAllNoOverflow() {
        let hosts = (0..<6).map { entry("vps-\($0).example", .vert) }
        let selection = WidgetSelector.select(hosts)
        XCTAssertFalse(selection.hasOverflow)
        XCTAssertEqual(selection.overflowCount, 0)
        XCTAssertEqual(selection.shown.count, 6)
    }

    // Boundary control: 7 hosts is the FIRST count that overflows (overflow of 1).
    func testSevenIsTheExactOverflowBoundary() {
        let six = (0..<6).map { entry("vps-\($0).example", .vert) }
        let seven = (0..<7).map { entry("vps-\($0).example", .vert) }
        XCTAssertEqual(WidgetSelector.select(six).overflowCount, 0)
        XCTAssertEqual(WidgetSelector.select(seven).overflowCount, 1)
    }

    // Fewer than 6 ⇒ all shown, no overflow.
    func testFewHostsShowAllNoOverflow() {
        let selection = WidgetSelector.select([entry("vps-a.example", .rougeInjoignable),
                                               entry("vps-b.example", .vert)])
        XCTAssertFalse(selection.hasOverflow)
        XCTAssertEqual(selection.shown.map { $0.hostID }, ["vps-a.example", "vps-b.example"])
    }

    // Zero hosts ⇒ empty, no overflow (degenerate, no crash).
    func testZeroHostsEmptyNoOverflow() {
        let selection = WidgetSelector.select([])
        XCTAssertTrue(selection.shown.isEmpty)
        XCTAssertEqual(selection.overflowCount, 0)
    }

    // Overflow only ever hides the LEAST severe hosts: with 6 reds + N vert, no
    // red is ever pushed into overflow (a red silently dropped would be fail-open).
    func testOverflowNeverHidesWorseThanShown() {
        var hosts = (0..<6).map { entry("vps-red-\($0).example", .rougeInjoignable) }
        hosts += (0..<4).map { entry("vps-green-\($0).example", .vert) }
        let selection = WidgetSelector.select(hosts)
        XCTAssertEqual(selection.overflowCount, 4)
        XCTAssertTrue(selection.shown.allSatisfy { $0.state == .rougeInjoignable },
                      "the 6 shown must be the worst; no red may fall into overflow")
    }
}
