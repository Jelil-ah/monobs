//
//  MenuBarContent.swift
//  Monobs
//

import SwiftUI
import MonobsKit

/// Presentation-only mapping (Story 1.4). It maps an **already-derived** state
/// (the reducer's output) to a neutral native SF Symbol / label / age string.
/// This is NOT state derivation (AD-11): there is no age-to-threshold
/// comparison and no state reconstruction — only a `switch` over values the
/// pure reducer/projector already produced. Rendering is native and neutral
/// (Q3 gated — no palette, no visual direction).
enum MenuBarPresentation {
    static func symbol(for state: HostState) -> String {
        switch state {
        case .vert: return "checkmark.circle"
        case .stale: return "clock.badge.questionmark"
        case .rougeSeuil: return "exclamationmark.triangle"
        case .rougeInjoignable: return "bolt.horizontal.circle"
        }
    }

    /// Menu bar icon for the aggregate. `nil` (zero hosts) renders a neutral
    /// dashed circle — never the vert symbol (fail-closed).
    static func aggregateSymbol(_ aggregate: HostState?) -> String {
        guard let aggregate else { return "circle.dashed" }
        return symbol(for: aggregate)
    }

    static func label(for state: HostState) -> String {
        switch state {
        case .vert: return "vert"
        case .stale: return "stale"
        case .rougeSeuil: return "rouge (seuil)"
        case .rougeInjoignable: return "rouge (injoignable)"
        }
    }

    static func aggregateLabel(_ aggregate: HostState?) -> String {
        guard let aggregate else { return "aucun hôte" }
        return label(for: aggregate)
    }

    /// Age text (FR5). `nil` ⇒ "jamais", never "0 s" for a never-received host.
    static func ageText(_ age: TimeInterval?) -> String {
        guard let age else { return "jamais" }
        // Clock-skew guard (fail-closed): never render a negative age as
        // "il y a -N s". A negative interval means the freshness timestamp is
        // in the future (wall-clock jump backward, AD-10) — show a neutral "—"
        // rather than a misleading negative count. The pure projection already
        // maps such cases to nil; this guards the display independently.
        guard age >= 0 else { return "—" }
        return "il y a \(Int(age.rounded())) s"
    }
}
