import XCTest
@testable import MonobsKit

// Story 2.3, Q2 (client thresholds): the tier-4 `.rougeSeuil` decision. These
// tests pin the ONE new behavior 2.3 adds to the reducer — a fresh host, no
// active failure, Tailscale up, that breaches at least one client-computed
// threshold becomes `.rougeSeuil` instead of `.vert`. Everything ABOVE tier 4
// (Tailscale-down, active-failure, staleness) is owned by StateReducerTests
// (2.2) and only re-checked here as PRECEDENCE (seuil never masks a higher red).
//
// Determinism over floats: the reducer computes `1 − avail/total`,
// `avail/total`, `load/nproc` in IEEE-754 `Double` (bit-identical on the M4
// ARM64 target and any SSE host). Every boundary value below was computed in
// that exact arithmetic, NOT by decimal intuition — the disk `1 − 100/1000`
// rounds back to EXACTLY the `0.90` double, so the 90.0 % boundary is a true
// equality; the RAM `100/1000` does NOT (`0.1+ε > 1−0.9`), so its inclusive
// boundary is pinned on an exactly-representable dyadic fraction (3/32) instead.
// Each boundary is proven both ways: the breaching side AND its non-breaching
// neighbor, so a vacuous always-red / always-vert predicate cannot pass.
//
// Privacy (AD-15): fixtures use RFC 2606 names only; the metric values are
// synthetic ratios, never a real host's telemetry.
final class StateReducerThresholdTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let threshold: TimeInterval = 180

    /// A FRESH snapshot (age `-ageOffset` inverted → default age 60 s < 180 s),
    /// no active failure, carrying the given raw metric facts. Reaching tier 4
    /// requires exactly this: Tailscale up (passed at `reduce`), no ssh failure,
    /// fresh valid data. `serverTimestamp` is an RFC 2606-safe placeholder.
    private func freshSnapshot(_ metrics: [String: JSONValue],
                               ageOffset: TimeInterval = 60,
                               sshFailureActive: Bool = false) -> HostSnapshot {
        HostSnapshot(lastValidFacts: ReportFacts(metrics: metrics,
                                                 serverTimestamp: "2026-01-01T12:00:00Z"),
                     lastValidReceivedAt: now.addingTimeInterval(-ageOffset),
                     sshFailureActive: sshFailureActive)
    }

    private func reduce(_ snap: HostSnapshot,
                        tailscaleLocalUp: Bool = true,
                        thresholds: SeuilConfig = .defaults) -> HostState {
        StateReducer.reduce(snap, now: now, tailscaleLocalUp: tailscaleLocalUp,
                            stalenessThreshold: threshold, thresholds: thresholds)
    }

    // A metrics dict that breaches on disk alone (used == 0.90 exactly) — reused
    // by the precedence tests as "a host that WOULD be rougeSeuil at tier 4".
    private var diskBreachingMetrics: [String: JSONValue] {
        ["disk_avail_kib": .number(100), "disk_total_kib": .number(1000)]
    }

    // MARK: - Disk boundary (op: 1 − avail/total ≥ diskUsedFraction, default 0.90)

    // 89.9 % used ⇒ vert. avail=101/total=1000 ⇒ used == 0.899, comfortably below
    // 0.90 (no float razor).
    func testDiskBelowThresholdIsVert() {
        let snap = freshSnapshot(["disk_avail_kib": .number(101), "disk_total_kib": .number(1000)])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // 90.0 % used ⇒ rougeSeuil, INCLUSIVE. avail=100/total=1000 ⇒ `1 − 100/1000`
    // rounds back to EXACTLY the `0.90` double (verified in IEEE-754), so this is
    // a true equality at the boundary — it fails if `>=` is weakened to `>`.
    func testDiskAtThresholdIsRougeSeuilInclusive() {
        XCTAssertEqual(reduce(freshSnapshot(diskBreachingMetrics)), .rougeSeuil)
    }

    // 90.1 % used ⇒ rougeSeuil. avail=99/total=1000 ⇒ used == 0.901, above 0.90.
    func testDiskAboveThresholdIsRougeSeuil() {
        let snap = freshSnapshot(["disk_avail_kib": .number(99), "disk_total_kib": .number(1000)])
        XCTAssertEqual(reduce(snap), .rougeSeuil)
    }

    // MARK: - RAM boundary (op: avail/total ≤ 1 − ramUsedFraction, default 0.90)

    // 9.9 % available ⇒ rougeSeuil. avail=99/total=1000 ⇒ 0.099 ≤ 0.10.
    func testRAMBelowAvailableThresholdIsRougeSeuil() {
        let snap = freshSnapshot(["mem_available_kib": .number(99), "mem_total_kib": .number(1000)])
        XCTAssertEqual(reduce(snap), .rougeSeuil)
    }

    // 10.1 % available ⇒ vert. avail=101/total=1000 ⇒ 0.101 > 0.10.
    func testRAMAboveAvailableThresholdIsVert() {
        let snap = freshSnapshot(["mem_available_kib": .number(101), "mem_total_kib": .number(1000)])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // RAM inclusive boundary, pinned on an EXACT dyadic ratio. With defaults the
    // "10.0 % pile" case (100/1000) is `0.1+ε`, which is > `1 − 0.90` and lands
    // vert — a genuine float artifact, NOT a bug (the reducer never claims a
    // false red). So `<=` inclusivity is proven where equality is exact:
    // avail=3/total=32 ⇒ 0.09375, against a custom threshold whose `1 − ram`
    // equals 0.09375 (ram = 0.90625). 0.09375 ≤ 0.09375 ⇒ rougeSeuil; this fails
    // if `<=` is weakened to `<`. (Also exercises the injected `thresholds:`.)
    func testRAMAtThresholdIsRougeSeuilInclusive() {
        let config = SeuilConfig(diskUsedFraction: 0.90, ramUsedFraction: 0.90625, loadPerCPU: 2.0)
        let snap = freshSnapshot(["mem_available_kib": .number(3), "mem_total_kib": .number(32)])
        XCTAssertEqual(reduce(snap, thresholds: config), .rougeSeuil)
        // Non-vacuous control: 4/32 == 0.125 > 0.09375 ⇒ vert under the SAME config.
        let clean = freshSnapshot(["mem_available_kib": .number(4), "mem_total_kib": .number(32)])
        XCTAssertEqual(reduce(clean, thresholds: config), .vert)
    }

    // MARK: - Load boundary (op: loadavg_1m/nproc ≥ loadPerCPU, default 2.0)

    // 1.99 per CPU ⇒ vert. load=7.96/nproc=4 ⇒ 1.99 < 2.0.
    func testLoadBelowThresholdIsVert() {
        let snap = freshSnapshot(["loadavg_1m": .number(7.96), "nproc": .number(4)])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // 2.0 per CPU ⇒ rougeSeuil, INCLUSIVE. load=8.0/nproc=4 ⇒ 8.0/4.0 == 2.0
    // EXACTLY (both dyadic), equal to the default 2.0 ⇒ fires with `.defaults`.
    // Fails if `>=` is weakened to `>`.
    func testLoadAtThresholdIsRougeSeuilInclusive() {
        let snap = freshSnapshot(["loadavg_1m": .number(8.0), "nproc": .number(4)])
        XCTAssertEqual(reduce(snap), .rougeSeuil)
    }

    // 2.01 per CPU ⇒ rougeSeuil. load=8.04/nproc=4 ⇒ 2.01 > 2.0.
    func testLoadAboveThresholdIsRougeSeuil() {
        let snap = freshSnapshot(["loadavg_1m": .number(8.04), "nproc": .number(4)])
        XCTAssertEqual(reduce(snap), .rougeSeuil)
    }

    // MARK: - OR semantics (any single breach suffices; several ⇒ still one red)

    // Three criteria simultaneously in breach ⇒ rougeSeuil (the OR collapses to a
    // single bare `.rougeSeuil`, no severity materialized).
    func testAllThreeCriteriaBreachIsRougeSeuil() {
        let snap = freshSnapshot([
            "disk_avail_kib": .number(50), "disk_total_kib": .number(1000),
            "mem_available_kib": .number(50), "mem_total_kib": .number(1000),
            "loadavg_1m": .number(16.0), "nproc": .number(4),
        ])
        XCTAssertEqual(reduce(snap), .rougeSeuil)
    }

    // Load ALONE breaches while disk and RAM are healthy ⇒ still rougeSeuil (a
    // single OR term is sufficient; a wrongly-AND'd predicate would return vert).
    func testSingleCriterionBreachIsSufficient() {
        let snap = freshSnapshot([
            "disk_avail_kib": .number(500), "disk_total_kib": .number(1000),   // 50 % used, healthy
            "mem_available_kib": .number(500), "mem_total_kib": .number(1000), // 50 % free, healthy
            "loadavg_1m": .number(12.0), "nproc": .number(4),                  // 3.0/CPU ⇒ breach
        ])
        XCTAssertEqual(reduce(snap), .rougeSeuil)
    }

    // MARK: - Graceful degradation (CRITICAL: a missing/invalid fact ⇒ vert, never red)

    // An OLD report predating 2.3 — loadavg + uptime + mem_available, but NONE of
    // the new denominators (no nproc, no mem_total, no disk_*) ⇒ every criterion
    // is skipped ⇒ vert. No false red on legacy telemetry.
    func testLegacyMetricsWithoutNewKeysIsVert() {
        let snap = freshSnapshot([
            "loadavg_1m": .number(0.42),
            "uptime_seconds": .number(123456),
            "mem_available_kib": .number(100),   // present, but no mem_total ⇒ RAM criterion skipped
        ])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // Zero denominator ⇒ criterion skipped, NO crash, NO red. disk_total_kib == 0
    // must never divide-by-zero into a false breach.
    func testZeroDiskTotalIsVertNoCrash() {
        let snap = freshSnapshot(["disk_avail_kib": .number(0), "disk_total_kib": .number(0)])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // Zero nproc ⇒ load criterion skipped (guard nproc > 0), vert.
    func testZeroNprocIsVertNoCrash() {
        let snap = freshSnapshot(["loadavg_1m": .number(9.9), "nproc": .number(0)])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // A non-numeric fact (JSON string where a number is expected) ⇒ numericFact
    // returns nil ⇒ criterion skipped ⇒ vert. A malformed disk_total can never
    // manufacture a red.
    func testNonNumericFactSkipsCriterionIsVert() {
        let snap = freshSnapshot([
            "disk_avail_kib": .number(10),
            "disk_total_kib": .string("lots"),   // non-numeric ⇒ skipped
        ])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // Missing numerator with present denominator ⇒ skipped (both facts required).
    func testMissingNumeratorIsVert() {
        let snap = freshSnapshot(["mem_total_kib": .number(1000)])   // no mem_available_kib
        XCTAssertEqual(reduce(snap), .vert)
    }

    // DEVRAIT-1: a NEGATIVE disk `avail` is a valid JSON number yet physically
    // out of domain. Without the `avail >= 0` guard it would compute
    // `1 − (−1000/1000) = 2.0 ≥ 0.90` and manufacture a FALSE rougeSeuil. It must
    // degrade gracefully to vert (criterion skipped), no crash.
    func testNegativeDiskAvailIsVert() {
        let snap = freshSnapshot(["disk_avail_kib": .number(-1000), "disk_total_kib": .number(1000)])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // DEVRAIT-1: a NEGATIVE RAM `avail` would compute `−50/1000 = −0.05 ≤ 0.10`
    // and manufacture a FALSE rougeSeuil without the `avail >= 0` guard. Skipped
    // ⇒ vert.
    func testNegativeRAMAvailIsVert() {
        let snap = freshSnapshot(["mem_available_kib": .number(-50), "mem_total_kib": .number(1000)])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // DEVRAIT-1 (upper bound): a disk `avail` GREATER than `total` is also out of
    // domain (`1 − 2000/1000 = −1.0`, no breach on its own, but the value is
    // impossible) ⇒ criterion skipped ⇒ vert. Pins the `avail <= total` guard.
    func testDiskAvailAboveTotalIsVert() {
        let snap = freshSnapshot(["disk_avail_kib": .number(2000), "disk_total_kib": .number(1000)])
        XCTAssertEqual(reduce(snap), .vert)
    }

    // MARK: - Injection (thresholds: is honored, not a hard-coded 0.90)

    // A disk at 50 % used is vert under `.defaults` but rougeSeuil under a config
    // whose diskUsedFraction is 0.50 — proving the tier-4 predicate reads the
    // injected `SeuilConfig`, never a literal.
    func testInjectedThresholdChangesOutcome() {
        let snap = freshSnapshot(["disk_avail_kib": .number(500), "disk_total_kib": .number(1000)])
        XCTAssertEqual(reduce(snap), .vert)
        let strict = SeuilConfig(diskUsedFraction: 0.50, ramUsedFraction: 0.90, loadPerCPU: 2.0)
        XCTAssertEqual(reduce(snap, thresholds: strict), .rougeSeuil)
    }

    // MARK: - Precedence (rougeSeuil is tier 4 — every higher red/grey masks it)

    // FR10.2: an active SSH failure ⇒ rougeInjoignable even when the metrics would
    // breach a threshold. Injoignable outranks seuil. Non-vacuous: the SAME
    // breaching metrics WITHOUT the failure are rougeSeuil.
    func testActiveFailureMasksSeuil() {
        let breaching = diskBreachingMetrics
        XCTAssertEqual(reduce(freshSnapshot(breaching, sshFailureActive: true)), .rougeInjoignable,
                       "active failure (10.2) must mask a tier-4 breach")
        XCTAssertEqual(reduce(freshSnapshot(breaching, sshFailureActive: false)), .rougeSeuil,
                       "control: same breach without failure IS rougeSeuil")
    }

    // FR10.1: Tailscale down ⇒ stale, breach suppressed. The override precedes any
    // threshold evaluation. Non-vacuous: Tailscale up flips it to rougeSeuil.
    func testTailscaleDownMasksSeuil() {
        let snap = freshSnapshot(diskBreachingMetrics)
        XCTAssertEqual(reduce(snap, tailscaleLocalUp: false), .stale,
                       "Tailscale down (10.1) suppresses a tier-4 breach")
        XCTAssertEqual(reduce(snap, tailscaleLocalUp: true), .rougeSeuil,
                       "control: same breach with Tailscale up IS rougeSeuil")
    }

    // FR10.3: stale data (age > threshold) ⇒ stale, breach suppressed. Tier 4 is
    // AFTER the staleness gate, so old breaching data never reddens on seuil.
    // Non-vacuous: the same breaching metrics FRESH are rougeSeuil.
    func testStalenessMasksSeuil() {
        let stale = freshSnapshot(diskBreachingMetrics, ageOffset: threshold + 1)
        XCTAssertEqual(reduce(stale), .stale, "age past threshold (10.3) suppresses a tier-4 breach")
        let fresh = freshSnapshot(diskBreachingMetrics, ageOffset: 60)
        XCTAssertEqual(reduce(fresh), .rougeSeuil, "control: same breach fresh IS rougeSeuil")
    }
}
