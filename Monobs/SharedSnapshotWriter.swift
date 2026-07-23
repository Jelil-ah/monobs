//
//  SharedSnapshotWriter.swift
//  Monobs
//

import Foundation
import MonobsKit
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Story 3.2 — the app-side writer for the shared app↔widget container. The app
/// process is the SOLE writer (AD-12); the WidgetKit extension only ever reads.
///
/// This type is the thin I/O shell around the pure `SharedSnapshotBuilder`
/// (MonobsKit): it builds the versioned container from the ALREADY-derived
/// projection plus the raw snapshots (for the ABSOLUTE freshness instant — never
/// the age duration, so the widget age keeps growing while the app is stopped,
/// AC4), then writes it ATOMICALLY (RISQUE #2 (b): a shared file path, sandbox
/// off B5). A torn read by the extension is impossible because the write is
/// atomic (temp + rename); a single writer plus atomic writes is the only
/// concurrency precaution needed.
enum SharedSnapshotWriter {
    /// Serializes the projection into the shared container. Best-effort: an I/O
    /// failure must never crash or block the poll loop — the widget degrades
    /// gracefully on a missing/stale file (AC5).
    static func write(projection: MenuBarProjection, snapshots: [String: HostSnapshot]) {
        do {
            let container = SharedSnapshotBuilder.build(projection: projection, snapshots: snapshots)
            let data = try SharedSnapshotCodec.encode(container)
            let fileURL = try SharedSnapshotLocation.stateFileURL()
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Atomic: write a temporary then rename — the extension never sees a
            // half-written file.
            try data.write(to: fileURL, options: .atomic)
            #if canImport(WidgetKit)
            // Ask WidgetKit to reload; the timeline cadence (age growth via future
            // entries) is a presentation choice inside the extension.
            WidgetCenter.shared.reloadTimelines(ofKind: SharedSnapshotLocation.widgetKind)
            #endif
        } catch {
            // Swallow — read-only observability must never fail the poll cycle.
        }
    }
}
