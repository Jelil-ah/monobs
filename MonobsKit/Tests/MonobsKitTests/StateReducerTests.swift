import XCTest
@testable import MonobsKit

// Story 1.4, Task 2 (AC1/AC2): the skeleton reducer — the T-STATE truth table
// restricted to the `{vert, stale}` subset, plus the fail-closed codomain test.
//
// Every checker is proven non-vacuous by a fixture that makes it fire: positive
// `vert` AND `stale` rows are both present, the `<=`/`<` boundary is pinned, the
// `sshFailureActive` invariance is proven by paired rows, and the codomain test
// fails if any red ever leaks.
final class StateReducerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let threshold: TimeInterval = 180

    private var facts: ReportFacts {
        ReportFacts(metrics: ["loadavg_1m": .number(0.42)], serverTimestamp: "2026-01-01T12:00:00Z")
    }

    /// Snapshot whose last valid report was received `ageOffset` seconds before
    /// `now` (nil ⇒ never received), with the given transport-failure signal.
    private func snapshot(ageOffset: TimeInterval?, sshFailureActive: Bool) -> HostSnapshot {
        if let ageOffset {
            return HostSnapshot(lastValidFacts: facts,
                                lastValidReceivedAt: now.addingTimeInterval(-ageOffset),
                                sshFailureActive: sshFailureActive)
        }
        return HostSnapshot(lastValidFacts: nil,
                            lastValidReceivedAt: nil,
                            sshFailureActive: sshFailureActive)
    }

    /// The T-STATE rows (skeleton subset). `ageOffset` is relative to the 180 s
    /// threshold: negative (clock skew), nil, <, ==, >.
    private var truthTable: [(line: Int, ageOffset: TimeInterval?, ssh: Bool, expected: HostState)] {
        [
            (1, nil, false, .stale),   // never received
            (2, nil, true,  .stale),   // never received — ssh ignored (seam 2.2)
            (3, 60,  false, .vert),    // age < threshold
            (4, 60,  true,  .vert),    // age < threshold — ssh ignored (3↔4)
            (5, 180, false, .vert),    // age == threshold (boundary ≤ ⇒ vert)
            (6, 240, false, .stale),   // age > threshold
            (7, 240, true,  .stale),   // age > threshold — ssh ignored (6↔7)
            (8, -60, false, .stale),   // clock skew: receivedAt in the future ⇒ age < 0 ⇒ fail-closed stale
        ]
    }

    func testTruthTableExactStatePerRow() {
        for row in truthTable {
            let state = StateReducer.reduce(snapshot(ageOffset: row.ageOffset, sshFailureActive: row.ssh),
                                            now: now, stalenessThreshold: threshold)
            XCTAssertEqual(state, row.expected, "T-STATE line \(row.line)")
        }
    }

    // Non-vacuity of the table checker: it must exercise BOTH outcomes, else a
    // vacuously always-vert (or always-stale) reducer could pass.
    func testTruthTableExercisesBothVertAndStale() {
        let produced = Set(truthTable.map {
            StateReducer.reduce(snapshot(ageOffset: $0.ageOffset, sshFailureActive: $0.ssh),
                                now: now, stalenessThreshold: threshold)
        })
        XCTAssertTrue(produced.contains(.vert), "table must produce vert")
        XCTAssertTrue(produced.contains(.stale), "table must produce stale")
    }

    // Boundary pin (Q4.1): at exactly the threshold the host is vert. This row
    // fails if `<=` is flipped to `<`.
    func testBoundaryAtThresholdIsVert() {
        let state = StateReducer.reduce(snapshot(ageOffset: threshold, sshFailureActive: false),
                                        now: now, stalenessThreshold: threshold)
        XCTAssertEqual(state, .vert)
    }

    // Just past the threshold flips to stale — proves the boundary is the
    // discriminating edge, not an arbitrary offset. The epsilon (1 ms) stays
    // well above the Double ulp of `Date` at epoch magnitude (~5e-7 s), so the
    // offset survives the addingTimeInterval/timeIntervalSince round-trip.
    func testJustPastThresholdIsStale() {
        let state = StateReducer.reduce(snapshot(ageOffset: threshold + 0.001, sshFailureActive: false),
                                        now: now, stalenessThreshold: threshold)
        XCTAssertEqual(state, .stale)
    }

    // sshFailureActive has no effect in the skeleton (seam 2.2): same freshness,
    // toggled signal ⇒ same state. Proven on both a fresh row (3↔4) and a stale
    // row (6↔7).
    func testSSHFailureActiveDoesNotChangeFreshHost() {
        let fresh = snapshot(ageOffset: 60, sshFailureActive: false)
        let freshFailing = snapshot(ageOffset: 60, sshFailureActive: true)
        XCTAssertEqual(StateReducer.reduce(fresh, now: now, stalenessThreshold: threshold), .vert)
        XCTAssertEqual(StateReducer.reduce(freshFailing, now: now, stalenessThreshold: threshold), .vert)
    }

    func testSSHFailureActiveDoesNotChangeStaleHost() {
        let stale = snapshot(ageOffset: 240, sshFailureActive: false)
        let staleFailing = snapshot(ageOffset: 240, sshFailureActive: true)
        XCTAssertEqual(StateReducer.reduce(stale, now: now, stalenessThreshold: threshold), .stale)
        XCTAssertEqual(StateReducer.reduce(staleFailing, now: now, stalenessThreshold: threshold), .stale)
    }

    func testNeverReceivedIsStale() {
        XCTAssertEqual(StateReducer.reduce(snapshot(ageOffset: nil, sshFailureActive: false),
                                           now: now, stalenessThreshold: threshold), .stale)
    }

    // Clock skew (fail-closed, F1): a reception timestamp in the FUTURE (age < 0,
    // a wall-clock jump backward on the client clock that also stamps `now`,
    // AD-10) is not reliably fresh data — the reducer must return .stale, never
    // .vert. This fails if a negative age leaks to vert (the fail-open this fix
    // closes: without the `age >= 0` guard, `age <= threshold` is true and a
    // dead host would show vert during the skew window).
    func testNegativeAgeClockSkewIsStaleNeverVert() {
        // receivedAt 60 s in the future ⇒ age == -60 (well within `<= 180`).
        let skewed = HostSnapshot(lastValidFacts: facts,
                                  lastValidReceivedAt: now.addingTimeInterval(60),
                                  sshFailureActive: false)
        let state = StateReducer.reduce(skewed, now: now, stalenessThreshold: threshold)
        XCTAssertEqual(state, .stale)
        XCTAssertNotEqual(state, .vert, "negative age must never be vert (fail-closed)")
    }

    // Fail-closed codomain: across the whole table the reducer returns only
    // `.vert` or `.stale` — never a red. This fails if anyone lets a red leak
    // into the skeleton.
    func testCodomainIsVertOrStaleNeverRed() {
        for row in truthTable {
            let state = StateReducer.reduce(snapshot(ageOffset: row.ageOffset, sshFailureActive: row.ssh),
                                            now: now, stalenessThreshold: threshold)
            XCTAssertTrue(state == .vert || state == .stale, "T-STATE line \(row.line) leaked \(state)")
            XCTAssertNotEqual(state, .rougeSeuil, "T-STATE line \(row.line)")
            XCTAssertNotEqual(state, .rougeInjoignable, "T-STATE line \(row.line)")
        }
    }

    // The isolated default is the provisional 180 s (Q4.1) — asserted so a
    // silent change to the ratified default trips a test.
    func testDefaultThresholdIsProvisional180() {
        XCTAssertEqual(StateReducer.defaultStalenessThreshold, 180)
    }

    // Threshold is a genuine injected parameter: a short threshold makes an
    // otherwise-fresh host stale.
    func testShortInjectedThresholdMakesHostStale() {
        let snap = snapshot(ageOffset: 60, sshFailureActive: false)
        XCTAssertEqual(StateReducer.reduce(snap, now: now, stalenessThreshold: 180), .vert)
        XCTAssertEqual(StateReducer.reduce(snap, now: now, stalenessThreshold: 30), .stale)
    }
}
