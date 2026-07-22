import Foundation

/// Runs one poll of one host: a single non-interactive exec of the system ssh
/// binary (AD-9), stdout captured for the validator, stderr kept for local
/// diagnostics only. One ephemeral connection per host per cycle — provisional
/// (Q4.2: no multiplexing, no jitter, sequential hosts in v1).
public enum SSHPollRunner {
    /// Provisional (Q4.2): connect timeout well below the 60 s cadence.
    public static let defaultConnectTimeout = 10
    /// Provisional (Q4.2): overall watchdog — ConnectTimeout only bounds the
    /// TCP connect; a server that accepts and then stalls (never sends a
    /// banner, never closes) would hang the poll forever without this.
    public static let defaultOverallTimeout: TimeInterval = 45
    /// Provisional Q4.2 byte budgets. Readers keep at most these amounts but
    /// continue draining and discarding excess bytes so a chatty or hostile
    /// child cannot deadlock the process or grow memory without bound.
    static let stdoutByteLimit = 1_048_576
    static let stderrByteLimit = 65_536

    /// `onDiagnostics` receives stderr text for local logging only; it never
    /// reaches the snapshot. Production always uses the fixed system binary,
    /// timeouts, and closed argument builder below.
    public static func poll(host: ObservedHost,
                            onDiagnostics: ((String) -> Void)? = nil) -> PollOutcome {
        run(host: host,
            connectTimeout: defaultConnectTimeout,
            overallTimeout: defaultOverallTimeout,
            knownHosts: .production,
            onDiagnostics: onDiagnostics).outcome
    }

    /// Closed integration seam for the throwaway local sshd. Only the pinned
    /// known-hosts paths differ; the production security policy is unchanged.
    static func pollForTesting(host: ObservedHost,
                               connectTimeout: Int,
                               overallTimeout: TimeInterval,
                               knownHosts: SSHKnownHostsFiles) -> PollOutcome {
        run(host: host,
            connectTimeout: connectTimeout,
            overallTimeout: overallTimeout,
            knownHosts: knownHosts,
            onDiagnostics: nil).outcome
    }

    /// Test-only observability for the bounded drain invariant. The captured
    /// bytes themselves remain private; tests can assert the exact budgets.
    static func pollForTestingWithStats(host: ObservedHost,
                                        connectTimeout: Int,
                                        overallTimeout: TimeInterval,
                                        knownHosts: SSHKnownHostsFiles) -> PollExecution {
        run(host: host,
            connectTimeout: connectTimeout,
            overallTimeout: overallTimeout,
            knownHosts: knownHosts,
            onDiagnostics: nil)
    }

    private static func run(host: ObservedHost,
                            connectTimeout: Int,
                            overallTimeout: TimeInterval,
                            knownHosts: SSHKnownHostsFiles,
                            onDiagnostics: ((String) -> Void)?) -> PollExecution {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHCommand.arguments(host: host,
                                                 connectTimeout: connectTimeout,
                                                 knownHosts: knownHosts)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice  // belt and braces with -n

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return PollExecution(outcome: .transportFailure(.launchFailure),
                                 collectionStats: PipeCollectionStats())
        }

        // Drain both pipes off-thread so a chatty child can never deadlock on
        // a full pipe buffer.
        let readGroup = DispatchGroup()
        let collector = PipeCollector()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.drain(stdoutPipe.fileHandleForReading,
                            limit: stdoutByteLimit,
                            into: .stdout)
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.drain(stderrPipe.fileHandleForReading,
                            limit: stderrByteLimit,
                            into: .stderr)
            readGroup.leave()
        }

        var timedOut = false
        if finished.wait(timeout: .now() + overallTimeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        readGroup.wait()

        let stdout = collector.capture(for: .stdout)
        let stderr = collector.capture(for: .stderr)
        if let onDiagnostics, !stderr.data.isEmpty,
           let text = String(data: stderr.data, encoding: .utf8) {
            onDiagnostics(text)
        }

        // A process killed by the watchdog has no meaningful exit code.
        let outcome = PollClassifier.classify(
            exitCode: timedOut ? nil : process.terminationStatus,
            timedOut: timedOut,
            stdout: stdout.data,
            stdoutOverflowed: stdout.overflowed
        )
        return PollExecution(
            outcome: outcome,
            collectionStats: PipeCollectionStats(
                stdoutBytesStored: stdout.data.count,
                stderrBytesStored: stderr.data.count,
                stdoutOverflowed: stdout.overflowed,
                stderrOverflowed: stderr.overflowed
            )
        )
    }
}

struct PipeCollectionStats: Equatable, Sendable {
    var stdoutBytesStored = 0
    var stderrBytesStored = 0
    var stdoutOverflowed = false
    var stderrOverflowed = false
}

struct PollExecution: Equatable, Sendable {
    let outcome: PollOutcome
    let collectionStats: PipeCollectionStats
}

/// Lock-protected bounded captures for the background pipe readers.
private final class PipeCollector: @unchecked Sendable {
    enum Stream {
        case stdout
        case stderr
    }

    struct Capture {
        var data = Data()
        var overflowed = false
    }

    private static let chunkSize = 64 * 1024
    private let lock = NSLock()
    private var stdout = Capture()
    private var stderr = Capture()

    func drain(_ handle: FileHandle, limit: Int, into stream: Stream) {
        var capture = Capture()
        while true {
            let chunk = handle.readData(ofLength: Self.chunkSize)
            guard !chunk.isEmpty else { break }
            let remaining = max(0, limit - capture.data.count)
            if remaining > 0 {
                capture.data.append(contentsOf: chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                capture.overflowed = true
            }
        }
        lock.lock()
        switch stream {
        case .stdout: stdout = capture
        case .stderr: stderr = capture
        }
        lock.unlock()
    }

    func capture(for stream: Stream) -> Capture {
        lock.lock(); defer { lock.unlock() }
        switch stream {
        case .stdout: return stdout
        case .stderr: return stderr
        }
    }
}
