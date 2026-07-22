import XCTest
@testable import MonobsKit

// Story 1.3, Task 5 (AC3/AC4): transport-vs-content classification, pure and
// unit-tested in isolation from the ssh invocation. v1 convention (provisional,
// Q4.2-adjacent): 255/timeout ⇒ transport failure; 0 ⇒ validate stdout;
// non-zero ≠ 255 ⇒ absent report (server collection failure, 1.2 convention).
final class PollClassifierTests: XCTestCase {

    private let validStdout = Data("{\"v\":1,\"ts\":\"2026-01-01T12:00:00Z\",\"metrics\":{\"loadavg_1m\":0.42}}\n".utf8)

    func testTimeoutIsTransportFailure() {
        XCTAssertEqual(PollClassifier.classify(exitCode: nil, timedOut: true, stdout: Data()),
                       .transportFailure(.timeout))
    }

    func testTimeoutDominatesEvenWithExitCodeAndOutput() {
        // A killed-late process may still have produced an exit code and bytes;
        // the timeout verdict must win.
        XCTAssertEqual(PollClassifier.classify(exitCode: 0, timedOut: true, stdout: validStdout),
                       .transportFailure(.timeout))
    }

    func testLaunchFailureIsTransportFailure() {
        XCTAssertEqual(PollClassifier.classify(exitCode: nil, timedOut: false, stdout: Data()),
                       .transportFailure(.launchFailure))
    }

    func testExit255IsTransportFailure() {
        XCTAssertEqual(PollClassifier.classify(exitCode: 255, timedOut: false, stdout: Data()),
                       .transportFailure(.sshExit255))
    }

    func testExitZeroWithValidReport() {
        XCTAssertEqual(PollClassifier.classify(exitCode: 0, timedOut: false, stdout: validStdout),
                       .validReport(ReportFacts(metrics: ["loadavg_1m": .number(0.42)],
                                                serverTimestamp: "2026-01-01T12:00:00Z")))
    }

    func testExitZeroWithMalformedStdoutIsInvalidReport() {
        XCTAssertEqual(PollClassifier.classify(exitCode: 0, timedOut: false, stdout: Data("not json".utf8)),
                       .invalidReport(.notJSON))
    }

    func testExitZeroWithEmptyStdoutIsInvalidReport() {
        XCTAssertEqual(PollClassifier.classify(exitCode: 0, timedOut: false, stdout: Data()),
                       .invalidReport(.emptyDocument))
    }

    func testExitZeroWithOverflowIsDedicatedInvalidReport() {
        XCTAssertEqual(PollClassifier.classify(exitCode: 0,
                                               timedOut: false,
                                               stdout: validStdout,
                                               stdoutOverflowed: true),
                       .invalidReport(.documentTooLarge))
    }

    func testNonZeroNon255IsAbsentReport() {
        // Server-side collection failure (1.2 convention: non-zero exit,
        // nothing on stdout) — same path as an invalid report, never a
        // transport failure.
        XCTAssertEqual(PollClassifier.classify(exitCode: 3, timedOut: false, stdout: Data()),
                       .reportAbsent(exitCode: 3))
    }

    func testNonZeroNon255IgnoresStrayStdout() {
        // Convention v1: the exit code decides; stray bytes on stdout of a
        // failed collection are never parsed (docs/report-contract.md — no
        // error payload is parsed out of a broken report).
        XCTAssertEqual(PollClassifier.classify(exitCode: 1, timedOut: false, stdout: validStdout),
                       .reportAbsent(exitCode: 1))
    }
}

// Pure argv builder for the ssh invocation (T-RO: the destination is the last
// argument — there is never a command argument after it).
final class SSHCommandTests: XCTestCase {

    private let host = ObservedHost(name: "web", host: "vps-web.example", user: "deploy")

    func testArgumentsAreNonInteractiveAndCommandFree() {
        let args = SSHCommand.arguments(host: host, connectTimeout: 5)
        XCTAssertEqual(args, [
            "-F", "/dev/null",
            "-n", "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "IdentitiesOnly=yes",
            "-o", "RemoteCommand=none",
            "-o", "LocalCommand=none",
            "-o", "ProxyCommand=none",
            "-o", "ProxyJump=none",
            "-o", "PermitLocalCommand=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "KnownHostsCommand=none",
            "-o", "GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts",
            "-o", "UserKnownHostsFile=\(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts").path)",
            "-o", "StrictHostKeyChecking=yes",
            "-p", "22",
            "--",
            "deploy@vps-web.example",
        ])
        // T-RO keystone, asserted on its own so it survives argv refactors:
        // the destination is the LAST argument — no command is ever requested.
        XCTAssertEqual(args.last, "deploy@vps-web.example")
    }

    func testCustomPortIsPassed() {
        let custom = ObservedHost(name: "web", host: "vps-web.example", user: "deploy", port: 2222)
        let args = SSHCommand.arguments(host: custom, connectTimeout: 5)
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
        XCTAssertEqual(args.last, "deploy@vps-web.example")
    }

    func testIdentityAddsKeyAndIdentitiesOnly() {
        let keyed = ObservedHost(name: "web", host: "vps-web.example", user: "deploy",
                                 identity: "~/.ssh/monobs_report_ed25519")
        let args = SSHCommand.arguments(host: keyed, connectTimeout: 5)
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
        let i = args.firstIndex(of: "-i")
        XCTAssertNotNil(i)
        // "~" is expanded client-side: ssh -i does not do tilde expansion itself.
        XCTAssertEqual(args[i! + 1], FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/monobs_report_ed25519").path)
        XCTAssertEqual(args.last, "deploy@vps-web.example")
    }

    func testNoIdentityOmitsOnlyExplicitKey() {
        let args = SSHCommand.arguments(host: host, connectTimeout: 5)
        XCTAssertFalse(args.contains("-i"))
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
    }

    func testExplicitTestKnownHostsUseTheProductionSecurityPolicy() {
        let knownHosts = SSHKnownHostsFiles(global: "/dev/null", user: "/tmp/known_hosts")
        let args = SSHCommand.arguments(host: host, connectTimeout: 5,
                                        knownHosts: knownHosts)
        XCTAssertEqual(args.last, "deploy@vps-web.example")
        XCTAssertTrue(args.contains("UserKnownHostsFile=/tmp/known_hosts"))
        XCTAssertEqual(Array(args.prefix(2)), ["-F", "/dev/null"])
        XCTAssertTrue(args.contains("ClearAllForwardings=yes"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "deploy@vps-web.example"])
    }


    func testEffectiveSSHConfigNeutralizesHostileCommandsProxiesAndForwardings() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostile = dir.appendingPathComponent("hostile_config")
        try """
        Host *
          RemoteCommand touch /tmp/remote-sentinel
          LocalCommand touch /tmp/local-sentinel
          PermitLocalCommand yes
          ProxyJump jump.example
          LocalForward 127.0.0.1:1111 127.0.0.1:22
          RemoteForward 127.0.0.1:2222 127.0.0.1:22
          DynamicForward 127.0.0.1:3333
          KnownHostsCommand /usr/bin/false
        """.write(to: hostile, atomically: true, encoding: .utf8)

        var args = SSHCommand.arguments(host: host, connectTimeout: 5)
        let configIndex = try XCTUnwrap(args.firstIndex(of: "-F"))
        XCTAssertEqual(args[configIndex + 1], "/dev/null",
                       "the shipped path must ignore user and system ssh_config")

        // Defense-in-depth proof: inject the hostile file in place of
        // /dev/null while retaining the exact production -o policy, then ask
        // OpenSSH for the effective configuration without connecting.
        args[configIndex + 1] = hostile.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "ssh -G failed: \(error)")

        let pairs = output.split(separator: "\n").compactMap { line -> (String, String)? in
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { return nil }
            return (fields[0], fields[1])
        }
        let effective = Dictionary(grouping: pairs, by: \.0).mapValues { $0.map(\.1) }
        XCTAssertNil(effective["remotecommand"])
        XCTAssertNil(effective["localcommand"])
        XCTAssertNil(effective["proxycommand"])
        XCTAssertNil(effective["proxyjump"])
        XCTAssertNil(effective["localforward"])
        XCTAssertNil(effective["remoteforward"])
        XCTAssertNil(effective["dynamicforward"])
        XCTAssertNil(effective["knownhostscommand"])
        XCTAssertEqual(effective["permitlocalcommand"], ["no"])
        XCTAssertEqual(effective["clearallforwardings"], ["yes"])
    }
}
