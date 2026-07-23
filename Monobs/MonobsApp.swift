//
//  MonobsApp.swift
//  Monobs
//

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

private final class MonobsRuntime {
    let model = MenuBarModel()

    private let hosts: [ObservedHost]
    private let snapshotStore: SnapshotStore
    private let pollingLoop: HostPollingLoop
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
        hosts = config.hosts
        let store = SnapshotStore()
        snapshotStore = store
        let model = self.model
        let hosts = self.hosts
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
                let projection = MenuBarProjector.project(hosts: hosts,
                                                          snapshots: store.allSnapshots(),
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
                DispatchQueue.main.async { model.projection = projection }
            }
        )
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
        model.projection = MenuBarProjector.project(hosts: hosts,
                                                    snapshots: store.allSnapshots(),
                                                    now: Date(),
                                                    tailscaleLocalUp: tailscaleFact.current)
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

    deinit {
        pollingLoop.stop()
    }

    private static func log(_ message: String) {
        guard let data = "Monobs: \(message)\n".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
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
            PopoverContent(model: model, onRefresh: { [runtime] in runtime.requestRefresh() })
        } label: {
            Image(systemName: MenuBarPresentation.aggregateSymbol(model.projection.aggregate))
        }
        .menuBarExtraStyle(.window)
    }
}
