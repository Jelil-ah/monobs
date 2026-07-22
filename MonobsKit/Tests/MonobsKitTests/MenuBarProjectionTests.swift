import XCTest
@testable import MonobsKit

// Story 1.4, Task 4 (AC1/AC2/AC4): the pure menu bar projection — aggregate =
// worst state, rows ordered AD-17, per-host age exposed (FR5), zero-host
// degenerate case fail-closed, and no state re-derivation outside the reducer.
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

    // AC1 nominal: fresh hosts ⇒ aggregate vert, each row vert with exact age.
    func testAllFreshHostsAreVertWithExactAgeAndAggregateVert() {
        let hosts = [host("vps-web.example"), host("vps-db.example")]
        let snapshots = [
            "vps-web.example": fresh(ageOffset: 30),
            "vps-db.example": fresh(ageOffset: 90),
        ]
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: snapshots, now: now, stalenessThreshold: threshold)
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
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: snapshots, now: now, stalenessThreshold: threshold)
        XCTAssertEqual(projection.aggregate, .stale)
        XCTAssertEqual(projection.hosts.map { $0.hostID }, ["vps-db.example", "vps-web.example"])
        XCTAssertEqual(projection.hosts.map { $0.state }, [.stale, .vert])
    }

    // FR5 fail-closed: a configured host with no snapshot (never received) ⇒
    // stale, age nil — rendered "jamais", NEVER 0 s.
    func testNeverReceivedHostIsStaleWithNilAge() {
        let hosts = [host("vps-new.example")]
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: [:], now: now, stalenessThreshold: threshold)
        XCTAssertEqual(projection.aggregate, .stale)
        XCTAssertEqual(projection.hosts.count, 1)
        XCTAssertEqual(projection.hosts[0].state, .stale)
        XCTAssertNil(projection.hosts[0].age)
        XCTAssertNotEqual(projection.hosts[0].age, 0, "never-received age must be nil, not 0 s")
    }

    // Clock skew (fail-closed, F1): a host whose last reception is timestamped
    // in the FUTURE (now < receivedAt — a wall-clock jump backward on the client
    // that also stamps `now`, AD-10) must NOT be vert and must NOT project a
    // negative age. The reducer classifies it stale; the projected age is nil
    // (unknown), never a negative interval that would render "il y a -N s".
    // Fails against the pre-fix code (which returned vert and age -45).
    func testClockSkewFutureTimestampIsStaleWithNonNegativeAge() {
        let hosts = [host("vps-web.example")]
        // receivedAt 45 s in the future ⇒ raw age would be -45.
        let skewed = HostSnapshot(lastValidFacts: facts,
                                  lastValidReceivedAt: now.addingTimeInterval(45),
                                  sshFailureActive: false)
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: ["vps-web.example": skewed], now: now, stalenessThreshold: threshold)
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
        let projection = MenuBarProjector.project(hosts: [], snapshots: [:], now: now, stalenessThreshold: threshold)
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
        let projection = MenuBarProjector.project(hosts: hosts, snapshots: ["vps-web.example": snap], now: now, stalenessThreshold: threshold)
        XCTAssertEqual(projection.hosts[0].state,
                       StateReducer.reduce(snap, now: now, stalenessThreshold: threshold))
        XCTAssertEqual(projection.hosts[0].state, .vert)
    }

    // sshFailureActive does not influence the projection (seam 2.2): same
    // freshness, toggled signal ⇒ identical projection.
    func testSSHFailureActiveDoesNotAffectProjection() {
        let hosts = [host("vps-web.example")]
        let clean = MenuBarProjector.project(hosts: hosts, snapshots: ["vps-web.example": fresh(ageOffset: 30, ssh: false)], now: now, stalenessThreshold: threshold)
        let failing = MenuBarProjector.project(hosts: hosts, snapshots: ["vps-web.example": fresh(ageOffset: 30, ssh: true)], now: now, stalenessThreshold: threshold)
        XCTAssertEqual(clean, failing)
        XCTAssertEqual(clean.aggregate, .vert)
    }
}
