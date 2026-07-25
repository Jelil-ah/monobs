import Foundation

/// The single source of truth for age tier formatting (PRESENTATION only — a
/// display-string projection, no business logic / threshold / ranking). Both the
/// widget (`WidgetPresentation.ageText`) and the app menu bar / popover
/// (`MenuBarPresentation.ageText`) delegate here so the tiers stay identical
/// across surfaces (popover ↔ widget alignment).
///
/// Lives in its OWN file rather than in `WidgetProjection.swift`: it is a
/// cross-surface helper, not widget-specific — the filename must not claim a
/// scope narrower than the type's.
///
/// Manual, deterministic tiers (s → min → h → j): surfaces showing the WORST
/// hosts render large ages as the norm, so raw seconds ("340s") both overflow
/// the fixed age column and violate the legible-age requirement (D-3). Not
/// `RelativeDateTimeFormatter` — that is locale-dependent and non-deterministic,
/// which would break the unit tests.
///
/// DOMAINE ACCEPTÉ — `0 ... Int.max`. Un âge est une durée écoulée : il n'existe
/// pas d'âge négatif. L'invariant est défendu ICI, à la frontière de l'API, et
/// pas seulement chez les appelants : une API publique qui rend "-1s" pour
/// `tiered(-1)` est mal-employable — chaque nouvel appelant devrait redupliquer
/// le garde, et un seul oubli produit un affichage absurde sur un moniteur.
/// Même classe de défaut que celui corrigé côté serveur en 2.3 (« reject
/// out-of-domain negative metrics »). Deux points d'entrée, un seul comportement :
///   • `tiered(_:)` — total, pratique : hors domaine ⇒ le marqueur neutre
///     `AgeFormatting.unavailable` ("—"), jamais une chaîne d'âge trompeuse ;
///   • `tieredIfInDomain(_:)` — rend l'invalidité REPRÉSENTABLE (`nil`) pour les
///     appelants qui veulent décider eux-mêmes du repli.
public enum AgeFormatting {
    /// Le marqueur neutre rendu pour une entrée hors domaine. Volontairement le
    /// même tiret cadratin que le popover affiche déjà sur horloge décalée
    /// (`MenuBarPresentation.ageText`, garde `age >= 0`) : le vocabulaire visuel
    /// de « âge non représentable » reste unique sur toutes les surfaces.
    /// Ce n'est PAS "jamais" — "jamais" veut dire « aucune donnée reçue » (âge
    /// absent), alors qu'ici on a une valeur, elle est simplement invalide.
    public static let unavailable = "—"

    /// Formats an age in seconds into its compact tier. TOTAL — always returns a
    /// string, so the two existing adapters keep a `String` result unchanged.
    ///
    /// Hors domaine (`seconds < 0`, horloge décalée / soustraction inversée) ⇒
    /// `unavailable` ("—"). JAMAIS "-1s" : sur un moniteur une chaîne d'âge
    /// négative n'est pas seulement laide, elle est trompeuse (elle se lit comme
    /// un âge). Les appelants qui gardent déjà en amont (le popover renvoie "—"
    /// avant d'arriver ici) ne changent pas de comportement ; ceux qui ne
    /// gardent pas sont désormais protégés par défaut.
    ///
    /// Callers narrowing a `TimeInterval` down to this `Int` MUST round up too
    /// (`age.rounded(.up)`): real ages are fractional, and a nearest-rounding at
    /// the boundary would cancel the ceil below before it ever runs (60.1 s → 60
    /// → "1min"). Both adapters — `WidgetPresentation.ageText` and
    /// `MenuBarPresentation.ageText` — do exactly that, so the guarantee is
    /// end to end.
    ///
    /// Each tier rounds UP (ceil) rather than truncating or rounding to nearest.
    /// On a monitor there is only ONE safe direction of error: an age may be
    /// announced as older than it is, NEVER as fresher. Truncation errs the
    /// dangerous way (340 s → "5min" when it is nearly 6), and so does
    /// round-to-nearest below the half-unit (80 s → "1min" when 1 min 20 has
    /// already elapsed; 3700 s → "1h" when the hour is past). Ceil closes both:
    /// one second past a boundary already displays the next unit
    /// (61 s → "2min", 3601 s → "2h", 86401 s → "2j"), so what the user reads is
    /// always an UPPER bound on freshness.
    ///
    /// Ceil can push a value onto the NEXT tier's boundary (3541 s = 59.02 min
    /// → 60 min; 82801 s = 23.0003 h → 24 h). Rather than render "60min" /
    /// "24h", the tier is promoted: each branch re-derives its unit from
    /// `seconds` directly, so a value that saturates one tier simply falls
    /// through to the next ("1h" / "1j"). Seconds below one minute are EXACT —
    /// nothing to round ("0s", "4s", "59s").
    public static func tiered(_ seconds: Int) -> String {
        tieredIfInDomain(seconds) ?? unavailable
    }

    /// La variante qui rend l'invalidité REPRÉSENTABLE : `nil` ⇔ hors domaine
    /// (`seconds < 0`). Pour les appelants qui veulent leur propre repli plutôt
    /// que le marqueur neutre — le type dit alors ce que la doc dit, et le
    /// compilateur force à traiter le cas.
    ///
    /// Pour `seconds >= 0` le résultat est EXACTEMENT celui de `tiered(_:)` :
    /// mêmes paliers, même ceil, même promotion (I7).
    public static func tieredIfInDomain(_ seconds: Int) -> String? {
        // Garde de domaine AVANT toute arithmétique. Testé par `< 0` et non par
        // une négation : `-Int.min` piégerait (Int.min n'a pas d'opposé).
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = ceilDivide(seconds, by: 60)
        if minutes < 60 { return "\(minutes)min" }
        let hours = ceilDivide(seconds, by: 3_600)
        if hours < 24 { return "\(hours)h" }
        return "\(ceilDivide(seconds, by: 86_400))j"
    }

    /// Ceil d'une division entière, en arithmétique entière (les paliers restent
    /// exactement reproductibles en test — aucun flottant).
    ///
    /// Écrit `value / unit (+1 si reste)` et NON l'idiome `(value + unit - 1) / unit` :
    /// ce dernier piège en overflow près de `Int.max` (`Int.max + 59` déborde, et
    /// un débordement signé fait CRASHER le process en Swift — un moniteur ne
    /// crashe pas sur un horodatage aberrant). Cette forme-ci ne déborde jamais
    /// pour `value >= 0` : le quotient est majoré par `value / 1`, et le `+1` ne
    /// peut pas franchir `Int.max` puisqu'un reste non nul implique
    /// `quotient < value`. Le domaine accepté est donc `0 ... Int.max` en entier,
    /// sans plafond arbitraire à documenter.
    private static func ceilDivide(_ value: Int, by unit: Int) -> Int {
        let quotient = value / unit
        return value % unit == 0 ? quotient : quotient + 1
    }
}
