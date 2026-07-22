import XCTest
@testable import MonobsKit

final class HostPollingLoopTests: XCTestCase {
    private let hosts = [
        ObservedHost(name: "web", host: "vps-web.example", user: "deploy"),
        ObservedHost(name: "db", host: "vps-db.example", user: "deploy"),
    ]

    func testProductCadenceIsSixtySeconds() {
        XCTAssertEqual(HostPollingLoop.defaultCadence, 60)
    }

    func testOneCyclePollsEveryHostAndRecordsAtClientClock() {
        let store = SnapshotStore()
        let receivedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let facts = ReportFacts(metrics: ["sample": .number(1)],
                                serverTimestamp: "2026-01-01T12:00:00Z")
        let recorder = HostCallRecorder()
        let loop = HostPollingLoop(
            hosts: hosts,
            snapshotStore: store,
            cadence: 0.01,
            now: { receivedAt },
            pollHost: { host in
                recorder.append(host.host)
                return host.host == "vps-web.example"
                    ? .validReport(facts)
                    : .transportFailure(.sshExit255)
            }
        )

        loop.runOneCycle()

        XCTAssertEqual(recorder.values, ["vps-web.example", "vps-db.example"])
        XCTAssertEqual(store.snapshot(for: "vps-web.example"),
                       HostSnapshot(lastValidFacts: facts,
                                    lastValidReceivedAt: receivedAt,
                                    sshFailureActive: false))
        XCTAssertEqual(store.snapshot(for: "vps-db.example"),
                       HostSnapshot(lastValidFacts: nil,
                                    lastValidReceivedAt: nil,
                                    sshFailureActive: true))
    }

    func testInjectedShortCadenceRunsRepeatedCycles() {
        let calls = expectation(description: "two scheduled polls")
        calls.expectedFulfillmentCount = 2
        calls.assertForOverFulfill = false
        let loop = HostPollingLoop(
            hosts: [hosts[0]],
            snapshotStore: SnapshotStore(),
            cadence: 0.02,
            pollHost: { _ in
                calls.fulfill()
                return .reportAbsent(exitCode: 3)
            }
        )

        XCTAssertTrue(loop.start())
        wait(for: [calls], timeout: 1)
        loop.stop()
    }

    func testCycleStartTimesStayAnchoredWhenPollingConsumesCadenceFraction() {
        let starts = MonotonicStartRecorder()
        let twoStarts = expectation(description: "two anchored cycle starts")
        twoStarts.expectedFulfillmentCount = 2
        let loop = HostPollingLoop(
            hosts: [hosts[0]],
            snapshotStore: SnapshotStore(),
            cadence: 0.40,
            pollHost: { _ in
                if starts.appendNow() <= 2 { twoStarts.fulfill() }
                Thread.sleep(forTimeInterval: 0.20)
                return .reportAbsent(exitCode: 3)
            }
        )

        XCTAssertTrue(loop.start())
        wait(for: [twoStarts], timeout: 2)
        loop.stop()

        let values = starts.values
        XCTAssertGreaterThanOrEqual(values.count, 2)
        let interval = Double(values[1] - values[0]) / 1_000_000_000
        XCTAssertGreaterThan(interval, 0.30, "cycle started too early: \(interval)s")
        XCTAssertLessThan(interval, 0.52,
                          "cycle start drifted by poll duration instead of staying on the 0.40s deadline: \(interval)s")
    }

    func testZeroHostsRemainsIdle() {
        let recorder = HostCallRecorder()
        let loop = HostPollingLoop(
            hosts: [],
            snapshotStore: SnapshotStore(),
            cadence: 0.01,
            pollHost: { host in
                recorder.append(host.host)
                return .reportAbsent(exitCode: 3)
            }
        )

        XCTAssertFalse(loop.start())
        loop.runOneCycle()
        XCTAssertEqual(recorder.values, [])
    }
}

private final class MonotonicStartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    var values: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func appendNow() -> Int {
        lock.lock()
        storage.append(DispatchTime.now().uptimeNanoseconds)
        let count = storage.count
        lock.unlock()
        return count
    }
}

private final class HostCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
