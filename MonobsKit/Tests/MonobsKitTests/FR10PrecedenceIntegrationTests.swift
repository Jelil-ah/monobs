import XCTest
@testable import MonobsKit

// Story 2.2, Task 4 (AC1/AC5): the poll → snapshot → reduce chain under the FR10
// precedence, exercised through `SnapshotStore.record(...)` (the `PollOutcome`
// vocabulary) on SIMULATED facts — no real SSH, no real probe. Proves two
// end-to-end contracts that the pure truth table cannot, because they depend on
// how the snapshot transitions:
//
//   • CA-3 — `rougeInjoignable` is MAINTAINED across cycles by the persistence
//     of `sshFailureActive` in the snapshot (Story 1.3), and LEFT at the first
//     poll whose transport succeeds. No memory in the reducer.
//   • T-CONTRACT (F2 Option A, AD-10) — an invalid/absent report over a healthy
//     transport clears `sshFailureActive`, so the host follows the STALENESS
//     path and is NEVER `rougeInjoignable`. Red is reserved for the active SSH
//     transport failure. 2.2 adds nothing to `SnapshotStore` — it consumes it.
final class FR10PrecedenceIntegrationTests: XCTestCase {

    private let hostID = "vps-web.example"
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private let threshold: TimeInterval = 180

    private var facts: ReportFacts {
        ReportFacts(metrics: ["loadavg_1m": .number(0.42)], serverTimestamp: "2026-01-01T12:00:00Z")
    }

    private func reduce(_ store: SnapshotStore, now: Date, tailscaleLocalUp: Bool = true) -> HostState {
        StateReducer.reduce(store.snapshot(for: hostID), now: now, tailscaleLocalUp: tailscaleLocalUp, stalenessThreshold: threshold)
    }

    // CA-3 — the red is maintained across every cycle while the transport keeps
    // failing, then LEAVES at the first successful poll. Non-vacuous: the state
    // genuinely changes rougeInjoignable → vert.
    func testActiveFailureMaintainedThenLeavesOnSuccessfulPoll() {
        let store = SnapshotStore()
        // Transport failure ⇒ sshFailureActive raised ⇒ rougeInjoignable.
        store.record(.transportFailure(.sshExit255), forHost: hostID, receivedAt: t0)
        XCTAssertEqual(reduce(store, now: t0.addingTimeInterval(10)), .rougeInjoignable)
        // Still failing at the next cycle ⇒ still red (maintained by the snapshot
        // persistence, not by reducer memory).
        store.record(.transportFailure(.timeout), forHost: hostID, receivedAt: t0.addingTimeInterval(60))
        XCTAssertEqual(reduce(store, now: t0.addingTimeInterval(70)), .rougeInjoignable)
        // First successful poll ⇒ signal falls back ⇒ leaves red for vert.
        store.record(.validReport(facts), forHost: hostID, receivedAt: t0.addingTimeInterval(120))
        XCTAssertEqual(reduce(store, now: t0.addingTimeInterval(130)), .vert,
                       "rougeInjoignable must be LEFT at the first successful poll")
    }

    // T-CONTRACT — a valid report then an INVALID report over a healthy
    // transport: sshFailureActive stays false, freshness stays anchored on the
    // valid report (AD-10). The host is on the staleness path, NEVER red.
    func testInvalidReportOverHealthyTransportFollowsStalenessNeverRed() {
        let store = SnapshotStore()
        store.record(.validReport(facts), forHost: hostID, receivedAt: t0)
        store.record(.invalidReport(.notJSON), forHost: hostID, receivedAt: t0.addingTimeInterval(60))
        // Age anchored on t0 (the valid report), not on the invalid one. Within
        // threshold ⇒ vert (never red); beyond threshold ⇒ stale (never red).
        XCTAssertEqual(reduce(store, now: t0.addingTimeInterval(90)), .vert)
        let stale = reduce(store, now: t0.addingTimeInterval(300))
        XCTAssertEqual(stale, .stale, "invalid report over healthy transport ⇒ staleness path")
        XCTAssertNotEqual(stale, .rougeInjoignable, "F2 Option A: an invalid report must never be red")
    }

    // T-CONTRACT — an ABSENT report (server collector failed, transport OK) from
    // a pristine snapshot: sshFailureActive false, no valid data ⇒ stale, never
    // red. Proves "host up but collector dead" follows the grey path (F2 A).
    func testAbsentReportOverHealthyTransportIsStaleNeverRed() {
        let store = SnapshotStore()
        store.record(.reportAbsent(exitCode: 3), forHost: hostID, receivedAt: t0)
        let state = reduce(store, now: t0.addingTimeInterval(10))
        XCTAssertEqual(state, .stale, "absent report over healthy transport ⇒ staleness path")
        XCTAssertNotEqual(state, .rougeInjoignable, "F2 Option A: an absent report must never be red")
    }

    // T-CONTRACT crossover — active failure (red), then a poll whose TRANSPORT
    // succeeds but carries an INVALID report: the signal falls back, so the host
    // leaves red for the staleness path — NOT another red. Proves the boolean
    // reflects transport, not report validity (the AD-10 keystone).
    func testFailureThenInvalidReportLeavesRedForStaleness() {
        let store = SnapshotStore()
        store.record(.transportFailure(.timeout), forHost: hostID, receivedAt: t0)
        XCTAssertEqual(reduce(store, now: t0.addingTimeInterval(10)), .rougeInjoignable)
        // Transport now succeeds but the report is invalid ⇒ signal clears.
        store.record(.invalidReport(.versionUnknown(2)), forHost: hostID, receivedAt: t0.addingTimeInterval(60))
        let state = reduce(store, now: t0.addingTimeInterval(70))
        XCTAssertEqual(state, .stale, "no valid report ever ⇒ staleness path after the signal clears")
        XCTAssertNotEqual(state, .rougeInjoignable, "transport OK (even with invalid report) must leave the red")
    }

    // FR10.1 at the integration level — Tailscale down suppresses the red from
    // an active failure: same store, tailscaleLocalUp false ⇒ stale (CA-5).
    func testTailscaleDownSuppressesRedFromActiveFailure() {
        let store = SnapshotStore()
        store.record(.transportFailure(.sshExit255), forHost: hostID, receivedAt: t0)
        XCTAssertEqual(reduce(store, now: t0.addingTimeInterval(10), tailscaleLocalUp: true), .rougeInjoignable)
        XCTAssertEqual(reduce(store, now: t0.addingTimeInterval(10), tailscaleLocalUp: false), .stale,
                       "Tailscale down suppresses the active-failure red (U-3/CA-5)")
    }
}
