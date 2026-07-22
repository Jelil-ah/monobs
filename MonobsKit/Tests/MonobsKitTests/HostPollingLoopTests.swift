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
        let initialTime: UInt64 = 10_000_000_000
        let cadenceNanoseconds: UInt64 = 400_000_000
        let pollDurationNanoseconds: UInt64 = 200_000_000
        let scheduler = VirtualPollingScheduler(now: initialTime)
        let starts = MonotonicStartRecorder()
        let loop = HostPollingLoop(
            hosts: [hosts[0]],
            snapshotStore: SnapshotStore(),
            cadence: 0.40,
            scheduler: scheduler,
            pollHost: { _ in
                starts.append(scheduler.nowNanoseconds())
                scheduler.advance(by: pollDurationNanoseconds)
                return .reportAbsent(exitCode: 3)
            }
        )

        XCTAssertTrue(loop.start())
        XCTAssertEqual(scheduler.scheduledDeadlines, [initialTime])
        XCTAssertTrue(scheduler.runNext())
        XCTAssertTrue(scheduler.runNext())
        loop.stop()

        // Advancing the virtual clock inside polling models work without wall-clock
        // jitter. Scheduling after that work would produce t0 + 0.60s here, so these
        // exact grid assertions continue to catch the original cadence-drift bug.
        XCTAssertEqual(starts.values,
                       [initialTime, initialTime + cadenceNanoseconds])
        XCTAssertEqual(scheduler.scheduledDeadlines,
                       [initialTime,
                        initialTime + cadenceNanoseconds,
                        initialTime + 2 * cadenceNanoseconds])
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

    func append(_ value: UInt64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class VirtualPollingScheduler: HostPollingScheduling, @unchecked Sendable {
    private struct ScheduledAction {
        let deadline: UInt64
        let order: UInt64
        let action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var currentTime: UInt64
    private var nextOrder: UInt64 = 0
    private var actions: [ScheduledAction] = []
    private var deadlines: [UInt64] = []

    init(now: UInt64) {
        currentTime = now
    }

    var scheduledDeadlines: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return deadlines
    }

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    func schedule(at deadline: UInt64,
                  action: @escaping @Sendable () -> Void) {
        lock.lock()
        actions.append(ScheduledAction(deadline: deadline,
                                       order: nextOrder,
                                       action: action))
        deadlines.append(deadline)
        nextOrder &+= 1
        lock.unlock()
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        currentTime &+= nanoseconds
        lock.unlock()
    }

    @discardableResult
    func runNext() -> Bool {
        lock.lock()
        guard let index = actions.indices.min(by: {
            let lhs = actions[$0]
            let rhs = actions[$1]
            return (lhs.deadline, lhs.order) < (rhs.deadline, rhs.order)
        }) else {
            lock.unlock()
            return false
        }
        let scheduled = actions.remove(at: index)
        currentTime = max(currentTime, scheduled.deadline)
        lock.unlock()
        scheduled.action()
        return true
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
