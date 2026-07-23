import Foundation

// Story 3.2 — the pure widget-side logic, shared in MonobsKit so it is fully
// testable without a rendered widget and without I/O:
//   • builder    — the writer's core: projection + snapshots → SharedSnapshot,
//   • selector   — the 6-worst selection + explicit overflow (AD-17 reused),
//   • age        — the pure projection of the absolute freshness instant,
//   • presentation — neutral native labels/symbols for the widget rows.
//
// None of this re-derives state (AD-11/AD-12): the builder carries the reducer's
// output verbatim, the selector reuses `StateRanking`, the age reads a timestamp.

/// The writer's PURE core (app side). Maps the already-derived projection plus
/// the raw snapshots into the versioned container. Kept here (not in the app) so
/// the AC8/Mary-#1 property — "serialize the ABSOLUTE freshness instant, not the
/// age duration" — is testable in MonobsKit.
public enum SharedSnapshotBuilder {
    public static func build(projection: MenuBarProjection,
                             snapshots: [String: HostSnapshot]) -> SharedSnapshot {
        // `projection.hosts` carries the reducer's derived `state` (AD-11 — never
        // recomputed here). The absolute freshness instant is read from the raw
        // `SnapshotStore` snapshot (`lastValidReceivedAt`), NOT from the projected
        // duration `HostProjection.age` — serializing the instant is what makes
        // the widget age grow while the app is stopped (AC4, Mary #1).
        let hosts = projection.hosts.map { row in
            SharedHostEntry(hostID: row.hostID,
                            state: row.state,
                            freshnessTimestamp: snapshots[row.hostID]?.lastValidReceivedAt)
        }
        return SharedSnapshot(v: SharedSnapshotCodec.currentVersion, hosts: hosts)
    }
}

/// The widget's 6-worst selection with an explicit overflow (CA-6). Ordering is
/// the single shared AD-17 `StateRanking` — reused, never a second ranking.
public struct WidgetSelection: Equatable, Sendable {
    /// The hosts shown, already ordered worst-state-first (AD-17). At most
    /// `WidgetSelector.maxShown`.
    public let shown: [SharedHostEntry]
    /// How many configured hosts are NOT shown. `0` ⇒ no overflow indicator.
    public let overflowCount: Int

    public var hasOverflow: Bool { overflowCount > 0 }

    public init(shown: [SharedHostEntry], overflowCount: Int) {
        self.shown = shown
        self.overflowCount = overflowCount
    }
}

public enum WidgetSelector {
    /// The medium widget shows the 6 worst hosts (AD-17).
    public static let maxShown = 6

    public static func select(_ hosts: [SharedHostEntry]) -> WidgetSelection {
        // Reuse the single AD-17 ranking — worst state first, ties by host ID
        // ascending. NOT re-implemented here.
        let ordered = StateRanking.ordered(hosts,
                                           hostID: { $0.hostID },
                                           state: { $0.state })
        // ≤6 ⇒ all shown, no overflow. ≥7 ⇒ 6 worst + explicit overflow (exact
        // boundary: N=6 no overflow, N=7 overflow of 1).
        guard ordered.count > maxShown else {
            return WidgetSelection(shown: ordered, overflowCount: 0)
        }
        return WidgetSelection(shown: Array(ordered.prefix(maxShown)),
                               overflowCount: ordered.count - maxShown)
    }
}

/// Age is a PURE projection of the absolute freshness instant (AD-12 / FR5),
/// never a re-derivation of state. It GROWS as `now` advances against a fixed
/// `freshnessTimestamp` — the mechanism behind "frozen best-effort, age
/// growing" when the app is stopped (AC4).
public enum WidgetAge {
    /// `age = now − freshnessTimestamp`. `nil` freshness ⇒ `nil` (never seen).
    /// A future timestamp (wall-clock skew, AD-10) ⇒ `nil` — fail-closed,
    /// consistent with `MenuBarProjector` and `MenuBarPresentation`: never a
    /// negative age.
    public static func age(freshnessTimestamp: Date?, now: Date) -> TimeInterval? {
        guard let timestamp = freshnessTimestamp else { return nil }
        let raw = now.timeIntervalSince(timestamp)
        return raw >= 0 ? raw : nil
    }
}

/// Neutral native presentation for the widget rows (Q3 gated — no palette, no
/// asset). Shared in MonobsKit so the extension does not re-invent formatting;
/// mirrors the app's neutral menu-bar vocabulary for cross-surface consistency
/// (AD-12) without duplicating any ranking.
public enum WidgetPresentation {
    public static func symbol(for state: HostState) -> String {
        switch state {
        case .vert: return "checkmark.circle"
        case .stale: return "clock.badge.questionmark"
        case .rougeSeuil: return "exclamationmark.triangle"
        case .rougeInjoignable: return "bolt.horizontal.circle"
        }
    }

    public static func label(for state: HostState) -> String {
        switch state {
        case .vert: return "vert"
        case .stale: return "stale"
        case .rougeSeuil: return "rouge (seuil)"
        case .rougeInjoignable: return "rouge (injoignable)"
        }
    }

    /// Age text (FR5). `nil` ⇒ "jamais", never "0 s" for a never-received host.
    ///
    /// Manual, deterministic tiers (s → min → h → j): the widget of WORST hosts
    /// shows large ages as the norm, so raw seconds ("il y a 7200 s") violate the
    /// legible-age requirement (D-3). Not `RelativeDateTimeFormatter` — that is
    /// locale-dependent and non-deterministic, which would break the unit tests.
    /// `age` is guaranteed non-negative (`WidgetAge.age` fails closed to `nil` on
    /// a future timestamp), so no negative branch is needed here.
    public static func ageText(_ age: TimeInterval?) -> String {
        guard let age else { return "jamais" }
        let seconds = Int(age.rounded())
        if seconds < 60 { return "il y a \(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "il y a \(minutes)min" }
        let hours = minutes / 60
        if hours < 24 { return "il y a \(hours)h" }
        return "il y a \(hours / 24)j"
    }

    /// Overflow indicator text (CA-6). Neutral, no direction visuelle.
    public static func overflowText(_ overflowCount: Int) -> String {
        "+\(overflowCount) autres"
    }
}
