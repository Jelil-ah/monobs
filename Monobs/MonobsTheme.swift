//
//  MonobsTheme.swift
//  Monobs
//
//  Story E1 — portage du système de design D2 « Braise » (autorité :
//  forge/monobs/craft-d2/tokens.css). PRÉSENTATION uniquement : ce fichier ne
//  contient aucune logique métier, aucune dérivation d'état. Il traduit les
//  tokens OKLCH (nommés par RÔLE dans tokens.css) en `Color` SwiftUI natifs via
//  une conversion OKLCH→sRGB CORRECTE (OKLab → LMS → sRGB linéaire → gamma sRGB),
//  et expose les rayons, espacements, tailles de police et géométries.
//
//  Les chiffres/métriques sont TOUJOURS rendus en mono tabular (SF Mono natif,
//  JetBrains Mono n'étant pas garanti installé — cf. tokens.css). Le glow est une
//  ressource RARE réservée à l'incident : aucun halo always-on ici, seulement des
//  couleurs et des primitives ; la décision « qui glowe » vit dans les vues.

import Foundation
import SwiftUI

/// Le système de thème D2 « Braise », partagé par les surfaces de l'app (popover,
/// menu bar). Le widget (cible séparée) duplique le minimum de tokens plutôt que
/// de casser l'isolation des cibles — cf. `MonobsWidgetView.swift`.
enum Theme {

    // MARK: - Conversion OKLCH → sRGB (le cœur)

    /// Convertit une couleur OKLCH en `Color` SwiftUI dans l'espace sRGB.
    ///
    /// Pipeline fidèle (Björn Ottosson) : OKLCH → OKLab → LMS' (non-linéaire) →
    /// LMS (cube) → sRGB linéaire (matrice) → courbe gamma sRGB. Les composantes
    /// sont clampées dans [0,1] (gamut clip simple) avant et après la gamma.
    ///
    /// - Parameters:
    ///   - l: lightness perceptuelle ∈ [0,1].
    ///   - c: chroma (rayon dans le plan a/b).
    ///   - h: teinte en **degrés**.
    ///   - a: alpha ∈ [0,1] (défaut 1).
    static func oklch(_ l: Double, _ c: Double, _ h: Double, _ a: Double = 1) -> Color {
        let hRad = h * .pi / 180.0
        let labA = c * cos(hRad)
        let labB = c * sin(hRad)

        // OKLab → LMS' (non-linéaire)
        let lPrime = l + 0.3963377774 * labA + 0.2158037573 * labB
        let mPrime = l - 0.1055613458 * labA - 0.0638541728 * labB
        let sPrime = l - 0.0894841775 * labA - 1.2914855480 * labB

        // LMS' → LMS (cube)
        let lCone = lPrime * lPrime * lPrime
        let mCone = mPrime * mPrime * mPrime
        let sCone = sPrime * sPrime * sPrime

        // LMS → sRGB linéaire
        let rLin =  4.0767416621 * lCone - 3.3077115913 * mCone + 0.2309699292 * sCone
        let gLin = -1.2684380046 * lCone + 2.6097574011 * mCone - 0.3413193965 * sCone
        let bLin = -0.0041960863 * lCone - 0.7034186147 * mCone + 1.7076147010 * sCone

        return Color(.sRGB,
                     red: Theme.gammaEncodeSRGB(rLin),
                     green: Theme.gammaEncodeSRGB(gLin),
                     blue: Theme.gammaEncodeSRGB(bLin),
                     opacity: max(0, min(1, a)))
    }

    /// Composante sRGB linéaire → sRGB gamma-encodé, clampée dans [0,1].
    private static func gammaEncodeSRGB(_ value: Double) -> Double {
        let clamped = max(0, min(1, value))
        let encoded = clamped <= 0.0031308
            ? 12.92 * clamped
            : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        return max(0, min(1, encoded))
    }

    // MARK: - Surfaces bureau (fond de scène)

    static let surfacePageA = oklch(0.20, 0.018, 45)
    static let surfacePageB = oklch(0.17, 0.015, 285)
    static let surfacePageC = oklch(0.14, 0.012, 275)

    // MARK: - Popover (4 stops translucides, verre chaud)

    static let popStop1 = oklch(0.270, 0.042, 34, 0.50)
    static let popStop2 = oklch(0.235, 0.032, 33, 0.50)
    static let popStop3 = oklch(0.198, 0.022, 34, 0.52)
    static let popStop4 = oklch(0.165, 0.014, 40, 0.56)

    // MARK: - Widget (opaque — WidgetKit ne compose pas de vibrancy fiable)

    static let widStop1 = oklch(0.250, 0.034, 36)
    static let widStop2 = oklch(0.278, 0.040, 34)
    static let widStop3 = oklch(0.190, 0.020, 40)

    // MARK: - Menu bar & zones internes

    static let menubarBackground = oklch(0.18, 0.013, 40, 0.44)
    static let surfaceDetail     = oklch(0.13, 0.014, 38, 0.26)
    static let surfaceFooter     = oklch(0.14, 0.014, 40, 0.22)
    static let surfaceSelected   = oklch(0.50, 0.090, 32, 0.12)
    static let menubarAlertBackground = oklch(0.42, 0.11, 32, 0.85)

    // MARK: - Hairlines / bordures

    static let hair        = oklch(0.82, 0.02, 50, 0.11)
    static let hair2       = oklch(0.82, 0.02, 50, 0.18)
    static let borderGlass = oklch(0.95, 0.03, 60, 0.24)

    // Fond/bord du contrôle « Rafraîchir » (cf. `.refresh` dans index.html).
    static let controlFill   = oklch(0.9, 0.03, 60, 0.08)
    static let controlBorder = oklch(0.9, 0.03, 60, 0.16)

    // MARK: - Échelle d'encre (texte, ≥4.5:1 sur tout le dégradé)

    static let ink   = oklch(0.96, 0.012, 70)
    static let ink2  = oklch(0.87, 0.020, 60)
    static let muted = oklch(0.785, 0.028, 55)
    static let faint = oklch(0.735, 0.032, 50)

    // MARK: - Couleurs d'ÉTAT (jamais du décor)

    static let green     = oklch(0.80, 0.17, 150)   // objet graphique (pastille / sparkline)
    static let greenDim  = oklch(0.66, 0.13, 150)   // pastille nominale mate
    static let greenText = oklch(0.84, 0.15, 150)   // texte vert (≥4.5:1)

    static let red     = oklch(0.685, 0.195, 27)    // pastille + halo incident
    static let redMark = oklch(0.72, 0.16, 30)      // sparkline rouge-seuil
    static let redText = oklch(0.76, 0.155, 30)     // texte d'état incident (≥4.5:1)

    static let stale     = oklch(0.66, 0.02, 55)    // pastille stale (plate)
    static var staleText: Color { muted }           // hostname/métrique stale atténués

    /// Anneau de focus clavier : token NEUTRE, aligné à l'échelle d'encre, JAMAIS
    /// une couleur d'état (une row incident au focus ne doit pas être encadrée de
    /// vert ni de rouge).
    static let focusRing = oklch(0.93, 0.02, 60, 0.92)

    // MARK: - Ombres

    /// Teinte de l'ombre portée principale du popover/widget
    /// (`--shadow-popover` : `oklch(0.05 0.02 30 / 0.75)`).
    static let shadowColor = oklch(0.05, 0.02, 30, 0.75)

    // MARK: - Dégradés

    /// Convertit un angle de dégradé CSS (0° = vers le haut, sens horaire) en
    /// couple `UnitPoint` start/end SwiftUI (y vers le bas).
    static func gradientPoints(angleDegrees: Double) -> (start: UnitPoint, end: UnitPoint) {
        let rad = angleDegrees * .pi / 180.0
        let dx = sin(rad)
        let dy = -cos(rad)
        let start = UnitPoint(x: 0.5 - dx / 2, y: 0.5 - dy / 2)
        let end   = UnitPoint(x: 0.5 + dx / 2, y: 0.5 + dy / 2)
        return (start, end)
    }

    /// Dégradé verre chaud du popover — 4 stops, ~178° (quasi vertical, haut→bas).
    static var popoverGradient: LinearGradient {
        let stops: [Gradient.Stop] = [
            .init(color: popStop1, location: 0.0),
            .init(color: popStop2, location: 0.42),
            .init(color: popStop3, location: 0.66),
            .init(color: popStop4, location: 1.0),
        ]
        let p = gradientPoints(angleDegrees: 178)
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: p.start, endPoint: p.end)
    }

    // MARK: - Rayons

    static let radiusPopover: CGFloat = 15
    static let radiusWidget:  CGFloat = 22
    static let radiusControl: CGFloat = 8
    static let radiusIcon:    CGFloat = 5

    // MARK: - Espacement (base 4px, cadence de la planche)

    static let space1: CGFloat = 2
    static let space2: CGFloat = 4
    static let space3: CGFloat = 6
    static let space4: CGFloat = 9    // padding vertical de row
    static let space5: CGFloat = 11
    static let space6: CGFloat = 13
    static let space7: CGFloat = 16   // gouttière horizontale popover
    static let space8: CGFloat = 17   // gouttière widget

    // MARK: - Tailles de police (px @ 1rem = 16px)

    static let fsH1:     CGFloat = 16     // titre header
    static let fsHost:   CGFloat = 13.5   // hostname popover
    static let fsBody:   CGFloat = 12     // détail inline / refresh
    static let fsMetric: CGFloat = 11.5   // métrique mono
    static let fsMeta:   CGFloat = 11     // comptes, âge

    // MARK: - Géométries fixes (product register)

    static let popoverW:    CGFloat = 392
    static let popoverWMin: CGFloat = 360
    static let popoverHMax: CGFloat = 600
    static let ageW:        CGFloat = 52   // largeur réservée âge popover — tient les paliers s/min/h/j (pire cas « 59 min » / « 23 h ») sur une ligne

    // MARK: - Fabriques de police

    /// Police sans-serif système (SF Pro) — titres, hostnames, labels.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Police mono (SF Mono natif) — chiffres/métriques/âge. Toujours associer
    /// `.monospacedDigit()` côté vue pour des colonnes tabular alignées.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
