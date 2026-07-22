import Foundation

/// The single shared worst-state-first ranking module (AD-17). One source of
/// truth for the state ordering; stories 2.2 / 2.3 / 3.x reuse it without
/// rewriting the order.
///
/// Complete total order (worst → best):
///   `rougeInjoignable` > `rougeSeuil` > `stale` > `vert`.
/// The full order is encoded now (and tested on the four states constructed
/// directly), even though the skeleton reducer only ever emits `{vert, stale}`.
public enum StateRanking {

    /// Severity rank in the AD-17 total order — higher is worse. This is the
    /// only place the order is defined.
    public static func severity(_ state: HostState) -> Int {
        switch state {
        case .vert: return 0
        case .stale: return 1
        case .rougeSeuil: return 2
        case .rougeInjoignable: return 3
        }
    }

    /// Worst (most severe) state over a set, or `nil` for the empty set.
    ///
    /// The empty case is degenerate and **fail-closed**: it returns `nil`, never
    /// `.vert` — an empty set is not "healthy". Callers render `nil` as a neutral
    /// "no host" projection; it is a projection distinction, never a 5th
    /// canonical state.
    public static func worst(_ states: [HostState]) -> HostState? {
        states.max { severity($0) < severity($1) }
    }

    /// AD-17 ordering: worst state first, ties broken by host identifier
    /// ascending.
    ///
    /// Precondition: host IDs are unique. This holds by construction for every
    /// production caller — `HostConfig.assemble` rejects duplicate host IDs and
    /// the `SnapshotStore` is keyed by host ID — which makes (severity, hostID)
    /// a strict total order. As defence in depth (this API is public and does
    /// not re-verify uniqueness), a final tie-break on the input index keeps the
    /// result fully deterministic even if a future caller passes two rows with
    /// the same host ID: it then preserves input order rather than depending on
    /// `sorted(by:)` stability, which Swift does not guarantee.
    public static func ordered<Item>(_ items: [Item],
                                     hostID: (Item) -> String,
                                     state: (Item) -> HostState) -> [Item] {
        items.enumerated().sorted { lhs, rhs in
            let sl = severity(state(lhs.element))
            let sr = severity(state(rhs.element))
            if sl != sr { return sl > sr }                    // worst first
            let hl = hostID(lhs.element), hr = hostID(rhs.element)
            if hl != hr { return hl < hr }                    // tie-break: host ID ascending
            return lhs.offset < rhs.offset                    // stable: preserve input order
        }.map { $0.element }
    }
}
