//
//  MonobsWidgetView.swift
//  MonobsWidget
//

import Foundation
import WidgetKit
import SwiftUI
import MonobsKit

/// Story 3.2 — the medium widget view. It derives nothing: it projects the
/// container the app wrote and computes the age as a pure projection of the
/// freshness instant against the entry's date.
///
/// Story E1 — the neutral (Q3) rendering is REPLACED by the D2 « Braise »
/// direction. The widget is a SEPARATE target: it CANNOT import the app's
/// `Theme`, so it duplicates the MINIMUM of tokens (`WidgetTheme`) rather than
/// break target isolation (as the story prescribes). Unlike the popover the
/// widget is OPAQUE — WidgetKit does not compose system vibrancy reliably — so it
/// uses the warm `wid-stop-1..3` gradient, no translucency. Only the STYLE
/// changes: the body still consumes `entry.content` verbatim and the FR labels
/// are unchanged.
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
        .widgetWarmBackground()
    }

    @ViewBuilder
    private func snapshotBody(_ snapshot: SharedSnapshot) -> some View {
        let selection = WidgetSelector.select(snapshot.hosts)
        VStack(alignment: .leading, spacing: 2.5) {
            if selection.shown.isEmpty {
                Text("aucun hôte configuré")
                    .font(WidgetTheme.sans(WidgetTheme.fsWHost))
                    .foregroundStyle(WidgetTheme.muted)
            } else {
                ForEach(selection.shown, id: \.hostID) { host in
                    HostRow(host: host, now: entry.date)
                }
                if selection.hasOverflow {
                    Spacer(minLength: 0)
                    Divider().overlay(WidgetTheme.hair)
                    Text(WidgetPresentation.overflowText(selection.overflowCount))
                        .font(WidgetTheme.mono(WidgetTheme.fsWAge))
                        .monospacedDigit()
                        .foregroundStyle(WidgetTheme.muted)
                        .padding(.top, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, WidgetTheme.space8)
        .padding(.vertical, 13)
    }
}

/// One host row: derived-state dot, host ID, distinct per-state label, and the
/// visible data age (FR5) computed against the entry date. D2 « Braise » colors.
private struct HostRow: View {
    let host: SharedHostEntry
    let now: Date

    var body: some View {
        let isStale = host.state == .stale
        let incident = WidgetTheme.isIncident(host.state)
        HStack(spacing: 9) {
            // Pastille : halo (ressource rare) réservé à l'incident.
            Circle()
                .fill(WidgetTheme.dotColor(for: host.state))
                .frame(width: 6, height: 6)
                .shadow(color: incident ? WidgetTheme.red.opacity(0.72) : .clear,
                        radius: incident ? 4 : 0)
            Text(host.hostID)
                .font(WidgetTheme.sans(WidgetTheme.fsWHost, .semibold))
                .foregroundStyle(isStale ? WidgetTheme.muted : WidgetTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(WidgetPresentation.label(for: host.state))
                .font(WidgetTheme.mono(WidgetTheme.fsWMet))
                .monospacedDigit()
                .foregroundStyle(WidgetTheme.textColor(for: host.state))
                .lineLimit(1)
            // Âge : `faint` en nominal, promu `ink2` sur stale. Largeur réservée.
            Text(WidgetPresentation.ageText(WidgetAge.age(freshnessTimestamp: host.freshnessTimestamp, now: now)))
                .font(WidgetTheme.mono(WidgetTheme.fsWAge))
                .monospacedDigit()
                .foregroundStyle(isStale ? WidgetTheme.ink2 : WidgetTheme.faint)
                .lineLimit(1)
                .frame(width: WidgetTheme.ageWWidget, alignment: .trailing)
        }
    }
}

/// Readable degradation view — never a crash (AC5). D2 « Braise » ink scale on
/// the warm opaque background.
private struct DegradedView: View {
    let degradation: MonobsEntry.Degradation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Monobs", systemImage: "circle.dashed")
                .font(WidgetTheme.sans(WidgetTheme.fsWHost, .semibold))
                .foregroundStyle(WidgetTheme.ink)
            Text(message)
                .font(WidgetTheme.mono(WidgetTheme.fsWMet))
                .foregroundStyle(WidgetTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, WidgetTheme.space8)
        .padding(.vertical, 13)
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
    /// Fond OPAQUE chaud du widget (dégradé `wid-stop-1..3`, ~172°). WidgetKit ne
    /// compose pas de vibrancy fiable → jamais translucide. `containerBackground`
    /// est macOS 14+/iOS 17+ ; sur le plancher 13.0 on retombe sur `.background`.
    @ViewBuilder
    func widgetWarmBackground() -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            self.containerBackground(for: .widget) { WidgetTheme.widgetGradient }
        } else {
            self.background(WidgetTheme.widgetGradient)
        }
    }
}

// MARK: - WidgetTheme (duplication minimale des tokens D2 — isolation de cible)

/// Sous-ensemble du thème D2 « Braise » nécessaire au widget. Dupliqué depuis
/// `tokens.css` (et non partagé avec l'app `Theme`) pour préserver l'isolation de
/// la cible WidgetKit. La conversion OKLCH→sRGB est IDENTIQUE à celle de l'app
/// (OKLab → LMS → sRGB linéaire → gamma sRGB), pour une fidélité pixel entre
/// surfaces. PRÉSENTATION uniquement — aucune dérivation d'état.
enum WidgetTheme {

    // MARK: OKLCH → sRGB (identique à `Theme.oklch`)

    static func oklch(_ l: Double, _ c: Double, _ h: Double, _ a: Double = 1) -> Color {
        let hRad = h * .pi / 180.0
        let labA = c * cos(hRad)
        let labB = c * sin(hRad)

        let lPrime = l + 0.3963377774 * labA + 0.2158037573 * labB
        let mPrime = l - 0.1055613458 * labA - 0.0638541728 * labB
        let sPrime = l - 0.0894841775 * labA - 1.2914855480 * labB

        let lCone = lPrime * lPrime * lPrime
        let mCone = mPrime * mPrime * mPrime
        let sCone = sPrime * sPrime * sPrime

        let rLin =  4.0767416621 * lCone - 3.3077115913 * mCone + 0.2309699292 * sCone
        let gLin = -1.2684380046 * lCone + 2.6097574011 * mCone - 0.3413193965 * sCone
        let bLin = -0.0041960863 * lCone - 0.7034186147 * mCone + 1.7076147010 * sCone

        return Color(.sRGB,
                     red: gammaEncodeSRGB(rLin),
                     green: gammaEncodeSRGB(gLin),
                     blue: gammaEncodeSRGB(bLin),
                     opacity: max(0, min(1, a)))
    }

    private static func gammaEncodeSRGB(_ value: Double) -> Double {
        let clamped = max(0, min(1, value))
        let encoded = clamped <= 0.0031308
            ? 12.92 * clamped
            : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        return max(0, min(1, encoded))
    }

    // MARK: Tokens widget

    static let widStop1 = oklch(0.250, 0.034, 36)
    static let widStop2 = oklch(0.278, 0.040, 34)
    static let widStop3 = oklch(0.190, 0.020, 40)

    static let hair = oklch(0.82, 0.02, 50, 0.11)

    static let ink   = oklch(0.96, 0.012, 70)
    static let ink2  = oklch(0.87, 0.020, 60)
    static let muted = oklch(0.785, 0.028, 55)
    static let faint = oklch(0.735, 0.032, 50)

    static let greenDim = oklch(0.66, 0.13, 150)
    static let red      = oklch(0.685, 0.195, 27)
    static let redText  = oklch(0.76, 0.155, 30)
    static let stale    = oklch(0.66, 0.02, 55)

    static let radiusWidget: CGFloat = 22

    // Tailles widget (px @ 1rem = 16px)
    static let fsWHost: CGFloat = 11.5
    static let fsWMet:  CGFloat = 10.5
    static let fsWAge:  CGFloat = 10

    static let space8: CGFloat = 17
    // Largeur réservée de la colonne d'âge. Dimensionnée sur le PIRE cas réel des
    // paliers (« 59min ») en SF Mono 10 pt, pas sur la valeur courte de la
    // maquette : 28 pt suffisaient à « 2h » mais tronquaient les paliers minutes.
    static let ageWWidget: CGFloat = 34

    // MARK: Dégradé opaque du widget (~172°, haut→bas)

    static var widgetGradient: LinearGradient {
        let stops: [Gradient.Stop] = [
            .init(color: widStop1, location: 0.0),
            .init(color: widStop2, location: 0.55),
            .init(color: widStop3, location: 1.0),
        ]
        let rad = 172.0 * .pi / 180.0
        let dx = sin(rad)
        let dy = -cos(rad)
        let start = UnitPoint(x: 0.5 - dx / 2, y: 0.5 - dy / 2)
        let end   = UnitPoint(x: 0.5 + dx / 2, y: 0.5 + dy / 2)
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: start, endPoint: end)
    }

    // MARK: Fabriques de police

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Mapping couleurs d'état (présentation — cf. app `MenuBarPresentation`)

    static func dotColor(for state: HostState) -> Color {
        switch state {
        case .vert: return greenDim
        case .stale: return stale
        case .rougeSeuil, .rougeInjoignable: return red
        }
    }

    static func textColor(for state: HostState) -> Color {
        switch state {
        case .vert, .stale: return muted
        case .rougeSeuil, .rougeInjoignable: return redText
        }
    }

    static func isIncident(_ state: HostState) -> Bool {
        switch state {
        case .rougeSeuil, .rougeInjoignable: return true
        case .vert, .stale: return false
        }
    }
}
