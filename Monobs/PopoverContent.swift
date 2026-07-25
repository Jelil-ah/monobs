//
//  PopoverContent.swift
//  Monobs
//

import SwiftUI
import MonobsKit

/// Story 3.1 — the popover surface (Epic 3, T-SURFACES). A thin SwiftUI view
/// (AD-11): it CONSUMES `model.projection` and renders it — it derives nothing.
/// The rows arrive already ordered worst-state-first by the single shared ranking
/// module (AD-17, applied in `MenuBarProjector`); the view never re-ranks and
/// never re-derives state or age. It projects the SAME snapshot as the menu bar
/// icon (AD-12), so the two surfaces can never diverge.
///
/// Contents per row: derived state dot, host ID, distinct per-state label
/// (`MenuBarPresentation.label`), and data age (FR5). Detail is INLINE ONLY — no
/// navigation, no server action. The list is UNLIMITED (CA-7): every configured
/// host is shown, scrolled rather than truncated (overflow/limit is the widget,
/// Story 3.2).
///
/// Story E1 — the neutral (Q3) rendering is REPLACED by the D2 « Braise »
/// direction: warm translucent glass gradient (`Theme.popoverGradient` over
/// `.ultraThinMaterial` for macOS vibrancy), glass rim, popover shadow, SF Pro
/// titles, SF Mono tabular metrics, state dots (halo reserved for incidents).
/// Only the STYLE changes — the body still consumes `model.projection` verbatim,
/// and the FR labels/strings are unchanged.
struct PopoverContent: View {
    @ObservedObject var model: MenuBarModel
    /// AD-16 manual refresh. The view only REQUESTS a refresh — it does not
    /// orchestrate cycles; the serialization onto the poll-queue lives in
    /// `HostPollingLoop.requestImmediateCycle()` (D-1 closed there, not here).
    let onRefresh: () -> Void

    /// Cibles de focus clavier du popover. `row` porte le `hostID` : les rows
    /// sont identifiées par cette même clé dans le `ForEach` (AD-17 — l'ordre
    /// vient du projecteur, la vue ne réordonne rien).
    private enum FocusTarget: Hashable {
        case refresh
        case row(String)
    }

    @FocusState private var focusTarget: FocusTarget?

    var body: some View {
        let projection = model.projection
        VStack(alignment: .leading, spacing: 0) {
            header(projection)
            Divider().overlay(Theme.hair)
            content(projection)
            Divider().overlay(Theme.hair)
            footer()
        }
        .frame(width: Theme.popoverW, alignment: .leading)
        .frame(maxHeight: Theme.popoverHMax)
        .background {
            // Verre chaud : la vibrancy macOS (`.ultraThinMaterial`) fait remonter
            // le bureau à travers, le dégradé translucide le teinte (cf. le
            // backdrop-filter blur + gradient alpha bas d'index.html).
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.popoverGradient
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPopover, style: .continuous))
        .overlay {
            // Liseré-reflet du verre (rim clair) — sans lui la surface translucide
            // lit « trou » et non « verre ».
            RoundedRectangle(cornerRadius: Theme.radiusPopover, style: .continuous)
                .strokeBorder(Theme.borderGlass, lineWidth: 0.5)
        }
        .shadow(color: Theme.shadowColor, radius: 30, x: 0, y: 18)
    }

    // MARK: - Header agrégat

    @ViewBuilder
    private func header(_ projection: MenuBarProjection) -> some View {
        HStack(spacing: 12) {
            // Pastille d'agrégat : halo rouge INCIDENT-ONLY ; vert/stale = plat.
            // `nil` (aucun hôte) → neutre stale, rien ne bat.
            StatusDot(state: projection.aggregate ?? .stale, size: 11, header: true)
            Text("Monobs — \(MenuBarPresentation.aggregateLabel(projection.aggregate))")
                .font(Theme.sans(Theme.fsH1, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 12)
            refreshButton
        }
        .padding(.horizontal, Theme.space7)
        .padding(.top, 15)
        .padding(.bottom, 13)
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                Text("Rafraîchir")
            }
            .font(Theme.sans(Theme.fsBody, .medium))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(Theme.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Rafraîchir maintenant")
        .focusable()
        .focused($focusTarget, equals: .refresh)
        .neutralFocusRingOnly()
        .overlay(focusRing(focusTarget == .refresh, radius: Theme.radiusControl))
    }

    // MARK: - Focus clavier (anneau NEUTRE)

    /// Anneau de focus EXPLICITE, dessiné avec `Theme.focusRing`. Il est NEUTRE
    /// dans tous les états (vert / rougeInjoignable / rougeSeuil / stale) : la
    /// couleur d'état reste réservée à la pastille et au libellé, jamais au
    /// chrome de focus. Sans cet anneau, macOS retombe sur l'accent système —
    /// que l'utilisateur peut régler en ROUGE, ce qui encadrerait de rouge une
    /// row DÉJÀ en incident : exactement le brouillage sémantique que le token
    /// neutre existe pour empêcher.
    private func focusRing(_ isFocused: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Theme.focusRing, lineWidth: 2)
            // Opacité plutôt qu'un `if` : l'anneau ne participe jamais au layout,
            // la row ne bouge donc pas d'un pixel quand le focus arrive.
            .opacity(isFocused ? 1 : 0)
    }

    // MARK: - Liste

    @ViewBuilder
    private func content(_ projection: MenuBarProjection) -> some View {
        if projection.hosts.isEmpty {
            Text("aucun hôte configuré")
                .font(Theme.sans(Theme.fsBody))
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, Theme.space7)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Sans limite (CA-7): tous les hôtes, déjà triés AD-17 par le
            // projecteur. `List` scrolle pour N grand — jamais de troncature.
            List {
                ForEach(projection.hosts, id: \.hostID) { host in
                    row(host)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.hair)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)
        }
    }

    private func row(_ host: HostProjection) -> some View {
        let isStale = host.state == .stale
        return HStack(spacing: 11) {
            StatusDot(state: host.state, size: 8)
            Text(host.hostID)
                .font(Theme.sans(Theme.fsHost, isStale ? .medium : .semibold))
                .foregroundStyle(isStale ? Theme.muted : Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(MenuBarPresentation.label(for: host.state))
                .font(Theme.mono(Theme.fsMetric, .medium))
                .monospacedDigit()
                .foregroundStyle(MenuBarPresentation.textColor(for: host.state))
                .lineLimit(1)
            // Âge : `faint` en nominal, PROMU à `ink2` sur stale (signal saillant).
            // Largeur réservée (`ageW`) : ne se comprime jamais.
            Text(MenuBarPresentation.ageText(host.age))
                .font(Theme.mono(Theme.fsMeta))
                .monospacedDigit()
                .foregroundStyle(isStale ? Theme.ink2 : Theme.faint)
                .frame(width: Theme.ageW, alignment: .trailing)
        }
        .padding(.horizontal, Theme.space7)
        .padding(.vertical, Theme.space4)
        .contentShape(Rectangle())
        .focusable()
        .focused($focusTarget, equals: .row(host.hostID))
        .neutralFocusRingOnly()
        .overlay(focusRing(focusTarget == .row(host.hostID), radius: Theme.radiusControl))
    }

    // MARK: - Footer fixe (fraîcheur / cadence, lecture seule)

    private func footer() -> some View {
        HStack {
            Text("Cadence \(Int(HostPollingLoop.defaultCadence)) s")
                .font(Theme.mono(Theme.fsMeta))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, Theme.space7)
        .padding(.vertical, Theme.space5)
        .background(Theme.surfaceFooter)
    }
}

// MARK: - Focus système vs. anneau neutre

private extension View {
    /// Coupe l'effet de focus SYSTÈME pour ne laisser que notre anneau neutre.
    ///
    /// `focusEffectDisabled()` n'existe qu'à partir de macOS 14 ; le plancher du
    /// projet est macOS 13 (`MonobsKit/Package.swift` : `.macOS(.v13)`). Sur 14+,
    /// l'anneau neutre REMPLACE donc bien l'accent système.
    ///
    /// LIMITATION ASSUMÉE sur macOS 13 — dite en clair plutôt qu'euphémisée :
    /// SwiftUI 4 n'expose AUCUNE API pour supprimer l'effet de focus système, et
    /// le neutraliser demanderait de sortir de `.focusable()`/`@FocusState` (hôte
    /// AppKit custom, `focusRingType = .none`), c'est-à-dire une refonte du
    /// layout du popover — hors périmètre de cette story. Conséquence réelle :
    /// sur 13, l'anneau d'accent système reste dessiné SOUS notre overlay
    /// `Theme.focusRing`, et cet accent est réglable en ROUGE par l'utilisateur
    /// dans les Réglages Système — une row DÉJÀ en incident prise au focus peut
    /// donc y être cerclée de rouge. Notre overlay, lui, reste neutre dans TOUS
    /// les états. Neutralité TOTALE garantie à partir de macOS 14 seulement.
    /// Documenté dans `docs/stories/story-E1-theme-braise.md` §Amendments (3).
    @ViewBuilder
    func neutralFocusRingOnly() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}

// MARK: - Pastille d'état

/// La pastille d'état D2. Le halo (glow) est une ressource sémantique RARE
/// (SPEC §8.1) : il n'est dépensé QUE sur l'incident (rouge), jamais sur le
/// nominal ni le stale. Aucune animation — le glow est statique (E3 traitera le
/// glyphe animé).
private struct StatusDot: View {
    let state: HostState
    var size: CGFloat = 8
    var header: Bool = false

    var body: some View {
        let incident = MenuBarPresentation.isIncident(state)
        Circle()
            .fill(MenuBarPresentation.dotColor(for: state))
            .frame(width: size, height: size)
            .shadow(color: incident ? Theme.red.opacity(header ? 0.58 : 0.72) : .clear,
                    radius: incident ? (header ? 6 : 5) : 0)
    }
}
