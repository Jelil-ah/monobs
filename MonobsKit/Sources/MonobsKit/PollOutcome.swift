import Foundation

public enum TransportFailureKind: Equatable, Sendable {
    /// ssh's own exit code — connection refused, auth failure, host key
    /// mismatch, DNS failure… all transport-level.
    case sshExit255
    /// Client-side deadline hit (connect or overall watchdog).
    case timeout
    /// The ssh process could not even be launched.
    case launchFailure
}

/// Outcome of one poll of one host — the whole vocabulary consumed by the
/// snapshot store. It carries transport and report facts only.
public enum PollOutcome: Equatable, Sendable {
    /// Transport succeeded and stdout carried a valid v1 report.
    case validReport(ReportFacts)
    /// Transport succeeded but stdout is not a usable report (AD-10):
    /// no fresh data, no SSH-failure signal.
    case invalidReport(ReportInvalidReason)
    /// Transport succeeded but the server-side collection failed (exit != 0
    /// and != 255, stdout empty — the 1.2 error convention). Same path as an
    /// invalid report.
    case reportAbsent(exitCode: Int32)
    /// The SSH transport itself failed — the only outcome that raises
    /// `sshFailureActive`.
    case transportFailure(TransportFailureKind)
}
