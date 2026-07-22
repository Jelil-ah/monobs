import XCTest
@testable import MonobsKit

// Story 1.3, Task 2 (AC1): host configuration parser — minimal subset of
// docs/host-config.md, never a general TOML parser. Every hostname here is
// RFC 2606 fictional, every IP is RFC 5737 documentation space (AD-15).
final class HostConfigTests: XCTestCase {

    // MARK: nominal

    func testNominalMultiHostMirrorsDocumentedExample() {
        let text = """
        # ~/.config/monobs/hosts.toml — fictional example
        [[hosts]]
        name = "web frontend"            # display label in the menu bar UI
        host = "vps-web.example"         # SSH target: tailnet MagicDNS name or IP
        user = "deploy"                  # SSH user (key-based auth only)
        port = 22                        # optional, default 22

        [[hosts]]
        name = "database"
        host = "vps-db.example"
        user = "deploy"

        [[hosts]]
        name = "lab"
        host = "192.0.2.10"              # RFC 5737 documentation address
        user = "ops"
        """
        let result = HostConfigLoader.parse(text)
        // Exact expected hosts — proves the parser extracts real values, so the
        // "unchanged"/emptiness assertions elsewhere can never be vacuously true.
        XCTAssertEqual(result.hosts, [
            ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy", port: 22, identity: nil),
            ObservedHost(name: "database", host: "vps-db.example", user: "deploy", port: 22, identity: nil),
            ObservedHost(name: "lab", host: "192.0.2.10", user: "ops", port: 22, identity: nil),
        ])
        XCTAssertEqual(result.diagnostics, [])
    }

    func testOptionalIdentityAndPortAreParsed() {
        let text = """
        [[hosts]]
        name = "web frontend"
        host = "vps-web.example"
        user = "deploy"
        port = 2222
        identity = "~/.ssh/monobs_report_ed25519"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [
            ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy",
                         port: 2222, identity: "~/.ssh/monobs_report_ed25519"),
        ])
        XCTAssertEqual(result.diagnostics, [])
    }

    func testNameDefaultsToHostWhenAbsent() {
        let text = """
        [[hosts]]
        host = "vps-db.example"
        user = "deploy"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [
            ObservedHost(name: "vps-db.example", host: "vps-db.example", user: "deploy", port: 22, identity: nil),
        ])
    }

    // MARK: entry-level rejections (entry ignored + diagnostic, no crash)

    func testEntryWithoutHostIsIgnoredWithDiagnosticOthersKept() {
        let text = """
        [[hosts]]
        name = "no target"
        user = "deploy"

        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts.map(\.host), ["vps-web.example"])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].contains("host"), "diagnostic must name the missing key: \(result.diagnostics)")
    }

    func testEntryWithoutUserIsIgnoredWithDiagnostic() {
        let text = """
        [[hosts]]
        host = "vps-web.example"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].contains("user"))
    }

    func testDuplicateHostIdentifierSecondEntryIgnored() {
        // `host` is the stable per-host snapshot identifier (provisional, AD-17
        // consumes it in 1.4) — duplicates would alias two snapshot slots.
        let text = """
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"

        [[hosts]]
        host = "vps-web.example"
        user = "ops"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts.map(\.user), ["deploy"])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].contains("duplicate"))
    }

    func testPortWrongTypeEntryIgnoredWithDiagnostic() {
        let text = """
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        port = "22"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].contains("port"))
    }

    func testPortOutOfRangeEntryIgnoredWithDiagnostic() {
        let text = """
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        port = 70000
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].contains("port"))
    }

    func testUnknownKeyKeepsEntryWithDiagnostic() {
        let text = """
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        color = "green"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts.map(\.host), ["vps-web.example"])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].contains("color"))
    }

    // MARK: file-level rejections (zero hosts + diagnostic, no crash)

    func testKeyOutsideAnyHostsEntryRejectsWholeConfig() {
        let text = """
        title = "not in the documented subset"
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [])
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testUnknownTableHeaderRejectsWholeConfig() {
        let text = """
        [general]
        cadence = 60
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [])
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testUnterminatedStringRejectsWholeConfig() {
        let text = """
        [[hosts]]
        host = "vps-web.example
        user = "deploy"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [])
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testGarbageLineRejectsWholeConfig() {
        let text = """
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        this is not toml at all
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [])
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testDuplicateHostKeyRejectsWholeConfigWithLineDiagnostic() {
        let text = """
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        host = "vps-db.example"
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].contains("line 4"), "\(result.diagnostics)")
        XCTAssertTrue(result.diagnostics[0].contains("duplicate key `host`"), "\(result.diagnostics)")
    }

    func testDuplicatePortKeyRejectsWholeConfigWithLineDiagnostic() {
        let text = """
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        port = 22
        port = 2222
        """
        let result = HostConfigLoader.parse(text)
        XCTAssertEqual(result.hosts, [])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].contains("line 5"), "\(result.diagnostics)")
        XCTAssertTrue(result.diagnostics[0].contains("duplicate key `port`"), "\(result.diagnostics)")
    }

    func testEmptyFileYieldsZeroHostsNoDiagnostic() {
        let result = HostConfigLoader.parse("")
        XCTAssertEqual(result.hosts, [])
        XCTAssertEqual(result.diagnostics, [])
    }

    // MARK: load() — MONOBS_HOSTS_FILE seam and absent file

    func testLoadUsesEnvironmentSeamAndParsesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hosts.toml")
        try """
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        """.write(to: file, atomically: true, encoding: .utf8)

        let result = HostConfigLoader.load(environment: ["MONOBS_HOSTS_FILE": file.path])
        XCTAssertEqual(result.hosts.map(\.host), ["vps-web.example"])
        XCTAssertEqual(result.diagnostics, [])
    }

    func testLoadAbsentFileYieldsZeroHostsAndDiagnostic() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.toml")

        let result = HostConfigLoader.load(environment: ["MONOBS_HOSTS_FILE": missing.path])
        XCTAssertEqual(result.hosts, [])
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.diagnostics[0].contains("no host configuration"))
    }

    func testLoadNonUTF8FileYieldsZeroHostsAndDiagnostic() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hosts.toml")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: file)

        let result = HostConfigLoader.load(environment: ["MONOBS_HOSTS_FILE": file.path])
        XCTAssertEqual(result.hosts, [])
        XCTAssertEqual(result.diagnostics.count, 1)
    }

    func testDefaultURLIsHomeAnchoredConfigPath() {
        let url = HostConfigLoader.defaultURL()
        XCTAssertTrue(url.path.hasSuffix("/.config/monobs/hosts.toml"))
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }
}

// Unique POSIX mkdtemp directory per run; fixed paths corrupt concurrent runs.
func makeTempDir(function: StaticString = #function) throws -> URL {
    let templateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("monobskit-tests.XXXXXX")
    var template = Array(templateURL.path.utf8CString)
    guard let path = mkdtemp(&template) else {
        throw TestSSHServerError.temporaryDirectoryFailed
    }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
