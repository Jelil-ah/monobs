import Foundation

/// One per-host projection row: the derived state and the exposed data age
/// (FR5). Pure projection — never a source of state re-derivation (AD-12).
public struct HostProjection: Equatable, Sendable {
    /// Stable host identifier (`ObservedHost.host`, the `SnapshotStore` key).
    public let hostID: String
    /// The state produced by the single reducer (AD-11) — not recomputed here.
    public let state: HostState
    /// Age = `now − lastValidReceivedAt`. `nil` when no valid report was ever
    /// received; surfaces render `nil` as "jamais"/"—", never `0 s`
    /// (fail-closed: a never-seen host is not "just refreshed").
    public let age: TimeInterval?

    public init(hostID: String, state: HostState, age: TimeInterval?) {
        self.hostID = hostID
        self.state = state
        self.age = age
    }
}

/// The menu bar projection: the aggregate state plus the ordered per-host rows.
public struct MenuBarProjection: Equatable, Sendable {
    /// Aggregate = worst state over ALL configured hosts (AD-17) — not just the
    /// reachable subset: stale and never-received hosts count, so an unreachable
    /// host can never be silently excluded from the aggregate (excluding it
    /// would be a fail-open once story 2.2 adds `rougeInjoignable`). `nil` for
    /// the degenerate zero-host case — fail-closed, never `.vert`, and never a
    /// 5th canonical state (a projection distinction, rendered as a neutral "no
    /// host" label).
    public let aggregate: HostState?
    /// Per-host rows ordered AD-17 (worst first, ties by host ID ascending).
    public let hosts: [HostProjection]

    public init(aggregate: HostState?, hosts: [HostProjection]) {
        self.aggregate = aggregate
        self.hosts = hosts
    }
}

/// Pure projection for the menu bar (AD-11 / AD-12). It **calls** the single
/// reducer and the shared ranking module — it re-implements neither. Lives in
/// the pure package so it is fully testable; the SwiftUI view is thin and only
/// renders this output.
public enum MenuBarProjector {
    public static func project(hosts: [ObservedHost],
                               snapshots: [String: HostSnapshot],
                               now: Date,
                               tailscaleLocalUp: Bool,
                               stalenessThreshold: TimeInterval = StateReducer.defaultStalenessThreshold) -> MenuBarProjection {
        let rows = hosts.map { host -> HostProjection in
            let snapshot = snapshots[host.host] ?? HostSnapshot()
            // The single reducer derives the state (AD-11); the projection never
            // compares an age to a threshold or reconstructs a state. The global
            // `tailscaleLocalUp` fact is FORWARDED to the reducer unchanged — the
            // projection does not interpret it (the FR10.1 override lives in the
            // reducer, not here, or the projection would be deriving state).
            let state = StateReducer.reduce(snapshot, now: now,
                                            tailscaleLocalUp: tailscaleLocalUp,
                                            stalenessThreshold: stalenessThreshold)
            // Age is a pure projection of the freshness timestamp, not a
            // freshness decision (AD-12): nil stays nil (never rendered 0 s).
            // Clock-skew guard (fail-closed, consistent with the reducer): if
            // the last reception is timestamped in the future (raw age < 0, a
            // wall-clock jump backward — AD-10), the age is not trustworthy, so
            // it is projected as nil ("unknown") rather than a negative count.
            // The surface therefore never renders "il y a -N s".
            let age: TimeInterval? = snapshot.lastValidReceivedAt.flatMap {
                let raw = now.timeIntervalSince($0)
                return raw >= 0 ? raw : nil
            }
            return HostProjection(hostID: host.host, state: state, age: age)
        }
        let ordered = StateRanking.ordered(rows, hostID: { $0.hostID }, state: { $0.state })
        let aggregate = StateRanking.worst(ordered.map { $0.state })
        return MenuBarProjection(aggregate: aggregate, hosts: ordered)
    }
}
