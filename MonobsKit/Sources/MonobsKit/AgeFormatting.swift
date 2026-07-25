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
public enum AgeFormatting {
    /// Formats a NON-NEGATIVE age in seconds into its compact tier. Callers own
    /// the `nil` (never seen) and negative (clock-skew) guards — this helper is
    /// pure tiering for `seconds >= 0`.
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
        if seconds < 60 { return "\(seconds)s" }
        // `+ (unit - 1)` before integer division = ceil, kept in integer
        // arithmetic so the tiers stay exactly reproducible in tests.
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes)min" }
        let hours = (seconds + 3_599) / 3_600
        if hours < 24 { return "\(hours)h" }
        return "\((seconds + 86_399) / 86_400)j"
    }
}
