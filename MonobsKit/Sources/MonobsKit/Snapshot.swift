import Foundation

/// Per-host snapshot — exactly three recorded facts (AD-10/AD-12):
///   1. last valid facts,
///   2. client reception instant of the last valid report,
///   3. active SSH failure boolean.
public struct HostSnapshot: Equatable, Sendable {
    /// Facts of the last valid report; nil until one has been received.
    public var lastValidFacts: ReportFacts?
    /// Client-clock instant (an absolute UTC point in time) at which the last
    /// valid report was received — the only freshness anchor (AD-10). The
    /// server `ts` inside the facts never feeds this field.
    public var lastValidReceivedAt: Date?
    /// Transport verdict of the last completed poll: raised by a transport
    /// failure, cleared by any poll whose transport succeeds — even one that
    /// carried an invalid report (AD-10: an invalid report must never leave a
    /// host on the unreachable path).
    public var sshFailureActive: Bool

    public init(lastValidFacts: ReportFacts? = nil,
                lastValidReceivedAt: Date? = nil,
                sshFailureActive: Bool = false) {
        self.lastValidFacts = lastValidFacts
        self.lastValidReceivedAt = lastValidReceivedAt
        self.sshFailureActive = sshFailureActive
    }
}

/// In-memory snapshot store, owned and written by the app process alone
/// (AD-12 — no shared container and no persistence). Lock-protected for the
/// polling queue and readers.
public final class SnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: HostSnapshot] = [:]

    public init() {}

    public func snapshot(for hostID: String) -> HostSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshots[hostID] ?? HostSnapshot()
    }

    public func allSnapshots() -> [String: HostSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return snapshots
    }

    /// Applies one poll outcome. `receivedAt` is the client reception instant
    /// injected by the caller (the poller passes its clock's "now") — injected
    /// for deterministic tests.
    public func record(_ outcome: PollOutcome, forHost hostID: String, receivedAt: Date) {
        lock.lock(); defer { lock.unlock() }
        var snapshot = snapshots[hostID] ?? HostSnapshot()
        switch outcome {
        case .validReport(let facts):
            snapshot.lastValidFacts = facts
            snapshot.lastValidReceivedAt = receivedAt
            snapshot.sshFailureActive = false
        case .invalidReport, .reportAbsent:
            // Transport succeeded: the failure signal falls back; facts and
            // freshness stay untouched (AD-10 — neither fresh data nor an
            // active failure).
            snapshot.sshFailureActive = false
        case .transportFailure:
            snapshot.sshFailureActive = true
        }
        snapshots[hostID] = snapshot
    }
}
