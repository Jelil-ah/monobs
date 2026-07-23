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
    /// Signature of the last STATE actually written (list of `hostID=state`,
    /// sorted by host ID). Used to gate `reloadTimelines` (D-2): the poll loop
    /// writes every cycle, but the WidgetKit reload budget is scarce — spending
    /// it on every write (including pure age drift, which changes on every cycle)
    /// gets the timeline throttled and makes the widget MORE stale, not less.
    /// The age is projected inside the extension from the absolute timestamp we
    /// always persist, so it keeps advancing without a reload; only a real state
    /// change needs to invalidate the timeline. `nil` ⇒ nothing written yet.
    private static var lastStateSignature: String?

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
            // half-written file. The writer stays the source of truth, so we write
            // EVERY cycle (freshness timestamp must be current).
            try data.write(to: fileURL, options: .atomic)
            #if canImport(WidgetKit)
            // Only spend a WidgetKit reload when the projected STATE changed —
            // NOT on age drift (age advances in the extension off the persisted
            // timestamp, so it needs no reload). Sorted by host ID so a pure
            // reordering that leaves every host's state unchanged does not reload.
            let signature = projection.hosts
                .map { "\($0.hostID)=\($0.state)" }
                .sorted()
                .joined(separator: "|")
            if signature != lastStateSignature {
                lastStateSignature = signature
                WidgetCenter.shared.reloadTimelines(ofKind: SharedSnapshotLocation.widgetKind)
            }
            #endif
        } catch {
            // Swallow — read-only observability must never fail the poll cycle.
        }
    }
}
