import XCTest
@testable import MonobsKit

// CAP-10 (writer): every test goes through the MONOBS_HOSTS_FILE seam and a
// per-run mkdtemp directory — nothing here can ever touch a real
// `~/.config/monobs/`. Every hostname is RFC 2606 fictional, every IP is
// RFC 5737 documentation space (AD-15).
//
// The central proof is the round trip: what the writer emits is re-read by the
// EXISTING `HostConfigLoader` — never by a second parser written for the tests —
// and must yield exactly the hosts that went in.
final class HostConfigWriterTests: XCTestCase {

    private func seam(_ file: URL) -> [String: String] {
        [HostConfigLoader.environmentVariable: file.path]
    }

    private func temporaryConfigFile() throws -> (directory: URL, file: URL) {
        let directory = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, directory.appendingPathComponent("hosts.toml"))
    }

    // MARK: - round trip = identity

    func testRoundTripThroughTheExistingParserIsIdentity() throws {
        let (_, file) = try temporaryConfigFile()
        let hosts = [
            ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy"),
            ObservedHost(name: "database", host: "vps-db.example", user: "deploy",
                         port: 2222, identity: "~/.ssh/monobs_report_ed25519"),
            ObservedHost(name: "lab", host: "192.0.2.10", user: "ops"),
        ]

        try HostConfigWriter.write(hosts, environment: seam(file))

        let reread = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(reread.hosts, hosts)
        XCTAssertEqual(reread.diagnostics, [])
    }

    func testRoundTripPreservesOptionalsAndDefaultVersusExplicitPort() throws {
        let (_, file) = try temporaryConfigFile()
        let hosts = [
            // identity absent, port left at the documented default
            ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy"),
            // identity present, port explicit and at both ends of the valid range
            ObservedHost(name: "edge", host: "192.0.2.11", user: "ops",
                         port: 1, identity: "~/.ssh/monobs_report_ed25519"),
            ObservedHost(name: "far", host: "192.0.2.12", user: "ops", port: 65535),
            // name equal to host — the parser's own fallback value, written back
            // explicitly, must still read back as the same host
            ObservedHost(name: "vps-db.example", host: "vps-db.example", user: "deploy"),
        ]

        try HostConfigWriter.write(hosts, environment: seam(file))

        let reread = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(reread.hosts, hosts)
        XCTAssertEqual(reread.diagnostics, [])
        // The default port is emitted explicitly rather than left implicit.
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("port = 22"), text)
    }

    func testRoundTripPreservesValuesThatStressTheSubsetSyntax() throws {
        let (_, file) = try temporaryConfigFile()
        // Characters that carry meaning in the subset — comment marker, key
        // separator, table brackets — plus non-ASCII and edge whitespace. None of
        // them may leak into the syntax, all of them must come back verbatim.
        let hosts = [
            ObservedHost(name: "hôte-de-test # 1", host: "vps-web.example", user: "deploy"),
            ObservedHost(name: " marges ", host: "192.0.2.13", user: "ops",
                         identity: "~/.ssh/clé de test [1]"),
            ObservedHost(name: "a = b", host: "192.0.2.14", user: "ops-équipe"),
        ]

        try HostConfigWriter.write(hosts, environment: seam(file))

        let reread = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(reread.hosts, hosts)
        XCTAssertEqual(reread.diagnostics, [])
    }

    func testEmptyHostListWritesAReadableEmptyConfiguration() throws {
        let (_, file) = try temporaryConfigFile()

        try HostConfigWriter.write([], environment: seam(file))

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let reread = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(reread.hosts, [])
        XCTAssertEqual(reread.diagnostics, [])
    }

    func testWriterOutputPassesItsOwnFailClosedGateOnRewrite() throws {
        let (_, file) = try temporaryConfigFile()
        let first = [ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy")]
        let second = [
            ObservedHost(name: "database", host: "vps-db.example", user: "deploy", port: 2222),
            ObservedHost(name: "lab", host: "192.0.2.10", user: "ops"),
        ]

        try HostConfigWriter.write(first, environment: seam(file))
        // A file the writer itself produced must never be seen as unreadable —
        // otherwise editing hosts twice from the app would be impossible.
        try HostConfigWriter.write(second, environment: seam(file))

        XCTAssertEqual(HostConfigLoader.load(environment: seam(file)).hosts, second)
    }

    // MARK: - values that cannot be represented (no escapes exist in the subset)

    func testQuoteInAValueIsRejectedAndNothingIsWritten() throws {
        let (_, file) = try temporaryConfigFile()
        let hosts = [ObservedHost(name: "web \"frontend\"", host: "vps-web.example", user: "deploy")]

        XCTAssertThrowsError(try HostConfigWriter.write(hosts, environment: seam(file))) { error in
            XCTAssertEqual(error as? HostConfigWriteError,
                           HostConfigWriteError.unrepresentableValue(entry: 1, field: "name"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testNewlineInAValueCannotForgeAnExtraEntry() throws {
        let (_, file) = try temporaryConfigFile()
        // The injection attempt: a name that, written naively, would close the
        // entry and open a second one pointing somewhere else.
        let hosts = [ObservedHost(name: "web\"\n[[hosts]]\nhost = \"192.0.2.66\"\nuser = \"root",
                                  host: "vps-web.example", user: "deploy")]

        XCTAssertThrowsError(try HostConfigWriter.write(hosts, environment: seam(file))) { error in
            XCTAssertEqual(error as? HostConfigWriteError,
                           HostConfigWriteError.unrepresentableValue(entry: 1, field: "name"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCarriageReturnInAValueIsRejected() {
        // `\r\n` is a single Swift grapheme, so a character-level scan would miss
        // it — and the loader splits lines on `\n` only, so it would break the
        // whole file rather than one value.
        let hosts = [ObservedHost(name: "web", host: "vps-web.example\r\nuser = \"root", user: "deploy")]

        XCTAssertThrowsError(try HostConfigWriter.serialize(hosts)) { error in
            XCTAssertEqual(error as? HostConfigWriteError,
                           HostConfigWriteError.unrepresentableValue(entry: 1, field: "host"))
        }
    }

    func testEmptyRequiredValuesAreRejectedPerField() {
        let cases: [(ObservedHost, String)] = [
            (ObservedHost(name: "", host: "vps-web.example", user: "deploy"), "name"),
            (ObservedHost(name: "web", host: "", user: "deploy"), "host"),
            (ObservedHost(name: "web", host: "vps-web.example", user: ""), "user"),
            (ObservedHost(name: "web", host: "vps-web.example", user: "deploy", identity: ""), "identity"),
        ]
        for (host, field) in cases {
            XCTAssertThrowsError(try HostConfigWriter.serialize([host]), field) { error in
                XCTAssertEqual(error as? HostConfigWriteError,
                               HostConfigWriteError.emptyValue(entry: 1, field: field))
            }
        }
    }

    func testPortOutsideTheAcceptedRangeIsRejected() {
        for port in [0, -1, 65536, 70000] {
            let hosts = [ObservedHost(name: "web", host: "vps-web.example", user: "deploy", port: port)]
            XCTAssertThrowsError(try HostConfigWriter.serialize(hosts), "port \(port)") { error in
                XCTAssertEqual(error as? HostConfigWriteError,
                               HostConfigWriteError.portOutOfRange(entry: 1, port: port))
            }
        }
    }

    func testDuplicateHostIdentifierIsRejectedRatherThanSilentlyLost() {
        // The loader drops the second entry with a diagnostic; writing it would
        // lose a host on the next read, so the writer refuses up front.
        let hosts = [
            ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy"),
            ObservedHost(name: "web frontend (bis)", host: "vps-web.example", user: "ops"),
        ]

        XCTAssertThrowsError(try HostConfigWriter.serialize(hosts)) { error in
            XCTAssertEqual(error as? HostConfigWriteError,
                           HostConfigWriteError.duplicateHost(entry: 2, host: "vps-web.example"))
        }
    }

    // MARK: - fail closed on an existing configuration we cannot reproduce

    func testExistingConfigurationRejectedByTheParserIsNotOverwritten() throws {
        let (_, file) = try temporaryConfigFile()
        let handWritten = """
        [general]
        cadence = 60
        """
        try handWritten.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try HostConfigWriter.write(
            [ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy")],
            environment: seam(file))
        ) { error in
            guard case .existingConfigurationNotUnderstood(let diagnostics)? = error as? HostConfigWriteError else {
                return XCTFail("expected a fail-closed refusal, got \(error)")
            }
            // The loader's own diagnostic is surfaced, not a reworded one.
            XCTAssertEqual(diagnostics, HostConfigLoader.parse(handWritten).diagnostics)
            XCTAssertFalse(diagnostics.isEmpty)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), handWritten)
    }

    func testExistingConfigurationWithAnyDiagnosticIsNotOverwritten() throws {
        let (_, file) = try temporaryConfigFile()
        // Parses into one usable host, but carries a key this writer cannot
        // reproduce — overwriting would silently delete what the user typed.
        let handWritten = """
        [[hosts]]
        host = "vps-web.example"
        user = "deploy"
        color = "green"
        """
        try handWritten.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try HostConfigWriter.write(
            [ObservedHost(name: "lab", host: "192.0.2.10", user: "ops")],
            environment: seam(file))
        ) { error in
            guard case .existingConfigurationNotUnderstood(let diagnostics)? = error as? HostConfigWriteError else {
                return XCTFail("expected a fail-closed refusal, got \(error)")
            }
            XCTAssertTrue(diagnostics.contains { $0.contains("color") }, "\(diagnostics)")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), handWritten)
    }

    func testExistingNonUTF8ConfigurationIsNotOverwritten() throws {
        let (_, file) = try temporaryConfigFile()
        let bytes = Data([0xFF, 0xFE, 0x00, 0xD8])
        try bytes.write(to: file)

        XCTAssertThrowsError(try HostConfigWriter.write(
            [ObservedHost(name: "lab", host: "192.0.2.10", user: "ops")],
            environment: seam(file))
        ) { error in
            guard case .existingConfigurationNotUnderstood(_)? = error as? HostConfigWriteError else {
                return XCTFail("expected a fail-closed refusal, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testConfigurationTheParserFullyUnderstandsIsReplacedByAnExplicitEdit() throws {
        let (_, file) = try temporaryConfigFile()
        // A v0.2.0-era hand-written file, comments included: read identically by
        // the untouched loader, and replaceable by an explicit in-app edit.
        let legacy = """
        # ~/.config/monobs/hosts.toml — fictional example
        [[hosts]]
        name = "web frontend"            # display label
        host = "vps-web.example"
        user = "deploy"
        """
        try legacy.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(HostConfigLoader.load(environment: seam(file)).hosts,
                       [ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy")])

        let edited = [
            ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy"),
            ObservedHost(name: "database", host: "vps-db.example", user: "deploy", port: 2222),
        ]
        try HostConfigWriter.write(edited, environment: seam(file))

        let reread = HostConfigLoader.load(environment: seam(file))
        XCTAssertEqual(reread.hosts, edited)
        XCTAssertEqual(reread.diagnostics, [])
    }

    func testUnreadableConfigurationIsReplacedOnlyWithTheExplicitOverride() throws {
        let (_, file) = try temporaryConfigFile()
        try "[general]\ncadence = 60".write(to: file, atomically: true, encoding: .utf8)
        let hosts = [ObservedHost(name: "lab", host: "192.0.2.10", user: "ops")]

        XCTAssertThrowsError(try HostConfigWriter.write(hosts, environment: seam(file)))
        try HostConfigWriter.write(hosts, environment: seam(file),
                                   replacingUnreadableConfiguration: true)

        XCTAssertEqual(HostConfigLoader.load(environment: seam(file)).hosts, hosts)
    }

    // MARK: - atomicity, directory creation, path seam

    func testWriteLeavesNoTemporaryResidueAndACompleteFile() throws {
        let (directory, file) = try temporaryConfigFile()
        let hosts = [
            ObservedHost(name: "web frontend", host: "vps-web.example", user: "deploy"),
            ObservedHost(name: "database", host: "vps-db.example", user: "deploy", port: 2222),
        ]

        try HostConfigWriter.write(hosts, environment: seam(file))
        try HostConfigWriter.write(hosts, environment: seam(file))

        // contentsOfDirectory lists hidden entries too, so a leftover partial
        // file would show up here.
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(entries, ["hosts.toml"])

        // The visible file is whole: both entries present, terminated, parseable.
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "[[hosts]]").count - 1, 2, text)
        XCTAssertTrue(text.hasSuffix("\n"), text)
        XCTAssertEqual(HostConfigLoader.parse(text).hosts, hosts)
    }

    func testMissingParentDirectoryIsCreatedWithOwnerOnlyPermissions() throws {
        let (directory, _) = try temporaryConfigFile()
        let nested = directory.appendingPathComponent("config/monobs", isDirectory: true)
        let file = nested.appendingPathComponent("hosts.toml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))

        try HostConfigWriter.write(
            [ObservedHost(name: "lab", host: "192.0.2.10", user: "ops")],
            environment: seam(file))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
    }

    func testUnwritableDestinationFailsWithoutCreatingAnything() throws {
        let (directory, _) = try temporaryConfigFile()
        // The parent path exists as a regular file: the directory cannot be made.
        let blocker = directory.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let file = blocker.appendingPathComponent("hosts.toml")

        XCTAssertThrowsError(try HostConfigWriter.write(
            [ObservedHost(name: "lab", host: "192.0.2.10", user: "ops")],
            environment: seam(file))
        ) { error in
            guard case .ioFailure(_)? = error as? HostConfigWriteError else {
                return XCTFail("expected an I/O failure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["blocked"])
    }

    func testDestinationURLUsesTheSameSeamAndDefaultAsTheLoader() {
        let file = URL(fileURLWithPath: "/tmp/monobs-writer-seam/hosts.toml")
        XCTAssertEqual(HostConfigWriter.destinationURL(environment: seam(file)).path, file.path)
        // No I/O here: the real `~/.config/monobs/` is never touched by the suite.
        XCTAssertEqual(HostConfigWriter.destinationURL(environment: [:]), HostConfigLoader.defaultURL())
        XCTAssertEqual(
            HostConfigWriter.destinationURL(environment: [HostConfigLoader.environmentVariable: ""]),
            HostConfigLoader.defaultURL())
    }
}
