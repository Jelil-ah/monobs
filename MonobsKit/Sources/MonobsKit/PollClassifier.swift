import Foundation

/// Transport-vs-content classification of one finished (or killed) ssh exec.
/// Pure — the Process invocation lives in `SSHPollRunner`, this table is the
/// tested logic. v1 convention (provisional, Q4.2-adjacent):
///   - client timeout, launch failure, or exit 255 ⇒ transport failure
///     (255 is ssh's own exit code — docs/deploy-forced-command.md);
///   - exit 0 ⇒ validate stdout (valid or invalid report);
///   - non-zero ≠ 255 ⇒ server collection failure (1.2 convention: nothing on
///     stdout) ⇒ absent report, same path as an invalid one.
/// Known provisional limit, documented not solved: a remote command exiting
/// 255 itself is indistinguishable from ssh's 255 on the client side.
public enum PollClassifier {
    public static func classify(exitCode: Int32?,
                                timedOut: Bool,
                                stdout: Data,
                                stdoutOverflowed: Bool = false) -> PollOutcome {
        if timedOut {
            return .transportFailure(.timeout)
        }
        guard let exitCode else {
            return .transportFailure(.launchFailure)
        }
        switch exitCode {
        case 255:
            return .transportFailure(.sshExit255)
        case 0:
            guard !stdoutOverflowed else {
                return .invalidReport(.documentTooLarge)
            }
            switch ReportValidator.validate(stdout) {
            case .valid(let facts): return .validReport(facts)
            case .invalid(let reason): return .invalidReport(reason)
            }
        default:
            // The exit code decides; stray stdout of a failed collection is
            // never parsed (no error payload out of a broken report).
            return .reportAbsent(exitCode: exitCode)
        }
    }
}
