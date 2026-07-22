import Foundation

/// One observed host from the out-of-repo configuration (docs/host-config.md).
/// `host` doubles as the stable per-host snapshot identifier — unique by
/// construction (duplicates are rejected at parse time). Provisional choice:
/// AD-17 (1.4) will consume it as the tie-break ordering key.
public struct ObservedHost: Equatable, Hashable, Sendable {
    public let name: String
    public let host: String
    public let user: String
    public let port: Int
    /// Optional path to the dedicated AD-9 key. Provisional doc extension
    /// (docs/host-config.md): absent means standard ssh identity resolution.
    public let identity: String?

    public init(name: String, host: String, user: String, port: Int = 22, identity: String? = nil) {
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identity = identity
    }
}

public struct HostConfigResult: Equatable, Sendable {
    public var hosts: [ObservedHost]
    /// Human-readable local diagnostics. A config problem never crashes and
    /// never raises any per-host signal — it just yields fewer (or zero) hosts.
    public var diagnostics: [String]

    public init(hosts: [ObservedHost] = [], diagnostics: [String] = []) {
        self.hosts = hosts
        self.diagnostics = diagnostics
    }
}

/// Parser for the **documented subset** of hosts.toml only (docs/host-config.md):
/// `[[hosts]]` entries, `key = "string" | integer` pairs, `#` comments, blank
/// lines. Deliberately not a general TOML parser (no third-party dependency —
/// B1/B2). Anything outside the subset rejects the whole file (zero hosts +
/// diagnostic, fail closed); semantic problems inside one entry drop that entry
/// only.
public enum HostConfigLoader {
    /// Test seam, same pattern as MONOBS_REPORT_PROC in 1.2: points the loader
    /// at a fictional test config. Never set in production.
    public static let environmentVariable = "MONOBS_HOSTS_FILE"

    private static let knownKeys: Set<String> = ["name", "host", "user", "port", "identity"]

    /// `~/.config/monobs/hosts.toml`, resolved through FileManager (AD-15: no
    /// literal home path anywhere).
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/monobs/hosts.toml")
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> HostConfigResult {
        let url: URL
        if let override = environment[environmentVariable], !override.isEmpty {
            url = URL(fileURLWithPath: override)
        } else {
            url = defaultURL()
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return HostConfigResult(diagnostics: ["no host configuration (expected ~/.config/monobs/hosts.toml, see docs/host-config.md) — polling zero hosts"])
        }
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            return HostConfigResult(diagnostics: ["host configuration is not readable UTF-8 — polling zero hosts"])
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> HostConfigResult {
        var entries: [[String: TOMLValue]] = []
        var current: [String: TOMLValue]?

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") {
                guard stripTrailingComment(afterValueIn: line) == "[[hosts]]" else {
                    return HostConfigResult(diagnostics: ["line \(lineNumber): only [[hosts]] tables are in the documented subset — config rejected"])
                }
                if let entry = current { entries.append(entry) }
                current = [:]
                continue
            }

            guard let equals = line.firstIndex(of: "=") else {
                return HostConfigResult(diagnostics: ["line \(lineNumber): not a `key = value` pair — config rejected"])
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, isBareKey(key) else {
                return HostConfigResult(diagnostics: ["line \(lineNumber): invalid key — config rejected"])
            }
            guard let value = parseValue(rawValue) else {
                return HostConfigResult(diagnostics: ["line \(lineNumber): value of `\(key)` is neither a quoted string nor an integer — config rejected"])
            }
            guard current != nil else {
                return HostConfigResult(diagnostics: ["line \(lineNumber): `\(key)` outside any [[hosts]] entry is not in the documented subset — config rejected"])
            }
            guard current?[key] == nil else {
                return HostConfigResult(diagnostics: ["line \(lineNumber): duplicate key `\(key)` in [[hosts]] entry — config rejected"])
            }
            current?[key] = value
        }
        if let entry = current { entries.append(entry) }

        return assemble(entries)
    }

    // MARK: - subset lexing

    private enum TOMLValue: Equatable {
        case string(String)
        case integer(Int)
    }

    private static func isBareKey(_ key: String) -> Bool {
        key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Strips a trailing `#` comment from a non-string line fragment.
    private static func stripTrailingComment(afterValueIn line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line }
        return String(line[..<hash]).trimmingCharacters(in: .whitespaces)
    }

    private static func parseValue(_ raw: String) -> TOMLValue? {
        if raw.hasPrefix("\"") {
            // Basic quoted string, no escape sequences (none are documented).
            let afterOpen = raw.index(after: raw.startIndex)
            guard let close = raw[afterOpen...].firstIndex(of: "\"") else { return nil }
            let rest = String(raw[raw.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
            return .string(String(raw[afterOpen..<close]))
        }
        let bare = stripTrailingComment(afterValueIn: raw)
        guard !bare.isEmpty, bare.allSatisfy(\.isNumber), let int = Int(bare) else { return nil }
        return .integer(int)
    }

    // MARK: - entry semantics

    private static func assemble(_ entries: [[String: TOMLValue]]) -> HostConfigResult {
        var result = HostConfigResult()
        var seenHostIDs = Set<String>()

        for (index, entry) in entries.enumerated() {
            let label = "hosts entry #\(index + 1)"
            var entry = entry

            for unknown in entry.keys.filter({ !knownKeys.contains($0) }).sorted() {
                result.diagnostics.append("\(label): unknown key `\(unknown)` ignored")
                entry.removeValue(forKey: unknown)
            }

            guard case .string(let host)? = entry["host"], !host.isEmpty else {
                result.diagnostics.append("\(label): missing or invalid `host` — entry ignored")
                continue
            }
            guard case .string(let user)? = entry["user"], !user.isEmpty else {
                result.diagnostics.append("\(label): missing or invalid `user` — entry ignored")
                continue
            }
            var port = 22
            if let portValue = entry["port"] {
                guard case .integer(let p) = portValue, (1...65535).contains(p) else {
                    result.diagnostics.append("\(label): `port` must be an integer in 1...65535 — entry ignored")
                    continue
                }
                port = p
            }
            var name = host
            if case .string(let n)? = entry["name"], !n.isEmpty { name = n }
            var identity: String?
            if let identityValue = entry["identity"] {
                guard case .string(let i) = identityValue, !i.isEmpty else {
                    result.diagnostics.append("\(label): `identity` must be a non-empty string — entry ignored")
                    continue
                }
                identity = i
            }
            guard seenHostIDs.insert(host).inserted else {
                result.diagnostics.append("\(label): duplicate host `\(host)` — entry ignored (host is the stable snapshot identifier)")
                continue
            }
            result.hosts.append(ObservedHost(name: name, host: host, user: user, port: port, identity: identity))
        }
        return result
    }
}
