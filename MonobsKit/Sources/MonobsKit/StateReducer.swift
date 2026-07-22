import Foundation

/// The single skeleton reducer (AD-11). One place — and only one — derives a
/// host's state from its snapshot. Surfaces consume this output and never
/// re-derive it.
///
/// Skeleton codomain (Story 1.4): the reducer returns **only** `.vert` or
/// `.stale`. It never produces a red state — a codomain test enforces this
/// across the whole truth table.
public enum StateReducer {

    /// Staleness threshold — the single isolated parameter for the freshness
    /// boundary (never a value hard-coded across the reducer; always injectable).
    ///
    /// Provisional default (Q4.1): "3 minutes" read as 180 s wall-clock, a fixed
    /// threshold. Undecided: 3 missed polls vs 180 s; fixed vs proportional if
    /// the polling ever leaves its 60 s cadence — not settled. Only this value
    /// is ratified as the provisional default; no other value is.
    public static let defaultStalenessThreshold: TimeInterval = 180

    /// Pure skeleton reduction: `HostSnapshot` (Story 1.3) + injected client
    /// clock `now` + staleness threshold ⇒ `.vert` / `.stale`, nothing else.
    ///
    /// `sshFailureActive` is **deliberately not consumed** here — this is the
    /// seam for story 2.2. In the skeleton only `{vert, stale}` are derived, so
    /// a host with fresh data stays `.vert` even when `sshFailureActive == true`.
    /// Story 2.2 wires the full precedence (active failure ⇒ `rougeInjoignable`,
    /// overriding freshness). `metrics` are opaque and never interpreted (Q1/Q2,
    /// story 2.3).
    public static func reduce(_ snapshot: HostSnapshot,
                              now: Date,
                              stalenessThreshold: TimeInterval = defaultStalenessThreshold) -> HostState {
        // Freshness is anchored on the client's reception instant of the last
        // valid report (AD-10). No valid report ever received ⇒ no fresh data.
        guard let receivedAt = snapshot.lastValidReceivedAt else {
            return .stale
        }
        let age = now.timeIntervalSince(receivedAt)
        // Clock skew (fail-closed, provisional — consistent with the Q4.1
        // staleness policy): a negative age means the last reception is
        // timestamped in the FUTURE relative to `now`. Since freshness is
        // anchored on the client clock that also stamps `now` (AD-10), this is
        // a wall-clock jump backward (wake from sleep, NTP step, manual
        // correction) — the reception time is not reliably fresh data. We
        // NEVER claim vert on an impossible age: age < 0 ⇒ .stale. This closes
        // the fail-open where a dead host could show vert during the skew
        // window.
        guard age >= 0 else { return .stale }
        // Boundary (provisional Q4.1): age ≤ threshold ⇒ vert; age > threshold
        // ⇒ stale. A host is NOT yet stale exactly at the threshold ("stale
        // AFTER 3 minutes", FR5). A truth-table row at age == threshold pins
        // this and fails if `<=` is flipped to `<`.
        return age <= stalenessThreshold ? .vert : .stale
    }
}
