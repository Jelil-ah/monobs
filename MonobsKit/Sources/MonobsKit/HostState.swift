import Foundation

/// The closed vocabulary of canonical host states (Story 1.4, Task 1).
///
/// Exactly four identifiers, no "orange" — the spine convention of stable
/// canonical identifiers across code, tests and fixtures. Declaring all four
/// cases is **not** the same as producing them: the skeleton reducer's codomain
/// is bounded to `{.vert, .stale}` (proven by a codomain test), while the two
/// red cases exist so the AD-17 ranking module can encode its *complete* total
/// order now — stories 2.2 (`rougeInjoignable`) and 2.3 (`rougeSeuil`) will fill
/// them in without touching this enum or the ranking order.
public enum HostState: Equatable, Sendable, CaseIterable {
    /// Fresh data within the staleness threshold.
    case vert
    /// Reserved for story 2.3 (metric threshold breach). Never produced by the
    /// skeleton reducer.
    case rougeSeuil
    /// Reserved for story 2.2 (active transport failure ⇒ unreachable). Never
    /// produced by the skeleton reducer.
    case rougeInjoignable
    /// No fresh data (age beyond the threshold, or no valid report ever received).
    case stale
}
