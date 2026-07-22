import XCTest
@testable import MonobsKit

// Story 1.3, Task 4 (AC1/AC2/AC3): per-host snapshot store — exactly three
// facts (last valid facts, client reception timestamp, SSH failure boolean).
final class SnapshotTests: XCTestCase {

    private let hostID = "vps-web.example"
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_750_000_060)

    private var factsA: ReportFacts {
        ReportFacts(metrics: ["loadavg_1m": .number(0.42)], serverTimestamp: "2026-01-01T12:00:00Z")
    }
    private var factsB: ReportFacts {
        ReportFacts(metrics: ["loadavg_1m": .number(1.77)], serverTimestamp: "2026-01-01T12:01:00Z")
    }

    func testUnknownHostHasPristineSnapshot() {
        let store = SnapshotStore()
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: nil, sshFailureActive: false))
    }

    func testValidReportRecordsFactsAndClientReceptionTime() {
        let store = SnapshotStore()
        store.record(.validReport(factsA), forHost: hostID, receivedAt: t0)
        // Freshness = client reception instant (AD-10), asserted exactly — the
        // server `ts` inside the facts stays informative and must not leak
        // into lastValidReceivedAt.
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: factsA, lastValidReceivedAt: t0, sshFailureActive: false))
    }

    // MARK: F2 (REVIEW-MARY-STORY-1-3) — named pristine-snapshot fixtures.
    // On a pristine snapshot the fields are absent, so a before==after check
    // would be vacuously true; these tests assert the exact expected absence
    // instead, and testValidReportRecordsFactsAndClientReceptionTime proves
    // the same fields DO change on a valid report — the pair makes every
    // "unchanged" checker non-vacuous.

    func testPristineSnapshotPlusInvalidReportStaysPristine() {
        // Fixture « snapshot initial vierge + report invalide » (F2).
        let store = SnapshotStore()
        store.record(.invalidReport(.versionUnknown(2)), forHost: hostID, receivedAt: t0)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: nil, sshFailureActive: false))
    }

    func testPristineSnapshotPlusTransportFailureRaisesSignalOnly() {
        // Fixture « snapshot initial vierge + échec transport » (F2).
        let store = SnapshotStore()
        store.record(.transportFailure(.sshExit255), forHost: hostID, receivedAt: t0)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: nil, sshFailureActive: true))
    }

    func testPristineSnapshotPlusAbsentReportStaysPristine() {
        let store = SnapshotStore()
        store.record(.reportAbsent(exitCode: 3), forHost: hostID, receivedAt: t0)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: nil, sshFailureActive: false))
    }

    // MARK: transitions after a valid report — prior values asserted exactly

    func testTransportFailureKeepsFactsAndTimestampRaisesSignal() {
        let store = SnapshotStore()
        store.record(.validReport(factsA), forHost: hostID, receivedAt: t0)
        store.record(.transportFailure(.timeout), forHost: hostID, receivedAt: t1)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: factsA, lastValidReceivedAt: t0, sshFailureActive: true))
    }

    func testInvalidReportKeepsFreshnessAndDoesNotRaiseSignal() {
        let store = SnapshotStore()
        store.record(.validReport(factsA), forHost: hostID, receivedAt: t0)
        store.record(.invalidReport(.notJSON), forHost: hostID, receivedAt: t1)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: factsA, lastValidReceivedAt: t0, sshFailureActive: false))
    }

    func testAbsentReportBehavesLikeInvalidReport() {
        let store = SnapshotStore()
        store.record(.validReport(factsA), forHost: hostID, receivedAt: t0)
        store.record(.reportAbsent(exitCode: 3), forHost: hostID, receivedAt: t1)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: factsA, lastValidReceivedAt: t0, sshFailureActive: false))
    }

    func testNewValidReportReplacesFactsAndAdvancesFreshness() {
        // Proves the "unchanged" fields genuinely mutate when they should.
        let store = SnapshotStore()
        store.record(.validReport(factsA), forHost: hostID, receivedAt: t0)
        store.record(.validReport(factsB), forHost: hostID, receivedAt: t1)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: factsB, lastValidReceivedAt: t1, sshFailureActive: false))
    }

    func testValidReportAfterFailureClearsSignal() {
        // FR6 "first successful poll": transport succeeded, signal falls back.
        let store = SnapshotStore()
        store.record(.transportFailure(.sshExit255), forHost: hostID, receivedAt: t0)
        store.record(.validReport(factsA), forHost: hostID, receivedAt: t1)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: factsA, lastValidReceivedAt: t1, sshFailureActive: false))
    }

    func testCombinedTContractCase_FailureThenTransportOKWithInvalidReport() {
        // The AD-10 keystone (Task 4, explicit combined case): active failure,
        // then a poll whose TRANSPORT succeeds but whose report is invalid ⇒
        // the failure signal falls back AND freshness stays exactly where it
        // was. This proves the boolean reflects transport rather than report
        // validity.
        let store = SnapshotStore()
        store.record(.validReport(factsA), forHost: hostID, receivedAt: t0)
        store.record(.transportFailure(.timeout), forHost: hostID, receivedAt: t1)
        XCTAssertTrue(store.snapshot(for: hostID).sshFailureActive)
        store.record(.invalidReport(.versionUnknown(2)), forHost: hostID,
                     receivedAt: t1.addingTimeInterval(60))
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: factsA, lastValidReceivedAt: t0, sshFailureActive: false))
    }

    func testCombinedTContractCase_PristineVariant() {
        // Same keystone from a pristine snapshot (F2 crossover): failure on a
        // never-seen host, then transport OK + invalid report ⇒ signal falls
        // back, fields stay absent.
        let store = SnapshotStore()
        store.record(.transportFailure(.sshExit255), forHost: hostID, receivedAt: t0)
        store.record(.invalidReport(.notJSON), forHost: hostID, receivedAt: t1)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: nil, sshFailureActive: false))
    }

    // MARK: multi-host isolation and determinism

    func testHostsAreIsolated() {
        let store = SnapshotStore()
        let other = "vps-db.example"
        store.record(.validReport(factsA), forHost: hostID, receivedAt: t0)
        store.record(.transportFailure(.sshExit255), forHost: other, receivedAt: t0)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: factsA, lastValidReceivedAt: t0, sshFailureActive: false))
        XCTAssertEqual(store.snapshot(for: other),
                       HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: nil, sshFailureActive: true))
        XCTAssertEqual(Set(store.allSnapshots().keys), [hostID, other])
    }

    func testTransitionsAreDeterministicUnderArbitraryOrder() {
        // Any outcome sequence preserves the last valid report and follows the
        // latest transport verdict, regardless of interleaving.
        let store = SnapshotStore()
        store.record(.invalidReport(.notJSON), forHost: hostID, receivedAt: t0)
        store.record(.transportFailure(.timeout), forHost: hostID, receivedAt: t0)
        store.record(.validReport(factsB), forHost: hostID, receivedAt: t0)
        store.record(.reportAbsent(exitCode: 7), forHost: hostID, receivedAt: t1)
        store.record(.transportFailure(.sshExit255), forHost: hostID, receivedAt: t1)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: factsB, lastValidReceivedAt: t0, sshFailureActive: true))
    }
}
