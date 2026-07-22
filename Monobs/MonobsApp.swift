//
//  MonobsApp.swift
//  Monobs
//

import Foundation
import SwiftUI
import MonobsKit

private final class MonobsRuntime {
    private let snapshotStore: SnapshotStore
    private let pollingLoop: HostPollingLoop

    init() {
        let config = HostConfigLoader.load()
        snapshotStore = SnapshotStore()
        pollingLoop = HostPollingLoop(
            hosts: config.hosts,
            snapshotStore: snapshotStore,
            pollHost: { host in
                SSHPollRunner.poll(host: host, onDiagnostics: Self.log)
            }
        )
        config.diagnostics.forEach(Self.log)
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
    private let runtime = MonobsRuntime()

    var body: some Scene {
        // The visible surface remains the static Story 1.1 placeholder.
        // LSUIElement=YES in build settings keeps the app out of the Dock.
        MenuBarExtra("Monobs", systemImage: "circle.dashed") {
            Text("Monobs — placeholder")
        }
    }
}
