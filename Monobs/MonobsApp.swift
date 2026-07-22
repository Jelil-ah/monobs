//
//  MonobsApp.swift
//  Monobs
//

import SwiftUI

@main
struct MonobsApp: App {
    var body: some Scene {
        // Story 1.1: static placeholder only — no state, no popover, no widget.
        // LSUIElement=YES in build settings keeps the app out of the Dock.
        MenuBarExtra("Monobs", systemImage: "circle.dashed") {
            Text("Monobs — placeholder")
        }
    }
}
