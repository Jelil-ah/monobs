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

    /// Age text (FR5). `nil` ⇒ "jamais", never "0s" for a never-received host.
    static func ageText(_ age: TimeInterval?) -> String {
        guard let age else { return "jamais" }
        // Clock-skew guard (fail-closed): never render a negative age as
        // "-Ns". A negative interval means the freshness timestamp is
        // in the future (wall-clock jump backward, AD-10) — show a neutral "—"
        // rather than a misleading negative count. The pure projection already
        // maps such cases to nil; this guards the display independently.
        guard age >= 0 else { return "—" }
        // Non-negative age → the SHARED tiers (s → min → h → j). Same source as
        // the widget (`AgeFormatting.tiered`), so the popover no longer shows raw
        // seconds that overflow the fixed age column (popover ↔ widget aligned).
        //
        // The `TimeInterval → Int` narrowing rounds UP too (`.up`), not to
        // nearest: `HostProjection.age` comes from `Date.timeIntervalSince` and
        // is therefore FRACTIONAL by nature, so a nearest-rounding here would
        // silently cancel the tiers' ceil (60.1 s → 60 → "1min" while a minute
        // and a tenth has elapsed). Ceil end to end — `TimeInterval` → `Int` →
        // tier — is what makes the guarantee "never presented as fresher than
        // reality" hold for fractional ages too. Consequence, and it is the
        // intended one: a strictly positive sub-second age reads "1s" (0.3 s →
        // "1s"), never "0s"; only an EXACT `0.0` stays "0s".
        return AgeFormatting.tiered(Int(age.rounded(.up)))
    }
}

// MARK: - Mapping couleurs d'état (Story E1 — direction D2 « Braise »)

/// Traduction PRÉSENTATION d'un état **déjà dérivé** vers les couleurs de rôle du
/// thème D2 (`Theme`). Ce n'est PAS de la dérivation d'état (AD-11) : aucun seuil,
/// aucune reconstruction — un simple `switch` sur des valeurs produites par le
/// réducteur pur. Convention D2 : `*-mark`/plein pour les objets graphiques
/// (pastilles), `*-text` (contraste ≥4.5:1) pour le TEXTE d'état.
extension MenuBarPresentation {
    /// Couleur de la pastille (objet graphique). Nominal = vert mat (`greenDim`),
    /// incident = rouge plein (le halo, ressource rare, est appliqué côté vue),
    /// stale = gris plat.
    static func dotColor(for state: HostState) -> Color {
        switch state {
        case .vert: return Theme.greenDim
        case .stale: return Theme.stale
        case .rougeSeuil, .rougeInjoignable: return Theme.red
        }
    }

    /// Couleur du TEXTE d'état (≥4.5:1). Incident = `redText` saturé ; nominal et
    /// stale restent dans l'échelle d'encre atténuée (`muted`) — un état non-rouge
    /// ne « crie » jamais.
    static func textColor(for state: HostState) -> Color {
        switch state {
        case .vert, .stale: return Theme.muted
        case .rougeSeuil, .rougeInjoignable: return Theme.redText
        }
    }

    /// `true` pour les seuls états incident (rouge). Le glow — ressource sémantique
    /// RARE (SPEC §8.1) — n'est alloué qu'à ces états ; jamais au nominal.
    static func isIncident(_ state: HostState) -> Bool {
        switch state {
        case .rougeSeuil, .rougeInjoignable: return true
        case .vert, .stale: return false
        }
    }
}
