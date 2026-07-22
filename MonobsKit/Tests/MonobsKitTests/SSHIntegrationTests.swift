import XCTest
@testable import MonobsKit

// Story 1.3, Task 5/7 (AC1/AC2/AC3/AC4): real integration proof without a real
// server — a throwaway sshd on 127.0.0.1 with per-scenario keys bound to
// `command="…",restrict` forced commands serving fixtures (the pattern
// validated in the 1.2 review, now client-side). Everything lives in a unique
// temp dir; no real infrastructure identifier anywhere. sshd/ssh/ssh-keygen
// ship with macOS — a missing binary FAILS the test, it never skips (no
// vacuous pass).
final class SSHIntegrationTests: XCTestCase {

    private var server: TestSSHServer!

    override func setUpWithError() throws {
        server = try TestSSHServer()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    private func observedHost(identity: URL, port: Int? = nil) -> ObservedHost {
        // 127.0.0.1 + the current login user: runtime-only values of the test
        // machine, never committed anywhere.
        ObservedHost(name: "integration", host: "127.0.0.1", user: NSUserName(),
                     port: port ?? server.port, identity: identity.path)
    }

    /// Test seam options: isolate ssh completely from the machine's own ssh
    /// configuration and pin the throwaway host key (strict checking stays ON).
    private var knownHosts: SSHKnownHostsFiles {
        SSHKnownHostsFiles(global: "/dev/null", user: server.knownHosts.path)
    }

    private func poll(identity: URL, port: Int? = nil,
                      overallTimeout: TimeInterval = 15) -> PollOutcome {
        SSHPollRunner.pollForTesting(host: observedHost(identity: identity, port: port),
                                     connectTimeout: 5,
                                     overallTimeout: overallTimeout,
                                     knownHosts: knownHosts)
    }

    // MARK: scenarios (AC1, AC2, AC3)

    func testValidReportPollYieldsExactFactsAndUpdatesSnapshot() throws {
        let outcome = poll(identity: server.validKey)
        let expectedFacts = ReportFacts(
            metrics: [
                "loadavg_1m": .number(0.42),
                "uptime_s": .number(123456),
                "mem_available_kib": .number(1048576),
            ],
            serverTimestamp: "2026-01-01T12:00:00Z"
        )
        XCTAssertEqual(outcome, .validReport(expectedFacts))

        let store = SnapshotStore()
        let now = Date()
        store.record(outcome, forHost: "vps-web.example", receivedAt: now)
        XCTAssertEqual(store.snapshot(for: "vps-web.example"),
                       HostSnapshot(lastValidFacts: expectedFacts,
                                    lastValidReceivedAt: now,
                                    sshFailureActive: false))
    }

    func testInvalidReportOverLiveTransportClearsFailureKeepsFreshness() throws {
        // AC2 + the AD-10 keystone over a REAL transport: raise the failure
        // signal first, then poll a host whose transport works but whose
        // report has an unknown major version.
        let store = SnapshotStore()
        let hostID = "vps-web.example"
        let refusedPort = try TestSSHServer.freeTCPPort()
        let t0 = Date()

        let failure = poll(identity: server.validKey, port: refusedPort)
        XCTAssertEqual(failure, .transportFailure(.sshExit255))
        store.record(failure, forHost: hostID, receivedAt: t0)
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: nil, sshFailureActive: true))

        let outcome = poll(identity: server.invalidReportKey)
        XCTAssertEqual(outcome, .invalidReport(.versionUnknown(2)))
        store.record(outcome, forHost: hostID, receivedAt: t0.addingTimeInterval(60))
        // Signal fell back, freshness fields still pristine-exact (F2 fixture
        // shape over live transport).
        XCTAssertEqual(store.snapshot(for: hostID),
                       HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: nil, sshFailureActive: false))
    }

    func testServerCollectionFailureIsAbsentReport() throws {
        // Forced command exits 3 with nothing on stdout (1.2 error convention).
        XCTAssertEqual(poll(identity: server.collectFailKey), .reportAbsent(exitCode: 3))
    }

    func testConnectionRefusedIsActiveTransportFailure() throws {
        let refusedPort = try TestSSHServer.freeTCPPort()
        XCTAssertEqual(poll(identity: server.validKey, port: refusedPort),
                       .transportFailure(.sshExit255))
    }

    func testSilentServerHitsClientWatchdogTimeout() throws {
        // A listener that accepts TCP but never speaks SSH: ConnectTimeout
        // does not cover this — the overall watchdog must classify it as a
        // transport timeout.
        let silent = try TestSSHServer.silentListener()
        defer { silent.close() }
        XCTAssertEqual(poll(identity: server.validKey, port: silent.port, overallTimeout: 3),
                       .transportFailure(.timeout))
    }

    func testFiniteStdoutAboveLimitIsDedicatedInvalidReportAndMemoryIsBounded() {
        let execution = SSHPollRunner.pollForTestingWithStats(
            host: observedHost(identity: server.oversizedKey),
            connectTimeout: 5,
            overallTimeout: 15,
            knownHosts: knownHosts
        )

        XCTAssertEqual(execution.outcome, .invalidReport(.documentTooLarge))
        XCTAssertTrue(execution.collectionStats.stdoutOverflowed)
        XCTAssertEqual(execution.collectionStats.stdoutBytesStored,
                       SSHPollRunner.stdoutByteLimit)
        XCTAssertLessThanOrEqual(execution.collectionStats.stderrBytesStored,
                                 SSHPollRunner.stderrByteLimit)

        let priorFacts = ReportFacts(metrics: ["sample": .number(1)],
                                     serverTimestamp: "2026-01-01T12:00:00Z")
        let receivedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let store = SnapshotStore()
        store.record(.validReport(priorFacts), forHost: "vps-web.example", receivedAt: receivedAt)
        store.record(.transportFailure(.sshExit255), forHost: "vps-web.example",
                     receivedAt: receivedAt.addingTimeInterval(1))
        store.record(execution.outcome, forHost: "vps-web.example",
                     receivedAt: receivedAt.addingTimeInterval(2))
        XCTAssertEqual(store.snapshot(for: "vps-web.example"),
                       HostSnapshot(lastValidFacts: priorFacts,
                                    lastValidReceivedAt: receivedAt,
                                    sshFailureActive: false),
                       "documentTooLarge must clear transport failure without advancing freshness")
    }

    func testContinuousStdoutTerminatesAtWatchdogWithBoundedMemoryAndExactVerdict() {
        let started = Date()
        let execution = SSHPollRunner.pollForTestingWithStats(
            host: observedHost(identity: server.continuousKey),
            connectTimeout: 5,
            overallTimeout: 1.5,
            knownHosts: knownHosts
        )

        XCTAssertEqual(execution.outcome, .transportFailure(.timeout))
        XCTAssertTrue(execution.collectionStats.stdoutOverflowed)
        XCTAssertEqual(execution.collectionStats.stdoutBytesStored,
                       SSHPollRunner.stdoutByteLimit)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "continuous stdout must be drained/discarded and terminate after the watchdog")
    }

    // MARK: T-RO behavioral proof (AC4)

    func testPollerNeverRequestsACommand() throws {
        // Every forced-command wrapper logs whether sshd received a requested
        // command (SSH_ORIGINAL_COMMAND). Run the real poller across all three
        // scenario keys, then read the log.
        XCTAssertEqual(poll(identity: server.validKey),
                       .validReport(ReportFacts(metrics: [
                           "loadavg_1m": .number(0.42),
                           "uptime_s": .number(123456),
                           "mem_available_kib": .number(1048576),
                       ], serverTimestamp: "2026-01-01T12:00:00Z")))
        XCTAssertEqual(poll(identity: server.invalidReportKey), .invalidReport(.versionUnknown(2)))
        XCTAssertEqual(poll(identity: server.collectFailKey), .reportAbsent(exitCode: 3))

        let entries = try server.commandLogEntries()
        XCTAssertEqual(entries.count, 3, "each poll must have hit the forced command exactly once")
        XCTAssertEqual(Set(entries), ["NO_COMMAND_REQUESTED"],
                       "the poller must never request a command (T-RO): \(entries)")

        // Non-vacuity: prove the checker CAN fire. SSHPollRunner has no way to
        // express a command, so drive ssh directly with one extra argument —
        // the log must record it (the forced command still ignores it, AD-9).
        try server.runRawSSH(identity: server.validKey,
                             knownHosts: knownHosts,
                             requestedCommand: "uname -a")
        let after = try server.commandLogEntries()
        XCTAssertEqual(after.count, 4)
        XCTAssertTrue(after.contains("COMMAND_REQUESTED:uname -a"),
                      "the T-RO log checker must fire when a command IS requested: \(after)")
        print("T-RO sshd log: 3x NO_COMMAND_REQUESTED; non-vacuity sentinel observed")
    }
}

// MARK: - throwaway sshd harness

/// Boots an unprivileged sshd on 127.0.0.1 (random free port) inside a unique
/// temp dir: one throwaway host key, three client keys each bound to a
/// `command="…",restrict` wrapper that logs SSH_ORIGINAL_COMMAND presence and
/// serves a fixture (valid v1 report / unknown-version report / collection
/// failure exit 3).
final class TestSSHServer {
    let dir: URL
    let port: Int
    let validKey: URL
    let invalidReportKey: URL
    let collectFailKey: URL
    let oversizedKey: URL
    let continuousKey: URL
    let knownHosts: URL
    private let commandLog: URL
    private var sshd: Process?

    init() throws {
        dir = try makeTempDir()
        port = try Self.freeTCPPort()
        commandLog = dir.appendingPathComponent("command.log")
        knownHosts = dir.appendingPathComponent("known_hosts")

        let hostKey = dir.appendingPathComponent("host_ed25519")
        validKey = dir.appendingPathComponent("client_valid_ed25519")
        invalidReportKey = dir.appendingPathComponent("client_invalid_ed25519")
        collectFailKey = dir.appendingPathComponent("client_collectfail_ed25519")
        oversizedKey = dir.appendingPathComponent("client_oversized_ed25519")
        continuousKey = dir.appendingPathComponent("client_continuous_ed25519")
        for key in [hostKey, validKey, invalidReportKey, collectFailKey, oversizedKey, continuousKey] {
            try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path])
        }

        // Fixtures served by the forced commands (fictional values only —
        // the valid one mirrors docs/report-contract.md).
        let validFixture = dir.appendingPathComponent("report-valid.json")
        try Data("{\"v\":1,\"ts\":\"2026-01-01T12:00:00Z\",\"metrics\":{\"loadavg_1m\":0.42,\"uptime_s\":123456,\"mem_available_kib\":1048576}}\n".utf8)
            .write(to: validFixture)
        let invalidFixture = dir.appendingPathComponent("report-invalid.json")
        try Data("{\"v\":2,\"ts\":\"2026-01-01T12:00:00Z\",\"metrics\":{\"loadavg_1m\":0.42}}\n".utf8)
            .write(to: invalidFixture)
        let oversizedFixture = dir.appendingPathComponent("report-oversized.bin")
        try Data(repeating: UInt8(ascii: "x"), count: SSHPollRunner.stdoutByteLimit + 1)
            .write(to: oversizedFixture)

        let serveValid = try writeWrapper(name: "serve-valid.sh", body: "exec /bin/cat '\(validFixture.path)'\n")
        let serveInvalid = try writeWrapper(name: "serve-invalid.sh", body: "exec /bin/cat '\(invalidFixture.path)'\n")
        let collectFail = try writeWrapper(name: "collect-fail.sh", body: "exit 3\n")
        let serveOversized = try writeWrapper(name: "serve-oversized.sh", body: "exec /bin/cat '\(oversizedFixture.path)'\n")
        let serveContinuous = try writeWrapper(name: "serve-continuous.sh", body: "exec /usr/bin/yes x\n")

        // authorized_keys: each client key is hard-bound to its wrapper, with
        // `restrict` — exactly the AD-9 deployment shape.
        var authorized = ""
        for (wrapper, key) in [
            (serveValid, validKey),
            (serveInvalid, invalidReportKey),
            (collectFail, collectFailKey),
            (serveOversized, oversizedKey),
            (serveContinuous, continuousKey),
        ] {
            let pub = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            authorized += "command=\"\(wrapper.path)\",restrict \(pub)\n"
        }
        let authorizedKeys = dir.appendingPathComponent("authorized_keys")
        try authorized.write(to: authorizedKeys, atomically: true, encoding: .utf8)

        // Pin the throwaway host key for the client side (strict checking on).
        let hostPub = try String(contentsOf: hostKey.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try "[127.0.0.1]:\(port) \(hostPub)\n".write(to: knownHosts, atomically: true, encoding: .utf8)

        let config = dir.appendingPathComponent("sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        PidFile \(dir.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(authorizedKeys.path)
        StrictModes no
        PubkeyAuthentication yes
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        LogLevel ERROR
        """.write(to: config, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", config.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        sshd = process
        try Self.waitUntilAccepting(port: port, deadline: Date().addingTimeInterval(10))
    }

    func stop() {
        if let sshd, sshd.isRunning {
            sshd.terminate()
            sshd.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func commandLogEntries() throws -> [String] {
        guard FileManager.default.fileExists(atPath: commandLog.path) else { return [] }
        return try String(contentsOf: commandLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// Drives ssh directly with an explicit requested command — only the
    /// non-vacuity check uses this; the production path cannot express it.
    func runRawSSH(identity: URL, knownHosts: SSHKnownHostsFiles, requestedCommand: String) throws {
        let host = ObservedHost(name: "raw", host: "127.0.0.1", user: NSUserName(),
                                port: port, identity: identity.path)
        let args = SSHCommand.arguments(host: host, connectTimeout: 5,
                                        knownHosts: knownHosts) + [requestedCommand]
        try Self.run("/usr/bin/ssh", args)
    }

    // MARK: plumbing

    private func writeWrapper(name: String, body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let script = """
        #!/bin/sh
        # Forced-command wrapper: log whether a command was requested (T-RO
        # proof), then behave like a deployed monobs-report would.
        if [ -n "${SSH_ORIGINAL_COMMAND-}" ]; then
          printf 'COMMAND_REQUESTED:%s\\n' "$SSH_ORIGINAL_COMMAND" >> '\(commandLog.path)'
        else
          printf 'NO_COMMAND_REQUESTED\\n' >> '\(commandLog.path)'
        fi
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestSSHServerError.toolFailed(tool: tool, exit: process.terminationStatus)
        }
    }

    /// Binds port 0 on 127.0.0.1, reads the kernel-assigned port, closes.
    static func freeTCPPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestSSHServerError.socketFailed }
        defer { close(fd) }
        var addr = Self.loopbackAddress(port: 0)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw TestSSHServerError.socketFailed }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw TestSSHServerError.socketFailed }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    /// TCP listener that accepts connections but never sends a byte — the
    /// "silent server" for the watchdog-timeout scenario.
    static func silentListener() throws -> SilentListener {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestSSHServerError.socketFailed }
        var addr = loopbackAddress(port: 0)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw TestSSHServerError.socketFailed
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw TestSSHServerError.socketFailed
        }
        return SilentListener(fd: fd, port: Int(UInt16(bigEndian: assigned.sin_port)))
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return addr
    }

    private static func waitUntilAccepting(port: Int, deadline: Date) throws {
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TestSSHServerError.socketFailed }
            var addr = loopbackAddress(port: UInt16(port))
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(fd)
            if connected == 0 { return }
            usleep(100_000)
        }
        throw TestSSHServerError.sshdNeverCameUp
    }
}

struct SilentListener {
    let fd: Int32
    let port: Int
    func close() { _ = Darwin.close(fd) }
}

enum TestSSHServerError: Error {
    case toolFailed(tool: String, exit: Int32)
    case socketFailed
    case sshdNeverCameUp
    case temporaryDirectoryFailed
}
