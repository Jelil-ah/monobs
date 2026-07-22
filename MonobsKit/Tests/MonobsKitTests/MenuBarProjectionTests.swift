import XCTest
@testable import MonobsKit

// Story 1.4, Task 4 (AC1/AC2/AC4) + Story 2.2 (AC3): the pure menu bar
// projection — aggregate = worst state, rows ordered AD-17, per-host age exposed
// (FR5), zero-host degenerate case fail-closed, no state re-derivation outside
// the reducer, and the FR10.1 Tailscale override forwarded to the reducer.
//
// Story 2.2: every `project(...)` call now passes the required `tailscaleLocalUp`
// argument (the projector forwards it to the reducer — it derives nothing). The
// nominal 1.4 cases pass `tailscaleLocalUp: true` to preserve their intent. The
// 1.4 skeleton invariance test `testSSHFailureActiveDoesNotAffectProjection` is
// SUPERSEDED — the reducer now consumes `sshFailureActive`, so an active failure
// (Tailscale up) drives the projection to `rougeInjoignable`.
final class MenuBarProjectionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let threshold: TimeInterval = 180

    private func host(_ id: String) -> ObservedHost {
        ObservedHost(name: id, host: id, user: "monobs", port: 22)
    }

    private var facts: ReportFacts {
        ReportFacts(metrics: ["loadavg_1m": .number(0.42)], serverTimestamp: "2026-01-01T12:00:00Z")
    }

    private func fresh(ageOffset: TimeInterval, ssh: Bool = false) -> HostSnapshot {
        HostSnapshot(lastValidFacts: facts,
                     lastValidReceivedAt: now.addingTimeInterval(-ageOffset),
                     sshFailureActive: ssh)
    }

    // AC1 nominal: fresh hosts (Tailscale up) ⇒ aggregate vert, each row vert
    // with exact age.
    func testAllFreshHostsAreVertWithExactAgeAndAggregateVert() {
        let hosts = [host("vps-web.example"), host("vps-db.example")]
        let snapshots = [
            "vps-web.example": fresh(ageOffset: 30),
            "vps-db.example": fresh(ageOffset: 90),
        ]
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: snapshots, now: now, tailscaleLocalUp: true, stalenessThreshold: threshold)
        XCTAssertEqual(projection.aggregate, .vert)
        XCTAssertEqual(projection.hosts.count, 2)
        // Tie in state ⇒ ordered by host ID ascending.
        XCTAssertEqual(projection.hosts.map { $0.hostID }, ["vps-db.example", "vps-web.example"])
        XCTAssertTrue(projection.hosts.allSatisfy { $0.state == .vert })
        let ageByHost = Dictionary(uniqueKeysWithValues: projection.hosts.map { ($0.hostID, $0.age) })
        XCTAssertEqual(ageByHost["vps-web.example"], 30)
        XCTAssertEqual(ageByHost["vps-db.example"], 90)
    }

    // AC2: one stale host ⇒ aggregate stale (worst state), ordered worst-first.
    func testStaleHostDrivesAggregateAndOrdersFirst() {
        let hosts = [host("vps-web.example"), host("vps-db.example")]
        let snapshots = [
            "vps-web.example": fresh(ageOffset: 30),      // vert
            "vps-db.example": fresh(ageOffset: 300),      // stale (> 180)
        ]
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: snapshots, now: now, tailscaleLocalUp: true, stalenessThreshold: threshold)
        XCTAssertEqual(projection.aggregate, .stale)
        XCTAssertEqual(projection.hosts.map { $0.hostID }, ["vps-db.example", "vps-web.example"])
        XCTAssertEqual(projection.hosts.map { $0.state }, [.stale, .vert])
    }

    // FR5 fail-closed: a configured host with no snapshot (never received) ⇒
    // stale, age nil — rendered "jamais", NEVER 0 s.
    func testNeverReceivedHostIsStaleWithNilAge() {
        let hosts = [host("vps-new.example")]
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: [:], now: now, tailscaleLocalUp: true, stalenessThreshold: threshold)
        XCTAssertEqual(projection.aggregate, .stale)
        XCTAssertEqual(projection.hosts.count, 1)
        XCTAssertEqual(projection.hosts[0].state, .stale)
        XCTAssertNil(projection.hosts[0].age)
        XCTAssertNotEqual(projection.hosts[0].age, 0, "never-received age must be nil, not 0 s")
    }

    // Clock skew (fail-closed, F1): a host whose last reception is timestamped
    // in the FUTURE (now < receivedAt) must NOT be vert and must NOT project a
    // negative age. The reducer classifies it stale; the projected age is nil.
    func testClockSkewFutureTimestampIsStaleWithNonNegativeAge() {
        let hosts = [host("vps-web.example")]
        let skewed = HostSnapshot(lastValidFacts: facts,
                                  lastValidReceivedAt: now.addingTimeInterval(45),
                                  sshFailureActive: false)
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: ["vps-web.example": skewed], now: now, tailscaleLocalUp: true, stalenessThreshold: threshold)
        XCTAssertEqual(projection.hosts[0].state, .stale, "future timestamp must be fail-closed stale, never vert")
        XCTAssertNotEqual(projection.hosts[0].state, .vert)
        if let age = projection.hosts[0].age {
            XCTAssertGreaterThanOrEqual(age, 0, "projected clock-skew age must never be negative")
        }
        XCTAssertNil(projection.hosts[0].age, "clock-skew age is projected as nil (unknown), never negative")
        XCTAssertEqual(projection.aggregate, .stale)
    }

    // Zero hosts ⇒ degenerate projection: aggregate nil, never vert; empty list.
    func testZeroHostsDegenerateNeverVert() {
        let projection = MenuBarProjector.project(hosts: [], snapshots: [:], now: now, tailscaleLocalUp: true, stalenessThreshold: threshold)
        XCTAssertNil(projection.aggregate)
        XCTAssertNotEqual(projection.aggregate, .vert)
        XCTAssertTrue(projection.hosts.isEmpty)
    }

    // AC4 / AD-11: the projection state is exactly the reducer's output — it
    // does not derive state independently. Checked at the boundary, where an
    // off-by-one re-derivation would diverge.
    func testProjectionStateMatchesReducerAtBoundary() {
        let hosts = [host("vps-web.example")]
        let snap = fresh(ageOffset: threshold)   // age == threshold ⇒ reducer says vert
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: ["vps-web.example": snap], now: now, tailscaleLocalUp: true, stalenessThreshold: threshold)
        XCTAssertEqual(projection.hosts[0].state,
                       StateReducer.reduce(snap, now: now, tailscaleLocalUp: true, stalenessThreshold: threshold))
        XCTAssertEqual(projection.hosts[0].state, .vert)
    }

    // Story 2.2 (supersedes testSSHFailureActiveDoesNotAffectProjection): the
    // reducer now consumes `sshFailureActive`. A fresh host with an active
    // transport failure (Tailscale up) projects `rougeInjoignable`, NOT vert —
    // and it keeps the age of its last valid data (FR5, age projection
    // unchanged). Non-vacuous: the same freshness WITHOUT the failure is vert.
    func testActiveFailureProjectsRougeInjoignableKeepingAge() {
        let hosts = [host("vps-web.example")]
        let clean = MenuBarProjector.project(hosts: hosts, snapshots: ["vps-web.example": fresh(ageOffset: 30, ssh: false)], now: now, tailscaleLocalUp: true, stalenessThreshold: threshold)
        let failing = MenuBarProjector.project(hosts: hosts, snapshots: ["vps-web.example": fresh(ageOffset: 30, ssh: true)], now: now, tailscaleLocalUp: true, stalenessThreshold: threshold)
        XCTAssertEqual(clean.aggregate, .vert)
        XCTAssertEqual(failing.aggregate, .rougeInjoignable)
        XCTAssertEqual(failing.hosts[0].state, .rougeInjoignable)
        // Age is a pure projection of the last valid data — an unreachable host
        // keeps its last-known age, it is not reset by the failure.
        XCTAssertEqual(failing.hosts[0].age, 30, "rougeInjoignable host keeps the age of its last valid data")
    }

    // AC3 / CA-5 — Tailscale-down override FLIPS the aggregate. A mixed host set
    // {one rougeInjoignable (active failure), one vert (fresh)} projected with
    // `tailscaleLocalUp: true` ⇒ aggregate rougeInjoignable, a red present; the
    // SAME set with `tailscaleLocalUp: false` ⇒ every host stale, aggregate
    // stale, ZERO red. Proves the override genuinely flips (non-vacuous).
    func testTailscaleOverrideFlipsMixedSetToAllStale() {
        let hosts = [host("vps-web.example"), host("vps-db.example")]
        let snapshots = [
            "vps-web.example": fresh(ageOffset: 30, ssh: true),   // would be rougeInjoignable
            "vps-db.example": fresh(ageOffset: 30, ssh: false),   // would be vert
        ]
        let up = MenuBarProjector.project(hosts: hosts, snapshots: snapshots, now: now, tailscaleLocalUp: true, stalenessThreshold: threshold)
        XCTAssertEqual(up.aggregate, .rougeInjoignable, "Tailscale up: the active failure surfaces as red")
        XCTAssertTrue(up.hosts.contains { $0.state == .rougeInjoignable }, "a red must be present when Tailscale is up")

        let down = MenuBarProjector.project(hosts: hosts, snapshots: snapshots, now: now, tailscaleLocalUp: false, stalenessThreshold: threshold)
        XCTAssertEqual(down.aggregate, .stale, "Tailscale down: aggregate forced stale")
        XCTAssertTrue(down.hosts.allSatisfy { $0.state == .stale }, "Tailscale down: every host stale, ex-reds included")
        XCTAssertFalse(down.hosts.contains { $0.state == .rougeInjoignable || $0.state == .rougeSeuil },
                       "Tailscale down: ZERO red survives (CA-5)")
    }
}
