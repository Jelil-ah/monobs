//
//  MonobsWidgetBundle.swift
//  MonobsWidget
//

import WidgetKit
import SwiftUI
import MonobsKit

/// Story 3.2 — the WidgetKit extension entry point. A separate process (AD-12):
/// it reads the shared container the app writes and PROJECTS it. It never polls,
/// never derives state, never re-ranks (the 6-worst uses the single shared
/// `StateRanking`/`WidgetSelector` from MonobsKit).
@main
struct MonobsWidgetBundle: WidgetBundle {
    var body: some Widget {
        MonobsWidget()
    }
}

/// The medium widget: the 6 worst hosts + explicit overflow + visible data age.
struct MonobsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedSnapshotLocation.widgetKind,
                            provider: MonobsTimelineProvider()) { entry in
            MonobsWidgetView(entry: entry)
        }
        .configurationDisplayName("Monobs")
        .description("Les 6 pires hôtes, débordement explicite et âge de la donnée.")
        .supportedFamilies([.systemMedium])
    }
}

/// One timeline entry. `date` is the instant this entry renders at — the age is
/// computed against it, so future entries show a LARGER age (AC4).
struct MonobsEntry: TimelineEntry {
    let date: Date
    let content: Content

    enum Content {
        /// A decoded, known-version container.
        case snapshot(SharedSnapshot)
        /// A readable degradation — never a crash.
        case degraded(Degradation)
    }

    enum Degradation: Equatable {
        /// File absent / illegible / corrupt (app never launched, or mid-write).
        case unavailable
        /// The container's major version is newer than this build understands.
        case unsupportedVersion(Int)
    }
}

/// Reads the shared container (READ-ONLY) and emits a timeline whose entries
/// carry the SAME snapshot at increasing instants — so the visible age GROWS
/// even while the app is stopped and the file is not refreshed (frozen
/// best-effort, AC4). No network, no derivation.
struct MonobsTimelineProvider: TimelineProvider {
    /// Number of future entries and their spacing — a presentation choice for how
    /// smoothly the age advances between app writes (the app also nudges reloads
    /// via `reloadTimelines`).
    private static let futureEntryCount = 12
    private static let entryInterval: TimeInterval = 60   // seconds

    func placeholder(in context: Context) -> MonobsEntry {
        MonobsEntry(date: Date(), content: .degraded(.unavailable))
    }

    func getSnapshot(in context: Context, completion: @escaping (MonobsEntry) -> Void) {
        completion(currentContentEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MonobsEntry>) -> Void) {
        let now = Date()
        let base = currentContentEntry(at: now)
        // Re-render the SAME content at increasing instants; the age is recomputed
        // per entry against the fixed freshnessTimestamp, so it visibly grows.
        let entries: [MonobsEntry] = (0..<Self.futureEntryCount).map { step in
            let entryDate = now.addingTimeInterval(Double(step) * Self.entryInterval)
            return MonobsEntry(date: entryDate, content: base.content)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func currentContentEntry(at date: Date) -> MonobsEntry {
        switch WidgetSnapshotReader.read() {
        case .ok(let snapshot):
            return MonobsEntry(date: date, content: .snapshot(snapshot))
        case .unsupportedVersion(let version):
            return MonobsEntry(date: date, content: .degraded(.unsupportedVersion(version)))
        case .unreadable:
            return MonobsEntry(date: date, content: .degraded(.unavailable))
        }
    }
}
