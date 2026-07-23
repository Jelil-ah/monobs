import Foundation

// Story 3.2 — the shared app↔widget container contract (AD-10 mirror / AD-12).
//
// The widget lives in a SEPARATE process (a WidgetKit extension), so it cannot
// read the in-memory `SnapshotStore`. The app process — the SOLE writer (AD-12)
// — serializes the ALREADY-derived per-host snapshot into a small versioned
// file; the extension reads it READ-ONLY and projects it. Nothing here re-derives
// state (AD-11): `state` is the reducer's output, carried verbatim.
//
// This module lives in MonobsKit so BOTH targets link the SAME contract, codec
// and file location — no duplicated ranking (StateRanking is reused, not copied)
// and no divergent path resolution.

/// Canonical wire names for `HostState`. This is a serialization label map (like
/// a presentation label), NOT a second ranking and NOT state derivation — the
/// AD-17 order stays the single `StateRanking`. The `switch` is exhaustive, so a
/// future 5th state fails to compile here rather than silently mis-serializing.
enum HostStateWireName {
    static func wireName(_ state: HostState) -> String {
        switch state {
        case .vert: return "vert"
        case .stale: return "stale"
        case .rougeSeuil: return "rougeSeuil"
        case .rougeInjoignable: return "rougeInjoignable"
        }
    }

    /// Reverse map. Unknown ⇒ `nil` (the decoder treats it as corruption and
    /// fails closed to a degradation view rather than guessing a state).
    static func state(_ wire: String) -> HostState? {
        switch wire {
        case "vert": return .vert
        case "stale": return .stale
        case "rougeSeuil": return .rougeSeuil
        case "rougeInjoignable": return .rougeInjoignable
        default: return nil
        }
    }
}

/// One per-host row in the shared container. Carries the ALREADY-derived state
/// and the **absolute** freshness instant — NOT the projected age duration.
///
/// Serializing the absolute instant (`freshnessTimestamp`) is what lets the
/// widget's age keep GROWING while the app is stopped (AC4): the extension
/// computes `age = now − freshnessTimestamp` at each timeline entry. Serializing
/// the duration `HostProjection.age` would freeze it at the write instant and
/// break AC4 (Mary #1).
public struct SharedHostEntry: Equatable, Sendable {
    /// Stable host identifier (the `SnapshotStore` key).
    public let hostID: String
    /// The reducer's output (AD-11) — carried verbatim, never recomputed.
    public let state: HostState
    /// Absolute client-reception instant of the last valid report
    /// (`HostSnapshot.lastValidReceivedAt`). `nil` when no valid report was ever
    /// received — the widget renders that as "jamais"/"—", never `0 s`.
    public let freshnessTimestamp: Date?

    public init(hostID: String, state: HostState, freshnessTimestamp: Date?) {
        self.hostID = hostID
        self.state = state
        self.freshnessTimestamp = freshnessTimestamp
    }
}

extension SharedHostEntry: Codable {
    enum CodingKeys: String, CodingKey { case hostID, state, freshnessTimestamp }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(String.self, forKey: .hostID)
        let wire = try container.decode(String.self, forKey: .state)
        guard let decoded = HostStateWireName.state(wire) else {
            throw DecodingError.dataCorruptedError(
                forKey: .state, in: container,
                debugDescription: "unknown host state identifier '\(wire)'")
        }
        state = decoded
        freshnessTimestamp = try container.decodeIfPresent(Date.self, forKey: .freshnessTimestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostID, forKey: .hostID)
        try container.encode(HostStateWireName.wireName(state), forKey: .state)
        try container.encodeIfPresent(freshnessTimestamp, forKey: .freshnessTimestamp)
    }
}

/// The versioned container payload — a mirror of AD-10: a mandatory major
/// version `v` plus the complete per-host derived snapshot (mirror of AD-12).
public struct SharedSnapshot: Codable, Equatable, Sendable {
    /// Major contract version (mirror of AD-10). An unknown value ⇒ degradation,
    /// never a crash (see `SharedSnapshotCodec.decode`).
    public let v: Int
    public let hosts: [SharedHostEntry]

    public init(v: Int = SharedSnapshotCodec.currentVersion, hosts: [SharedHostEntry]) {
        self.v = v
        self.hosts = hosts
    }
}

/// Outcome of a defensive two-stage decode. Every non-`ok` case is a readable
/// degradation, never a crash — the mirror of AD-10 client tolerance.
public enum SharedSnapshotDecodeResult: Equatable, Sendable {
    /// A known-version payload decoded cleanly.
    case ok(SharedSnapshot)
    /// The envelope decoded but its major version is unknown to this build. The
    /// payload is NEVER decoded (it may have an incompatible shape).
    case unsupportedVersion(Int)
    /// Bytes absent / not valid JSON / a known-version payload that failed to
    /// decode (e.g. corruption). Treated as a degradation view.
    case unreadable
}

/// Encode/decode of the shared container. The decode is defensive in TWO stages
/// (AD-10 mirror): read the `v` envelope first; on an unknown major version,
/// return `.unsupportedVersion` WITHOUT touching the rest of the payload — never
/// crash. `freshnessTimestamp` is serialized as an absolute epoch instant
/// (seconds since 1970), which round-trips exactly.
public enum SharedSnapshotCodec {
    /// The single major version this build produces and fully understands.
    public static let currentVersion = 1

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public static func encode(_ snapshot: SharedSnapshot) throws -> Data {
        try makeEncoder().encode(snapshot)
    }

    /// The version envelope — decoded ALONE first so an unknown major version is
    /// detected without ever parsing an incompatible payload.
    private struct VersionEnvelope: Decodable { let v: Int }

    public static func decode(_ data: Data) -> SharedSnapshotDecodeResult {
        let decoder = makeDecoder()
        // Stage 1 — envelope only.
        guard let envelope = try? decoder.decode(VersionEnvelope.self, from: data) else {
            return .unreadable
        }
        guard envelope.v == currentVersion else {
            return .unsupportedVersion(envelope.v)
        }
        // Stage 2 — full payload, known version.
        guard let snapshot = try? decoder.decode(SharedSnapshot.self, from: data) else {
            return .unreadable
        }
        return .ok(snapshot)
    }
}

/// The single shared file location for the container (RISQUE #2 tranché (b) —
/// shared file path, NOT App Group). Resolved via `FileManager` — never a
/// literal `~` (AD-15). Both processes are non-sandboxed (B5 / extension mirrors
/// it), so `.applicationSupportDirectory` resolves to the SAME real
/// `~/Library/Application Support` on each side.
public enum SharedSnapshotLocation {
    public static let directoryName = "Monobs"
    public static let fileName = "state.json"
    /// Widget kind — shared so the app's `reloadTimelines(ofKind:)` and the
    /// extension's `StaticConfiguration(kind:)` can never drift apart.
    public static let widgetKind = "MonobsWidget"

    /// `<Application Support>/Monobs/`.
    public static func directoryURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: false)
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `<Application Support>/Monobs/state.json`.
    public static func stateFileURL(fileManager: FileManager = .default) throws -> URL {
        try directoryURL(fileManager: fileManager).appendingPathComponent(fileName, isDirectory: false)
    }
}
