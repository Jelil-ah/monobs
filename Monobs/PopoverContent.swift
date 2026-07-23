//
//  PopoverContent.swift
//  Monobs
//

import SwiftUI
import MonobsKit

/// Story 3.1 — the popover surface (Epic 3, T-SURFACES). A thin SwiftUI view
/// (AD-11): it CONSUMES `model.projection` and renders it — it derives nothing.
/// The rows arrive already ordered worst-state-first by the single shared ranking
/// module (AD-17, applied in `MenuBarProjector`); the view never re-ranks and
/// never re-derives state or age. It projects the SAME snapshot as the menu bar
/// icon (AD-12), so the two surfaces can never diverge.
///
/// Contents per row: derived state symbol, host ID, distinct per-state label
/// (`MenuBarPresentation.label`), and data age (FR5). Detail is INLINE ONLY — no
/// navigation, no server action. The list is UNLIMITED (CA-7): every configured
/// host is shown, scrolled rather than truncated (overflow/limit is the widget,
/// Story 3.2).
///
/// Rendering is NATIVE NEUTRE (Q3 gated): system `List`/`Label`/`Text`/`Button`
/// and semantic styles only — no brand palette, no sparkline, no translucent
/// shell, no proprietary layout (NFR5).
struct PopoverContent: View {
    @ObservedObject var model: MenuBarModel
    /// AD-16 manual refresh. The view only REQUESTS a refresh — it does not
    /// orchestrate cycles; the serialization onto the poll-queue lives in
    /// `HostPollingLoop.requestImmediateCycle()` (D-1 closed there, not here).
    let onRefresh: () -> Void

    var body: some View {
        let projection = model.projection
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Monobs — \(MenuBarPresentation.aggregateLabel(projection.aggregate))")
                    .font(.headline)
                Spacer()
                Button(action: onRefresh) {
                    Label("Rafraîchir", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Rafraîchir maintenant")
            }
            Divider()
            if projection.hosts.isEmpty {
                Text("aucun hôte configuré").foregroundStyle(.secondary)
            } else {
                // Sans limite (CA-7): tous les hôtes, déjà triés AD-17 par le
                // projecteur. `List` scrolle pour N grand — jamais de troncature.
                List(projection.hosts, id: \.hostID) { host in
                    HStack(spacing: 8) {
                        Image(systemName: MenuBarPresentation.symbol(for: host.state))
                        Text(host.hostID)
                        Spacer(minLength: 12)
                        Text(MenuBarPresentation.label(for: host.state))
                        Text(MenuBarPresentation.ageText(host.age)).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120)
            }
            Divider()
            Text("Cadence \(Int(HostPollingLoop.defaultCadence)) s")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(minWidth: 300, alignment: .leading)
    }
}
