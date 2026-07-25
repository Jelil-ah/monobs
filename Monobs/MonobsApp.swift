//
//  MonobsApp.swift
//  Monobs
//

import AppKit
import Foundation
import Combine
import SwiftUI
import MonobsKit

/// Observable holder for the latest menu bar projection. The view subscribes to
/// it; it holds only already-derived values (AD-11) — no state is derived here.
final class MenuBarModel: ObservableObject {
    @Published var projection: MenuBarProjection

    init(projection: MenuBarProjection = MenuBarProjection(aggregate: nil, hosts: [])) {
        self.projection = projection
    }
}

/// CAP-10 — référence FAIBLE et différée vers la boucle de polling, pour que le
/// hook de fin de cycle projette la liste d'hôtes RÉELLEMENT observée par le
/// cycle qui vient de finir, et non celle figée à la construction.
///
/// Pourquoi ce détour : le hook `onCycleComplete` est passé au constructeur de
/// `HostPollingLoop`, donc il ne peut pas capturer la boucle qu'il sert. Depuis
/// T9 la liste est mutable ; capturer `config.hosts` gèlerait la projection sur
/// la configuration du démarrage, et un hôte ajouté depuis les réglages
/// n'apparaîtrait jamais dans le popover — l'app polerait le bon hôte en
/// affichant l'ancienne liste.
///
/// La référence est faible : la boucle retient le hook, le hook retiendrait
/// autrement la boucle (cycle de rétention, `deinit` jamais appelé, `stop()`
/// jamais joué).
private final class PollingLoopReference: @unchecked Sendable {
    weak var loop: HostPollingLoop?
}

private final class MonobsRuntime {
    let model = MenuBarModel()

    private let snapshotStore: SnapshotStore
    private let pollingLoop: HostPollingLoop
    /// CAP-10 — la fenêtre de réglages, créée à la première ouverture et
    /// conservée ensuite : ré-ouvrir ne repart pas d'un modèle neuf, mais relit
    /// le disque (cf. `SettingsWindowController.present()`).
    private var settingsWindow: SettingsWindowController?
    // Story 2.1: the global Tailscale-local availability fact (AD-14), produced
    // beside the per-host snapshots. The detector re-probes each read; the store
    // holds the latest value, refreshed once per poll cycle. NOTHING consumes it
    // yet — the reducer is deliberately NOT wired to it (that is Story 2.2's
    // FR10.1 override). Kept here only so 2.2 can read `tailscaleFact.current`.
    private let tailscaleDetector = TailscaleDetector()
    let tailscaleFact = TailscaleFactStore()
    // Story 2.4: the rising-edge notification coordinator (AD-13). It owns the
    // per-host "previous state" memory and drives the injected emitter. The real
    // `UserNotifications` effect is injected here; the coordinator itself is pure
    // logic (MonobsKit). Touched only by the poll-loop thread under this wiring,
    // but the coordinator locks its own state (F-1) so a future manual refresh
    // (AD-16) can call `processCycle` safely.
    private let coordinator = NotificationCoordinator(emitter: UserNotificationEmitter.emit)

    init() {
        let config = HostConfigLoader.load()
        let store = SnapshotStore()
        snapshotStore = store
        let model = self.model
        // CAP-10 : la liste observée n'est plus figée. Elle est relue à chaque
        // fin de cycle depuis la boucle elle-même — donc exactement la liste que
        // ce cycle a visitée (la reconfiguration T9 ne peut jamais atterrir au
        // milieu d'un cycle : elle est sérialisée sur la même file). Le repli sur
        // `bootHosts` ne sert qu'à la fenêtre entre la construction du hook et
        // l'affectation de la référence, avant tout premier cycle.
        let loopReference = PollingLoopReference()
        let bootHosts = config.hosts
        let currentHosts: @Sendable () -> [ObservedHost] = {
            loopReference.loop?.observedHosts ?? bootHosts
        }
        let tailscaleDetector = self.tailscaleDetector
        let tailscaleFact = self.tailscaleFact
        let coordinator = self.coordinator
        // Story 2.4: request notification authorization once at startup
        // (provisional posture §Blocker.1). Fire-and-forget — the rising-edge
        // decision + write-back run regardless of the permission outcome.
        UserNotificationEmitter.requestAuthorization()
        pollingLoop = HostPollingLoop(
            hosts: config.hosts,
            snapshotStore: store,
            pollHost: { host in
                SSHPollRunner.poll(host: host, onDiagnostics: Self.log)
            },
            // Recompute the projection at the loop's own cadence (Story 1.4,
            // CA-1) — no second cadence parameter. The pure projector derives
            // everything; this closure only feeds it the current snapshots.
            onCycleComplete: {
                // Story 2.1: refresh the global Tailscale fact at the loop's own
                // cadence (no second cadence). Read-only. Story 2.2 now CONSUMES
                // it: the freshly-updated `tailscaleFact.current` is passed to
                // the projector, which forwards it to the reducer for the FR10.1
                // override.
                tailscaleFact.update(tailscaleDetector.tailscaleLocalUp)
                // Read the snapshots ONCE so the projection and the shared-container
                // writer (Story 3.2) observe exactly the same cycle.
                let snapshots = store.allSnapshots()
                let projection = MenuBarProjector.project(hosts: currentHosts(),
                                                          snapshots: snapshots,
                                                          now: Date(),
                                                          tailscaleLocalUp: tailscaleFact.current)
                // Story 2.4 (AD-13): AFTER the projection, feed the already-derived
                // per-host states (AD-11, no re-derivation) to the rising-edge
                // coordinator. This runs ONLY on real poll cycles (`onCycleComplete`),
                // NEVER on the pre-poll initial projection below — so the FIRST poll
                // cycle IS the silent baseline (cold start muet even if a host is
                // already red: previous map empty ⇒ nil ⇒ muet).
                // Don't crash the poll thread on a duplicate hostID: keep the
                // first occurrence instead of a precondition failure. Symmetric
                // with the UI `ForEach(id: \.hostID)`, which already tolerates a
                // duplicate rather than aborting.
                let currentStates = Dictionary(
                    projection.hosts.map { ($0.hostID, $0.state) },
                    uniquingKeysWith: { first, _ in first })
                coordinator.processCycle(currentStates: currentStates)
                // Story 3.2 (AD-12): serialize the ALREADY-derived projection plus
                // the ABSOLUTE freshness instant (read from `snapshots`, NOT the age
                // duration) into the shared container for the WidgetKit extension.
                // Same hook as the projection/notification — the app is the sole
                // writer; the widget only reads.
                SharedSnapshotWriter.write(projection: projection, snapshots: snapshots)
                DispatchQueue.main.async { model.projection = projection }
            }
        )
        // Publie la boucle AVANT tout cycle : `start()` (plus bas) est le premier
        // à en enqueuer un, donc le hook ne peut pas s'exécuter sur la référence
        // encore vide.
        loopReference.loop = pollingLoop
        config.diagnostics.forEach(Self.log)
        // Prime the global Tailscale fact BEFORE the initial projection so the
        // cold-start view is honest: the fact starts `false` (fail-closed), and
        // even after this first probe a `false` result forces every host grey —
        // never a premature vert/red. Ordered before `project(...)` so the
        // initial projection consumes a fresh fact rather than the constructor
        // default.
        tailscaleFact.update(tailscaleDetector.tailscaleLocalUp)
        // Initial projection before the first cycle: honest degenerate/stale
        // view (no data yet), never a premature vert. Passes the primed
        // `tailscaleFact.current` — fail-closed at startup.
        let initialSnapshots = store.allSnapshots()
        model.projection = MenuBarProjector.project(hosts: config.hosts,
                                                    snapshots: initialSnapshots,
                                                    now: Date(),
                                                    tailscaleLocalUp: tailscaleFact.current)
        // Story 3.2: prime the shared container before the first poll so the widget
        // has an honest (empty/never-received) snapshot to read immediately.
        SharedSnapshotWriter.write(projection: model.projection, snapshots: initialSnapshots)
        pollingLoop.start()
    }

    /// Story 3.1 (AD-16) — the popover's manual refresh entry point. It routes to
    /// `HostPollingLoop.requestImmediateCycle()`, which ENQUEUES an immediate cycle
    /// on the SAME serial poll-queue as the scheduled poller (DEBT.md#D-1 closed
    /// there). The UI never calls `runOneCycle`/`processCycle` directly, so a
    /// manual refresh can never run concurrently with a scheduled cycle.
    func requestRefresh() {
        pollingLoop.requestImmediateCycle()
    }

    /// CAP-10 — ouvre (ou ramène au premier plan) la fenêtre de réglages. Point
    /// d'entrée unique du popover, y compris depuis l'état vide du premier
    /// lancement.
    func openSettings() {
        let controller = settingsWindow ?? SettingsWindowController(
            apply: { [weak self] hosts in self?.applyConfiguredHosts(hosts) })
        settingsWindow = controller
        controller.present()
    }

    /// CAP-10 — le pont réglages → runtime, et la seule chose que l'écran de
    /// réglages sait faire au moteur.
    ///
    /// `reconfigure` (T9) ENQUEUE le remplacement sur la file sérielle du
    /// poller : la nouvelle liste prend effet entre deux cycles, jamais au
    /// milieu de l'un d'eux. `requestImmediateCycle` (Story 3.1) enchaîne sur la
    /// MÊME file, donc strictement après le remplacement — c'est ce qui rend le
    /// résultat visible tout de suite au lieu d'attendre la cadence.
    ///
    /// Aucun appel si rien n'a changé : `reconfigure` répond `false` sur une
    /// liste identique, et on ne déclenche alors aucun cycle — enregistrer sans
    /// modification ne doit pas repoller la flotte.
    ///
    /// Cas du tout premier hôte : la boucle a démarré à vide (`start()` a
    /// renvoyé `false`), et c'est `reconfigure` qui rallume la cadence — d'où
    /// « la surveillance démarre sans relancer l'app ». Le cycle immédiat
    /// demandé ici est alors ignoré par la garde de génération, la cadence
    /// venant d'être activée avec son propre cycle initial.
    private func applyConfiguredHosts(_ hosts: [ObservedHost]) {
        guard pollingLoop.reconfigure(hosts: hosts) else { return }
        pollingLoop.requestImmediateCycle()
    }

    deinit {
        pollingLoop.stop()
    }

    private static func log(_ message: String) {
        guard let data = "Monobs: \(message)\n".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

/// CAP-10 — la fenêtre de réglages, en AppKit assumé.
///
/// Monobs est `LSUIElement` : pas de Dock, pas de menu applicatif, donc pas de
/// commande « Réglages… » système sur laquelle s'appuyer. La scène SwiftUI
/// `Settings` dépend précisément de ce menu pour être ouverte ; ici elle serait
/// inatteignable. Une `NSWindow` explicite rend l'ouverture déterministe depuis
/// le popover — le seul endroit d'où l'utilisateur peut cliquer.
private final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?

    init(apply: @escaping ([ObservedHost]) -> Void) {
        model = SettingsModel(apply: apply)
    }

    func present() {
        let window = self.window ?? makeWindow()
        // Relecture du disque à chaque ouverture — mais JAMAIS sur une fenêtre
        // déjà ouverte : ce serait effacer une saisie en cours parce que
        // l'utilisateur a recliqué sur « Réglages ».
        if !window.isVisible { model.reload() }
        // `LSUIElement` : sans activation explicite, la fenêtre s'ouvre derrière
        // l'application au premier plan. `activate()` (macOS 14) remplace
        // `activate(ignoringOtherApps:)`, déprécié depuis ce même plancher.
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Réglages Monobs"
        // La fenêtre survit à sa fermeture : la rouvrir réutilise le même
        // contrôleur (et relit le disque) au lieu de désallouer sous SwiftUI.
        window.isReleasedWhenClosed = false
        // Le thème Braise est sombre : les contrôles natifs (champs de texte)
        // doivent l'être aussi, sinon ils arrivent en clair sur fond prune.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: SettingsContent(model: model,
                                      onClose: { [weak window] in window?.performClose(nil) }))
        window.center()
        self.window = window
        return window
    }
}

@main
struct MonobsApp: App {
    private let runtime: MonobsRuntime
    // Observed so the menu bar icon re-renders when the aggregate changes.
    @StateObject private var model: MenuBarModel

    init() {
        let runtime = MonobsRuntime()
        self.runtime = runtime
        _model = StateObject(wrappedValue: runtime.model)
    }

    var body: some Scene {
        // The menu bar icon reflects the real aggregate state (Story 1.4). Story
        // 3.1 attaches the POPOVER surface as the window-style content: a dense,
        // unlimited (CA-7), AD-17-ordered list of all hosts with a manual refresh
        // (AD-16). Both surfaces project the SAME snapshot (AD-12). Rendering is
        // native and neutral (Q3 gated — no palette, no visual direction).
        // LSUIElement=YES keeps the app out of the Dock.
        MenuBarExtra {
            PopoverContent(model: model,
                           onRefresh: { [runtime] in runtime.requestRefresh() },
                           onOpenSettings: { [runtime] in runtime.openSettings() })
        } label: {
            // Story E1 — teinte d'agrégat (D2). Le glyphe reste INVARIANT (symbole
            // choisi par `MenuBarPresentation`) ; seule la teinte change. Nominal /
            // stale / vide = template neutre (le système gère la couleur de barre,
            // « boring is good »). Incident = teinté rouge — un signal, pas du
            // décor. Aligné à la règle D2 : le rouge, rare, surcrie ; le vert recule.
            Image(systemName: MenuBarPresentation.aggregateSymbol(model.projection.aggregate))
                .foregroundStyle(menuBarTint(for: model.projection.aggregate))
        }
        .menuBarExtraStyle(.window)
    }

    /// Teinte du glyphe de barre selon l'agrégat : rouge pour l'incident, neutre
    /// (template système) sinon. `nil` (aucun hôte) reste neutre.
    private func menuBarTint(for aggregate: HostState?) -> Color {
        if let aggregate, MenuBarPresentation.isIncident(aggregate) {
            return Theme.redText
        }
        return .primary
    }
}
