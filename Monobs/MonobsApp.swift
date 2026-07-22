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

    init() {
        let config = HostConfigLoader.load()
        hosts = config.hosts
        let store = SnapshotStore()
        snapshotStore = store
        let model = self.model
        let hosts = self.hosts
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
                let projection = MenuBarProjector.project(hosts: hosts,
                                                          snapshots: store.allSnapshots(),
                                                          now: Date())
                DispatchQueue.main.async { model.projection = projection }
            }
        )
        config.diagnostics.forEach(Self.log)
        // Initial projection before the first cycle: honest degenerate/stale
        // view (no data yet), never a premature vert.
        model.projection = MenuBarProjector.project(hosts: hosts,
                                                    snapshots: store.allSnapshots(),
                                                    now: Date())
        pollingLoop.start()
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
        // The menu bar now reflects the real aggregate state (Story 1.4). The
        // icon comes from the aggregate; the dropdown lists each host with its
        // derived state and data age (FR5). Rendering is native and neutral
        // (Q3 gated — no palette, no visual direction). LSUIElement=YES keeps
        // the app out of the Dock.
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: MenuBarPresentation.aggregateSymbol(model.projection.aggregate))
        }
    }
}
