import XCTest
@testable import MonobsKit

// Story 2.2, Task 4 (AC1/AC2/AC3/AC4/AC5): the single reducer under the FULL
// strict FR10 precedence — the T-STATE truth table over the reachable subset
// `{vert, rougeInjoignable, stale}`, with non-vacuous fail-closed checkers.
//
// This SUPERSEDES the Story 1.4 skeleton truth table: the reducer now CONSUMES
// `sshFailureActive` (and the new `tailscaleLocalUp` fact), so the 1.4
// invariance tests — `testSSHFailureActiveDoesNotChangeFreshHost/StaleHost`
// and the `{vert, stale}` codomain (`testCodomainIsVertOrStaleNeverRed`) — are
// DELIBERATELY INVERTED by 2.2 and removed here: a fresh host with an active
// SSH failure (Tailscale up) is now `.rougeInjoignable`, not `.vert`, and the
// codomain is `{vert, rougeInjoignable, stale}` (red IS expected).
//
// Every checker is proven non-vacuous by a fixture that makes it fire: the
// table produces all THREE reachable states, never `.rougeSeuil`; the
// `<=`/`<` boundary is pinned; the clock-skew fail-closed guard is pinned; the
// Tailscale-down override (red suppressed) is explicit; rule 10.2 is proven to
// beat both freshness AND the clock-skew guard (F-1, review Mary).
final class StateReducerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let threshold: TimeInterval = 180

    private var facts: ReportFacts {
        ReportFacts(metrics: ["loadavg_1m": .number(0.42)], serverTimestamp: "2026-01-01T12:00:00Z")
    }

    /// Snapshot whose last valid report was received `ageOffset` seconds before
    /// `now` (so `age == ageOffset`): nil ⇒ never received, negative ⇒ reception
    /// stamped in the FUTURE (clock skew), with the given transport-failure
    /// signal.
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

    private func reduce(_ snap: HostSnapshot, tailscaleLocalUp: Bool) -> HostState {
        StateReducer.reduce(snap, now: now, tailscaleLocalUp: tailscaleLocalUp, stalenessThreshold: threshold)
    }

    /// The full T-STATE truth table (2.2 reachable subset). Dimensions:
    /// `tailscaleLocalUp` ∈ {false, true} · `sshFailureActive` ∈ {false, true} ·
    /// age ∈ {never (nil), <0 (skew), <seuil, ==seuil, >seuil}. Each row's
    /// expected state is dictated by the strict order FR10.1 → 10.2 → 10.3 → 4.
    private var truthTable: [(line: Int, ts: Bool, ssh: Bool, ageOffset: TimeInterval?, expected: HostState, note: String)] {
        [
            // — Rule 10.1: tailscaleLocalUp == false overrides EVERYTHING ⇒ stale.
            //   Lines 1-2: RED SUPPRESSED. INTENDED (U-3/CA-5, honest grey silence,
            //   zero false red) but DEPENDS on probe reliability (Q4.3, DEBT G-2.2).
            (1,  false, true,  60,  .stale, "10.1 RED SUPPRESSED — fresh+failing but Tailscale down (U-3/CA-5; depends on probe, Q4.3/G-2.2)"),
            (2,  false, true,  nil, .stale, "10.1 red suppressed — never received + active failure"),
            (3,  false, false, 60,  .stale, "10.1 override — even fresh data goes grey"),
            (4,  false, false, 240, .stale, "10.1 override"),
            (13, false, true,  -60, .stale, "10.1 override beats BOTH active failure and clock skew"),
            // — Rule 10.2: Tailscale up + active failure ⇒ rougeInjoignable, IMMEDIATE,
            //   before ANY age evaluation. Active failure beats freshness (CA-3).
            (5,  true,  true,  60,  .rougeInjoignable, "10.2 immediate — active failure beats freshness"),
            (6,  true,  true,  nil, .rougeInjoignable, "10.2 — never received + active transport failure"),
            (7,  true,  true,  240, .rougeInjoignable, "10.2 — stale age is irrelevant under active failure"),
            (14, true,  true,  -60, .rougeInjoignable, "F-1 (Mary) — 10.2 short-circuits BEFORE the clock-skew guard"),
            // — Rule 10.3: Tailscale up + no active failure + not fresh ⇒ stale.
            (8,  true,  false, nil, .stale, "10.3 — never a valid report"),
            (9,  true,  false, -60, .stale, "10.3 clock-skew fail-closed preserved (1.4 #1)"),
            (10, true,  false, 240, .stale, "10.3 — CA-4, age > threshold"),
            // — Tier 4: Tailscale up + no failure + fresh ⇒ vert. rougeSeuil GATED 2.3.
            (11, true,  false, 180, .vert,  "tier 4 — boundary age == threshold ⇒ vert (<= preserved)"),
            (12, true,  false, 60,  .vert,  "tier 4 — CA-1 nominal; rougeSeuil GATED 2.3"),
        ]
    }

    // AC4: each combination produces the unique state dictated by the strict
    // order. Exact assertion per row — fails if a single state is wrong.
    func testTruthTableExactStatePerRow() {
        for row in truthTable {
            let state = reduce(snapshot(ageOffset: row.ageOffset, sshFailureActive: row.ssh),
                               tailscaleLocalUp: row.ts)
            XCTAssertEqual(state, row.expected, "T-STATE line \(row.line): \(row.note)")
        }
    }

    // Non-vacuity: the table must exercise ALL THREE reachable states — else a
    // vacuously always-stale (or never-red) reducer could pass.
    func testTruthTableProducesAllThreeReachableStates() {
        let produced = Set(truthTable.map {
            reduce(snapshot(ageOffset: $0.ageOffset, sshFailureActive: $0.ssh), tailscaleLocalUp: $0.ts)
        })
        XCTAssertTrue(produced.contains(.vert), "table must produce vert")
        XCTAssertTrue(produced.contains(.rougeInjoignable), "table must produce rougeInjoignable")
        XCTAssertTrue(produced.contains(.stale), "table must produce stale")
    }

    // Codomain (2.2 reachable subset): the reducer NEVER produces `.rougeSeuil`
    // — that tier is GATED to Story 2.3. Fails if 2.3 wiring leaks early.
    func testTruthTableNeverProducesRougeSeuil() {
        for row in truthTable {
            let state = reduce(snapshot(ageOffset: row.ageOffset, sshFailureActive: row.ssh),
                               tailscaleLocalUp: row.ts)
            XCTAssertNotEqual(state, .rougeSeuil, "T-STATE line \(row.line) leaked rougeSeuil (GATED 2.3)")
        }
    }

    // AC3 / FR10.1 — Tailscale down suppresses an otherwise-legitimate red. This
    // is the "rouge supprimé" line: fresh + active failure, but Tailscale down ⇒
    // stale, NOT rougeInjoignable. INTENDED (U-3/CA-5), depends on probe (Q4.3).
    // Non-vacuous: the SAME snapshot with Tailscale UP is rougeInjoignable.
    func testTailscaleDownSuppressesActiveFailureRed() {
        let failingFresh = snapshot(ageOffset: 60, sshFailureActive: true)
        XCTAssertEqual(reduce(failingFresh, tailscaleLocalUp: false), .stale,
                       "Tailscale down forces stale, red suppressed (U-3/CA-5)")
        XCTAssertEqual(reduce(failingFresh, tailscaleLocalUp: true), .rougeInjoignable,
                       "same snapshot with Tailscale up IS rougeInjoignable — proves the override flips")
    }

    // FR10.1 — with Tailscale down, EVERY age/failure combination is stale.
    func testTailscaleDownForcesStaleForEveryCombination() {
        for ssh in [false, true] {
            for ageOffset in [nil, -60, 60, 180, 240] as [TimeInterval?] {
                let state = reduce(snapshot(ageOffset: ageOffset, sshFailureActive: ssh),
                                   tailscaleLocalUp: false)
                XCTAssertEqual(state, .stale, "Tailscale down must force stale (ssh=\(ssh), age=\(String(describing: ageOffset)))")
            }
        }
    }

    // AC1 / FR10.2 — active failure beats freshness: a fresh host with an active
    // SSH failure (Tailscale up) is rougeInjoignable IMMEDIATELY, not vert. Pins
    // that rule 10.2 precedes any age evaluation. Non-vacuous: same age without
    // the failure is vert.
    func testActiveFailureBeatsFreshness() {
        let fresh = snapshot(ageOffset: 60, sshFailureActive: false)
        let freshFailing = snapshot(ageOffset: 60, sshFailureActive: true)
        XCTAssertEqual(reduce(fresh, tailscaleLocalUp: true), .vert)
        XCTAssertEqual(reduce(freshFailing, tailscaleLocalUp: true), .rougeInjoignable,
                       "active failure must beat freshness (10.2 immediate)")
    }

    // F-1 (review Mary) — rule 10.2 short-circuits BEFORE the clock-skew guard.
    // Tailscale up + active failure + age < 0 ⇒ rougeInjoignable, NOT stale. An
    // unreachable host whose clock drifts stays red, never grey. This fails if
    // an implementation placed the `guard age >= 0` (or any age evaluation)
    // BEFORE the `sshFailureActive` check — a reordering the 1.4 age guard makes
    // plausible. Lines 5-7 (age >= 0) do not catch it; line 9 (ssh=false) does
    // not catch it. Only this crossing pins the strongest invariant of the story.
    func testActiveFailureBeatsClockSkewGuard() {
        // receivedAt 60 s in the future ⇒ age == -60 (a clock-skew value that
        // rule 10.3 would classify stale). With an active failure it MUST be red.
        let skewedFailing = snapshot(ageOffset: -60, sshFailureActive: true)
        XCTAssertEqual(reduce(skewedFailing, tailscaleLocalUp: true), .rougeInjoignable,
                       "F-1: rule 10.2 must precede the clock-skew guard")
        // Non-vacuous control: the SAME skewed age WITHOUT the failure is stale
        // (rule 10.3) — so the red above is genuinely produced by rule 10.2, not
        // a spurious pass.
        let skewedClean = snapshot(ageOffset: -60, sshFailureActive: false)
        XCTAssertEqual(reduce(skewedClean, tailscaleLocalUp: true), .stale,
                       "clock skew without failure is fail-closed stale (control for F-1)")
    }

    // Clock skew fail-closed PRESERVED (Story 1.4 #1): Tailscale up, NO active
    // failure, a reception timestamp in the FUTURE (age < 0) ⇒ stale, never vert.
    // This fails if the FR10 wiring dropped the `age >= 0` guard.
    func testClockSkewNoFailureIsStaleNeverVert() {
        let skewed = HostSnapshot(lastValidFacts: facts,
                                  lastValidReceivedAt: now.addingTimeInterval(60),
                                  sshFailureActive: false)
        let state = reduce(skewed, tailscaleLocalUp: true)
        XCTAssertEqual(state, .stale)
        XCTAssertNotEqual(state, .vert, "negative age must never be vert (fail-closed)")
    }

    // Boundary pin (Q4.1): at exactly the threshold the host is vert. Fails if
    // `<=` is flipped to `<`.
    func testBoundaryAtThresholdIsVert() {
        XCTAssertEqual(reduce(snapshot(ageOffset: threshold, sshFailureActive: false), tailscaleLocalUp: true), .vert)
    }

    // Just past the threshold flips to stale — proves the boundary is the
    // discriminating edge. The epsilon (1 ms) stays well above the Double ulp of
    // `Date` at epoch magnitude (~5e-7 s), so the offset survives the
    // addingTimeInterval/timeIntervalSince round-trip.
    func testJustPastThresholdIsStale() {
        XCTAssertEqual(reduce(snapshot(ageOffset: threshold + 0.001, sshFailureActive: false), tailscaleLocalUp: true), .stale)
    }

    func testNeverReceivedNoFailureIsStale() {
        XCTAssertEqual(reduce(snapshot(ageOffset: nil, sshFailureActive: false), tailscaleLocalUp: true), .stale)
    }

    // The isolated default is the provisional 180 s (Q4.1) — asserted so a
    // silent change to the ratified default trips a test.
    func testDefaultThresholdIsProvisional180() {
        XCTAssertEqual(StateReducer.defaultStalenessThreshold, 180)
    }

    // Threshold is a genuine injected parameter: a short threshold makes an
    // otherwise-fresh host stale (Tailscale up, no failure).
    func testShortInjectedThresholdMakesHostStale() {
        let snap = snapshot(ageOffset: 60, sshFailureActive: false)
        XCTAssertEqual(StateReducer.reduce(snap, now: now, tailscaleLocalUp: true, stalenessThreshold: 180), .vert)
        XCTAssertEqual(StateReducer.reduce(snap, now: now, tailscaleLocalUp: true, stalenessThreshold: 30), .stale)
    }
}
