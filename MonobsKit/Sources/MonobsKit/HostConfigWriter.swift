import Foundation

// CAP-10 (writer) — the in-app counterpart of `HostConfigLoader`. Until v1 the
// host list could only be produced by hand-editing `~/.config/monobs/hosts.toml`
// in a terminal; this type lets the settings UI produce that same file. It is
// the WRITE side only: the read side (`HostConfig.swift`) stays untouched, which
// is what guarantees that a v0.2.0-era configuration keeps being read exactly as
// before.
//
// Three properties matter more than convenience here:
//
// 1. **Round-trip identity.** Whatever `serialize` emits must be read back by
//    the EXISTING parser as exactly the hosts it was given. The subset accepted
//    by the parser has no escape sequences at all, so "escaping" a value is
//    impossible by construction — the only correct behaviour is to validate and
//    refuse anything that could not be re-read verbatim. That also closes the
//    obvious injection door: a `"` or a newline inside a value could otherwise
//    forge extra keys or a whole extra `[[hosts]]` entry.
// 2. **Atomicity.** The file is written to a temporary in the SAME directory and
//    then `rename(2)`d over the destination. rename is atomic on the volume: an
//    interrupted write leaves either the previous configuration or the new one,
//    never a truncated one. A truncated config means the app silently observes
//    nothing.
// 3. **Fail closed on what we do not understand.** If the file already on disk
//    is outside the documented subset — or has any diagnostic at all, i.e. it
//    carries something this writer could not reproduce — the write is REFUSED
//    and the parser's own diagnostics are raised. We never destroy a
//    configuration the user hand-wrote and we cannot read back.

/// Why a set of hosts could not be written. Every case is a refusal BEFORE any
/// byte of the destination is touched — an error here always means the previous
/// configuration is still intact.
public enum HostConfigWriteError: Error, Equatable, Sendable {
    /// A value that the parser requires to be non-empty is empty. Entry numbers
    /// are 1-based, matching the `hosts entry #n` wording of the loader.
    case emptyValue(entry: Int, field: String)
    /// The value cannot be represented verbatim in the documented subset — it
    /// contains a `"` or a line break, and the subset has no escape sequences.
    case unrepresentableValue(entry: Int, field: String)
    case portOutOfRange(entry: Int, port: Int)
    /// `host` is the stable per-host snapshot identifier: a duplicate would be
    /// dropped on re-read, so writing it would lose an entry.
    case duplicateHost(entry: Int, host: String)
    /// The file already on disk is not something this writer could have produced.
    /// Carries the loader's own diagnostics verbatim.
    case existingConfigurationNotUnderstood(diagnostics: [String])
    /// Directory creation, temporary write or atomic replacement failed.
    case ioFailure(String)
    /// Defensive, unreachable by construction: the serialized text did not read
    /// back as the exact input. Kept as a hard stop — a writer that cannot prove
    /// its own output must not replace a working configuration.
    case roundTripCheckFailed
}

extension HostConfigWriteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyValue(let entry, let field):
            return "hosts entry #\(entry): `\(field)` must not be empty"
        case .unrepresentableValue(let entry, let field):
            return "hosts entry #\(entry): `\(field)` contains a quote or a line break, which the configuration format cannot represent"
        case .portOutOfRange(let entry, let port):
            return "hosts entry #\(entry): `port` \(port) is outside 1...65535"
        case .duplicateHost(let entry, let host):
            return "hosts entry #\(entry): duplicate host `\(host)` (host is the stable identifier and must be unique)"
        case .existingConfigurationNotUnderstood(let diagnostics):
            return "the existing host configuration is outside the documented format and was left untouched: "
                + diagnostics.joined(separator: "; ")
        case .ioFailure(let reason):
            return "host configuration not written: \(reason)"
        case .roundTripCheckFailed:
            return "host configuration not written: it could not be read back identically"
        }
    }
}

/// Serializer for the **documented subset** of hosts.toml (docs/host-config.md).
/// Mirror of `HostConfigLoader`, and deliberately not a general TOML emitter (no
/// third-party dependency — B1/B2). Stateless: only static members, nothing
/// shared, so it is safe to call from any isolation domain.
public enum HostConfigWriter {
    /// Permissions for `~/.config/monobs/` — owner only. Contains no secret, but
    /// it names the operator's infrastructure.
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    /// Scalars that cannot survive a write/read round trip in the subset (see
    /// `representable`).
    private static let forbiddenScalars: Set<Unicode.Scalar> = ["\"", "\n", "\r"]

    /// Same seam as the loader, resolved through the SAME constant and the SAME
    /// default path so reader and writer can never point at different files.
    public static func destinationURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[HostConfigLoader.environmentVariable], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return HostConfigLoader.defaultURL()
    }

    // MARK: - serialization (pure, no I/O)

    /// Renders hosts as the documented subset. Emits only the five keys the
    /// parser knows (`name`, `host`, `user`, `port`, `identity`) — nothing
    /// invented. `port` is always explicit: it costs one line and shows the
    /// operator the value actually used instead of an implicit default.
    ///
    /// Throws rather than emitting anything that would not be read back verbatim.
    public static func serialize(_ hosts: [ObservedHost]) throws -> String {
        var lines: [String] = [
            "# hosts.toml — written by Monobs (format: docs/host-config.md).",
            "# Edited from the app's host settings: rewriting this file from the app",
            "# does not preserve hand-written comments.",
        ]
        var seenHostIDs = Set<String>()

        for (index, host) in hosts.enumerated() {
            let entry = index + 1
            let name = try representable(host.name, entry: entry, field: "name")
            let target = try representable(host.host, entry: entry, field: "host")
            let user = try representable(host.user, entry: entry, field: "user")
            guard (1...65535).contains(host.port) else {
                throw HostConfigWriteError.portOutOfRange(entry: entry, port: host.port)
            }
            guard seenHostIDs.insert(target).inserted else {
                throw HostConfigWriteError.duplicateHost(entry: entry, host: target)
            }
            lines.append("")
            lines.append("[[hosts]]")
            lines.append("name = \(quoted(name))")
            lines.append("host = \(quoted(target))")
            lines.append("user = \(quoted(user))")
            lines.append("port = \(host.port)")
            if let identity = host.identity {
                let key = try representable(identity, entry: entry, field: "identity")
                lines.append("identity = \(quoted(key))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The subset has no escape sequences: a value is either writable as-is
    /// between two quotes, or it is not writable at all.
    ///
    /// - `"` would close the string early — the remainder of the line would be
    ///   re-read as garbage or, worse, as another key.
    /// - `\n` / `\r` would split the value across lines — the tail could forge a
    ///   whole `[[hosts]]` entry. (`\r` also breaks line splitting outright,
    ///   since `\r\n` is a single Swift grapheme.)
    ///
    /// Scanning unicode scalars, not characters, so a `\r\n` pair cannot hide
    /// inside a grapheme cluster.
    private static func representable(_ value: String, entry: Int, field: String) throws -> String {
        guard !value.isEmpty else {
            throw HostConfigWriteError.emptyValue(entry: entry, field: field)
        }
        guard !value.unicodeScalars.contains(where: { forbiddenScalars.contains($0) }) else {
            throw HostConfigWriteError.unrepresentableValue(entry: entry, field: field)
        }
        return value
    }

    private static func quoted(_ value: String) -> String { "\"\(value)\"" }

    // MARK: - atomic write

    /// Writes the host list to the configuration file, atomically.
    ///
    /// Order of operations is the safety contract: validate, prove the round
    /// trip, refuse an existing file we cannot reproduce — and only then touch
    /// the filesystem. Any thrown error leaves the previous configuration exactly
    /// as it was.
    ///
    /// - Parameter replacingUnreadableConfiguration: opt-in override for the
    ///   fail-closed rule. Default `false`: a configuration outside the
    ///   documented subset is never overwritten. A caller may set it to `true`
    ///   ONLY after showing the user the reported diagnostics and getting an
    ///   explicit "replace it anyway" — the rule is never to overwrite
    ///   *silently*, not that recovery is impossible.
    /// - Returns: the URL actually written.
    @discardableResult
    public static func write(
        _ hosts: [ObservedHost],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        replacingUnreadableConfiguration: Bool = false
    ) throws -> URL {
        let text = try serialize(hosts)

        // Prove the output against the REAL parser before it can replace
        // anything. Cheap for a handful of hosts, and it makes "we never write a
        // file we cannot read back" an enforced invariant instead of a claim.
        let readBack = HostConfigLoader.parse(text)
        guard readBack.hosts == hosts, readBack.diagnostics.isEmpty else {
            throw HostConfigWriteError.roundTripCheckFailed
        }

        let url = destinationURL(environment: environment)
        if !replacingUnreadableConfiguration {
            try refuseUnreadableExistingConfiguration(at: url)
        }

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions])
        } catch {
            throw HostConfigWriteError.ioFailure(
                "cannot create the configuration directory (\(error.localizedDescription))")
        }

        guard let data = text.data(using: .utf8) else {
            throw HostConfigWriteError.ioFailure("configuration is not encodable as UTF-8")
        }
        // Temporary in the SAME directory: rename is only atomic within a volume.
        // Hidden name so a hard crash between the two steps leaves nothing that
        // looks like a configuration file.
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path,
                                             contents: data,
                                             attributes: [.posixPermissions: filePermissions]) else {
            throw HostConfigWriteError.ioFailure("cannot write the temporary configuration file")
        }
        // rename(2): the destination flips from the old inode to the fully
        // written new one in a single step, so no reader ever observes a partial
        // file and no interruption can truncate the configuration.
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw HostConfigWriteError.ioFailure("cannot replace the configuration file atomically")
        }
        return url
    }

    /// Fail-closed gate. A file that yields ANY diagnostic — a rejected file, but
    /// also an unknown key or a dropped entry — is a file this writer could not
    /// reproduce: overwriting it would silently destroy what the user typed.
    /// The loader's diagnostics are surfaced verbatim so the UI can show exactly
    /// what it did not understand.
    private static func refuseUnreadableExistingConfiguration(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            throw HostConfigWriteError.existingConfigurationNotUnderstood(
                diagnostics: ["the existing host configuration is not readable UTF-8"])
        }
        let existing = HostConfigLoader.parse(text)
        guard existing.diagnostics.isEmpty else {
            throw HostConfigWriteError.existingConfigurationNotUnderstood(diagnostics: existing.diagnostics)
        }
    }
}
