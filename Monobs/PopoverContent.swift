//
//  PopoverContent.swift
//  Monobs
//

import AppKit
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
///
/// CAP-1 — le popover porte l'action « Quitter » (pied, à droite). Avec
/// `.menuBarExtraStyle(.window)` l'icône de barre n'ouvre AUCUN menu contextuel :
/// sans cette action, l'app ne se ferme que depuis le Moniteur d'activité. Deux
/// gestes suffisent désormais : clic sur l'icône → clic sur « Quitter ».
///
/// CAP-10 — le popover porte aussi l'accès aux RÉGLAGES des hôtes (pied, à
/// gauche de « Quitter »), et son état vide n'est plus une impasse : au premier
/// lancement, sans `hosts.toml`, il propose directement « Ajouter un hôte… ».
/// C'est l'unique chemin d'accès possible : `LSUIElement` prive l'app de Dock et
/// de menu applicatif.
///
/// CAP-6 — le verre chaud n'est plus inconditionnel. Sous « Réduire la
/// transparence » ou « Augmenter le contraste », le fond bascule sur le repli
/// OPAQUE prune sombre du thème Braise (SPEC Q5) — jamais le fond système : on
/// dégrade la matière, pas l'identité. Sous contraste augmenté, contours et
/// séparateurs sont renforcés puisque la matière ne délimite plus les zones.
struct PopoverContent: View {
    @ObservedObject var model: MenuBarModel
    /// AD-16 manual refresh. The view only REQUESTS a refresh — it does not
    /// orchestrate cycles; the serialization onto the poll-queue lives in
    /// `HostPollingLoop.requestImmediateCycle()` (D-1 closed there, not here).
    let onRefresh: () -> Void
    /// CAP-10 — ouvre l'écran de réglages des hôtes. Le popover est le SEUL
    /// endroit d'où l'utilisateur peut y accéder : l'app est `LSUIElement`, elle
    /// n'a ni Dock ni menu applicatif. Le point d'entrée existe donc dans les
    /// deux états — pied de popover quand des hôtes sont surveillés, action
    /// principale de l'état vide au premier lancement.
    let onOpenSettings: () -> Void

    /// Cibles de focus clavier du popover. `row` porte le `hostID` : les rows
    /// sont identifiées par cette même clé dans le `ForEach` (AD-17 — l'ordre
    /// vient du projecteur, la vue ne réordonne rien).
    private enum FocusTarget: Hashable {
        case refresh
        case settings
        case addHost
        case quit
        case row(String)
    }

    @FocusState private var focusTarget: FocusTarget?

    // MARK: - Réglages d'accessibilité (CAP-6)

    /// « Réglages Système → Accessibilité → Affichage → Réduire la transparence ».
    /// SwiftUI publie le réglage dans l'environnement et invalide la vue quand il
    /// change : aucun observateur AppKit à câbler.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Même écran, « Augmenter le contraste » → `.increased`.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Contraste augmenté actif.
    private var increasedContrast: Bool { colorSchemeContrast == .increased }

    /// Vrai dès qu'un des deux réglages est actif. Les deux retirent à la matière
    /// son rôle : `Réduire la transparence` la supprime, `Augmenter le contraste`
    /// la rend contre-productive. Même repli opaque dans les deux cas.
    private var prefersOpaqueSurface: Bool { reduceTransparency || increasedContrast }

    var body: some View {
        let projection = model.projection
        VStack(alignment: .leading, spacing: 0) {
            header(projection)
            Divider().overlay(hairline)
            content(projection)
            Divider().overlay(hairline)
            footer()
        }
        .frame(width: Theme.popoverW, alignment: .leading)
        .frame(maxHeight: Theme.popoverHMax)
        // I8 — aucune surface animée : le basculement verre ↔ opaque est
        // instantané. La transaction neutralisée empêche une animation ambiante
        // d'attraper le changement de fond et d'en faire un fondu.
        .background { surface.transaction { $0.animation = nil } }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPopover, style: .continuous))
        .overlay {
            // Liseré-reflet du verre (rim clair) — sans lui la surface translucide
            // lit « trou » et non « verre ». Sous contraste augmenté il cesse
            // d'être un reflet pour devenir le CONTOUR de la surface : plus opaque
            // et plus épais, seul délimiteur restant une fois la matière tombée.
            RoundedRectangle(cornerRadius: Theme.radiusPopover, style: .continuous)
                .strokeBorder(rimColor, lineWidth: rimWidth)
        }
        .shadow(color: Theme.shadowColor, radius: 30, x: 0, y: 18)
    }

    // MARK: - Surface (CAP-6)

    /// Fond du popover. Deux rendus, jamais un troisième : verre chaud par défaut,
    /// repli opaque Braise sous réglage d'accessibilité.
    @ViewBuilder
    private var surface: some View {
        if prefersOpaqueSurface {
            // Repli opaque prune sombre (SPEC Q5). Pas de `.ultraThinMaterial` du
            // tout : sous « Réduire la transparence » le matériau ne floute plus
            // rien et le dégradé à alpha ~0,5 laisserait le bureau décider du
            // contraste réel. Ici le fond est déterministe.
            Theme.popoverOpaqueGradient
        } else {
            // Verre chaud : la vibrancy macOS (`.ultraThinMaterial`) fait remonter
            // le bureau à travers, le dégradé translucide le teinte (cf. le
            // backdrop-filter blur + gradient alpha bas d'index.html).
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.popoverGradient
            }
        }
    }

    // MARK: - Contours, dérivés du réglage de contraste (CAP-6)

    /// Filets internes (séparateurs de zones et de rows).
    private var hairline: Color { increasedContrast ? Theme.hairContrast : Theme.hair }
    /// Liseré périphérique du popover.
    private var rimColor: Color { increasedContrast ? Theme.borderGlassContrast : Theme.borderGlass }
    /// `strokeBorder` dessine vers l'intérieur : épaissir ne déplace aucun pixel
    /// de contenu (le layout est hors périmètre de la tranche).
    private var rimWidth: CGFloat { increasedContrast ? 1 : 0.5 }
    /// Bord des contrôles (Rafraîchir, Quitter).
    private var controlBorderColor: Color {
        increasedContrast ? Theme.controlBorderContrast : Theme.controlBorder
    }
    /// Bandeau de pied.
    private var footerFill: Color {
        increasedContrast ? Theme.surfaceFooterContrast : Theme.surfaceFooter
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
            controlChrome(systemImage: "arrow.clockwise",
                          title: "Rafraîchir",
                          ink: Theme.ink2,
                          horizontalPadding: 11,
                          verticalPadding: 6)
        }
        .buttonStyle(.plain)
        .help("Rafraîchir maintenant")
        .focusable()
        .focused($focusTarget, equals: .refresh)
        .neutralFocusRingOnly()
        .overlay(focusRing(focusTarget == .refresh, radius: Theme.radiusControl))
    }

    /// Chrome commun des contrôles du popover (pastille arrondie, fond `controlFill`,
    /// bord `controlBorder`). Un seul endroit : « Quitter » ne peut pas dériver du
    /// style de « Rafraîchir », et le renfort de bord sous contraste augmenté
    /// s'applique aux deux par construction. Ce n'est PAS un bouton d'accent : la
    /// couleur d'accent Braise reste réservée aux états.
    private func controlChrome(systemImage: String,
                               title: String,
                               ink: Color,
                               horizontalPadding: CGFloat,
                               verticalPadding: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(Theme.sans(Theme.fsBody, .medium))
        .foregroundStyle(ink)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(Theme.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .strokeBorder(controlBorderColor, lineWidth: 0.5)
        )
    }

    // MARK: - Quitter (CAP-1)

    /// L'action « Quitter » manquante : avec `.menuBarExtraStyle(.window)` l'icône
    /// de barre ouvre le popover et rien d'autre — aucun menu contextuel, donc
    /// aucun « Quitter » système. Placée au PIED du popover, côté droit : la zone
    /// de service (cadence, méta), pas la zone de données. Elle est trouvable sans
    /// disputer l'attention aux hôtes surveillés, et reste à deux gestes de
    /// l'icône (clic icône → clic Quitter) — A3 tenu.
    ///
    /// Registre visuel : même chrome que « Rafraîchir », encre `muted` au lieu de
    /// `ink2` et pavé plus compact. Un cran sous l'action primaire, jamais un
    /// bouton d'accent — le rouge reste la couleur de l'incident, pas du danger
    /// d'interface.
    private var quitButton: some View {
        Button {
            // Terminaison RÉELLE du process : `NSApplication.terminate` déroule la
            // séquence d'arrêt AppKit (l'app quitte, le `MonobsRuntime` est libéré,
            // `HostPollingLoop.stop()` court via son `deinit`). Ce n'est ni un
            // masquage de fenêtre ni un `exit()` brutal — après ce geste, aucun
            // Monobs ne subsiste dans le Moniteur d'activité (CAP-1 success).
            // I3 tenu : le geste porte sur le process local, jamais sur un serveur.
            NSApplication.shared.terminate(nil)
        } label: {
            controlChrome(systemImage: "power",
                          title: "Quitter",
                          ink: increasedContrast ? Theme.ink2 : Theme.muted,
                          horizontalPadding: 9,
                          verticalPadding: 4)
        }
        .buttonStyle(.plain)
        .help("Quitter Monobs")
        .accessibilityLabel("Quitter Monobs")
        // ⌘Q pendant que le popover a le focus : l'app est LSUIElement et n'a
        // donc aucun menu applicatif pour porter le raccourci standard.
        .keyboardShortcut("q", modifiers: .command)
        .focusable()
        .focused($focusTarget, equals: .quit)
        .neutralFocusRingOnly()
        .overlay(focusRing(focusTarget == .quit, radius: Theme.radiusControl))
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
            emptyState
        } else {
            // Sans limite (CA-7): tous les hôtes, déjà triés AD-17 par le
            // projecteur. `List` scrolle pour N grand — jamais de troncature.
            List {
                ForEach(projection.hosts, id: \.hostID) { host in
                    row(host)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(hairline)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)
        }
    }

    // MARK: - État vide (CAP-10, premier lancement)

    /// Sans configuration, l'ancien popover disait « aucun hôte configuré » et
    /// s'arrêtait là : la seule issue était d'écrire `hosts.toml` à la main dans
    /// un terminal. C'est exactement ce qui rendait l'app impartageable. L'état
    /// vide devient donc le premier pas du parcours : il nomme la situation,
    /// annonce ce qui va se passer, et porte l'action.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Aucun hôte configuré")
                .font(Theme.sans(Theme.fsHost, .semibold))
                .foregroundStyle(Theme.ink)
            Text("Ajoutez un serveur depuis les réglages : la surveillance démarre aussitôt, sans relancer Monobs.")
                .font(Theme.sans(Theme.fsBody))
                // Encre remontée d'un cran sous contraste augmenté : `faint` est
                // le bas de l'échelle, c'est le premier texte à souffrir.
                .foregroundStyle(increasedContrast ? Theme.ink2 : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenSettings) {
                controlChrome(systemImage: "plus",
                              title: "Ajouter un hôte…",
                              ink: Theme.ink,
                              horizontalPadding: 11,
                              verticalPadding: 6)
            }
            .buttonStyle(.plain)
            .help("Ouvrir les réglages pour ajouter un hôte")
            .focusable()
            .focused($focusTarget, equals: .addHost)
            .neutralFocusRingOnly()
            .overlay(focusRing(focusTarget == .addHost, radius: Theme.radiusControl))
        }
        .padding(.horizontal, Theme.space7)
        .padding(.vertical, Theme.space6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Réglages (CAP-10)

    /// Point d'entrée permanent, au pied, à gauche de « Quitter » : même registre
    /// mat que les autres contrôles de service. Il reste à deux gestes de l'icône
    /// de barre (clic icône → clic Réglages), comme « Quitter » (A3).
    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            controlChrome(systemImage: "slider.horizontal.3",
                          title: "Réglages",
                          ink: increasedContrast ? Theme.ink2 : Theme.muted,
                          horizontalPadding: 9,
                          verticalPadding: 4)
        }
        .buttonStyle(.plain)
        .help("Ajouter, modifier ou retirer un hôte")
        .accessibilityLabel("Réglages des hôtes")
        // ⌘, — le raccourci système des réglages, que l'app ne peut pas obtenir
        // autrement faute de menu applicatif (LSUIElement).
        .keyboardShortcut(",", modifiers: .command)
        .focusable()
        .focused($focusTarget, equals: .settings)
        .neutralFocusRingOnly()
        .overlay(focusRing(focusTarget == .settings, radius: Theme.radiusControl))
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
                // Sous contraste augmenté, le nominal passe `faint`→`muted` : la
                // promotion `ink2` du stale reste AU-DESSUS, donc l'écart qui
                // porte le signal est préservé, pas aplati.
                .foregroundStyle(isStale ? Theme.ink2 : (increasedContrast ? Theme.muted : Theme.faint))
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

    // MARK: - Footer fixe (cadence en lecture seule + Réglages + Quitter)

    private func footer() -> some View {
        HStack(spacing: 12) {
            Text("Cadence \(Int(HostPollingLoop.defaultCadence)) s")
                .font(Theme.mono(Theme.fsMeta))
                .monospacedDigit()
                .foregroundStyle(increasedContrast ? Theme.ink2 : Theme.muted)
            Spacer(minLength: 12)
            settingsButton
            quitButton
        }
        .padding(.horizontal, Theme.space7)
        .padding(.vertical, Theme.space5)
        .background(footerFill)
    }
}

// MARK: - Focus système vs. anneau neutre

private extension View {
    /// Coupe l'effet de focus SYSTÈME pour ne laisser que notre anneau neutre.
    ///
    /// `focusEffectDisabled()` demande macOS 14 ; c'est désormais le plancher du
    /// projet (`MonobsKit/Package.swift` : `.macOS(.v14)`, `MACOSX_DEPLOYMENT_TARGET
    /// = 14.0`), donc l'appel est INCONDITIONNEL et l'anneau neutre remplace
    /// l'accent système partout. La limitation macOS 13 documentée par la story E1
    /// — l'accent système, réglable en ROUGE, pouvait cercler de rouge une row
    /// déjà en incident — est résolue par le plancher, pas contournée
    /// (`docs/specs/spec-monobs-v1/accessibility-notes.md` §2).
    func neutralFocusRingOnly() -> some View {
        focusEffectDisabled()
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
