//
//  MonobsWidgetView.swift
//  MonobsWidget
//

import WidgetKit
import SwiftUI
import MonobsKit

/// Story 3.2 — the medium widget view. NATIVE NEUTRE (Q3 gated): system
/// `Text`/`Label`/SF Symbols and semantic styles only — no brand palette, no
/// sparkline, no translucent shell, no proprietary layout (NFR5). It derives
/// nothing: it projects the container the app wrote and computes the age as a
/// pure projection of the freshness instant against the entry's date.
struct MonobsWidgetView: View {
    let entry: MonobsEntry

    var body: some View {
        Group {
            switch entry.content {
            case .snapshot(let snapshot):
                snapshotBody(snapshot)
            case .degraded(let degradation):
                DegradedView(degradation: degradation)
            }
        }
        .widgetNeutralBackground()
    }

    @ViewBuilder
    private func snapshotBody(_ snapshot: SharedSnapshot) -> some View {
        let selection = WidgetSelector.select(snapshot.hosts)
        VStack(alignment: .leading, spacing: 2) {
            if selection.shown.isEmpty {
                Text("aucun hôte configuré").foregroundStyle(.secondary)
            } else {
                ForEach(selection.shown, id: \.hostID) { host in
                    HostRow(host: host, now: entry.date)
                }
                if selection.hasOverflow {
                    Text(WidgetPresentation.overflowText(selection.overflowCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
    }
}

/// One host row: derived-state symbol, host ID, distinct per-state label, and the
/// visible data age (FR5) computed against the entry date.
private struct HostRow: View {
    let host: SharedHostEntry
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: WidgetPresentation.symbol(for: host.state))
                .imageScale(.small)
            Text(host.hostID)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(WidgetPresentation.label(for: host.state))
                .font(.caption2)
            Text(WidgetPresentation.ageText(WidgetAge.age(freshnessTimestamp: host.freshnessTimestamp, now: now)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

/// Readable degradation view — never a crash (AC5). Neutral system components.
private struct DegradedView: View {
    let degradation: MonobsEntry.Degradation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Monobs", systemImage: "circle.dashed")
                .font(.caption)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
    }

    private var message: String {
        switch degradation {
        case .unavailable:
            return "Données indisponibles — l'app n'a pas encore écrit d'état."
        case .unsupportedVersion(let version):
            return "Version de données non supportée (v\(version)) — mettez à jour l'app."
        }
    }
}

private extension View {
    /// Neutral system background for the widget container. `containerBackground`
    /// is macOS 14+/iOS 17+; on the 13.0 deployment floor it is a no-op. NEVER a
    /// brand palette — `.background` is the system material (Q3 gated).
    @ViewBuilder
    func widgetNeutralBackground() -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            self.containerBackground(.background, for: .widget)
        } else {
            self
        }
    }
}
