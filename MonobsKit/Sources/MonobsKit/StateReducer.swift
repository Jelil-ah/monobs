import Foundation

/// The single reducer (AD-11). One place — and only one — derives a host's
/// state from its snapshot and the global facts. Surfaces consume this output
/// and never re-derive it.
///
/// Codomain (Story 2.2): the reducer applies the full strict FR10 precedence
/// and produces `{.vert, .rougeInjoignable, .stale}`. `.rougeSeuil` is **never**
/// produced here — the "client metric threshold ⇒ rougeSeuil" tier (spine item
/// 4, Q1/Q2) is GATED to Story 2.3; a codomain test enforces its absence across
/// the whole truth table. The reducer stays **pure**: `(snapshot, now,
/// tailscaleLocalUp, threshold) ⇒ state`, with no side effect and no memory —
/// no "previous state" field and no notification (AD-13, Story 2.4).
public enum StateReducer {

    /// Staleness threshold — the single isolated parameter for the freshness
    /// boundary (never a value hard-coded across the reducer; always injectable).
    ///
    /// Provisional default (Q4.1): "3 minutes" read as 180 s wall-clock, a fixed
    /// threshold. Undecided: 3 missed polls vs 180 s; fixed vs proportional if
    /// the polling ever leaves its 60 s cadence — not settled. Only this value
    /// is ratified as the provisional default; no other value is.
    public static let defaultStalenessThreshold: TimeInterval = 180

    /// Pure reduction under the strict FR10 precedence: `HostSnapshot` (Story
    /// 1.3) + injected client clock `now` + the global `tailscaleLocalUp` fact
    /// (Story 2.1) + staleness threshold ⇒ `{.vert, .rougeInjoignable, .stale}`.
    ///
    /// The ORDER of the guards **is** the precedence — do not reorder. Each rule
    /// short-circuits before the next is evaluated (FR10):
    ///
    ///   1. `tailscaleLocalUp == false` overrides EVERYTHING ⇒ `.stale` (FR10.1).
    ///   2. else `sshFailureActive` ⇒ `.rougeInjoignable`, IMMEDIATELY, before
    ///      any age evaluation (FR10.2).
    ///   3. else no/stale valid data ⇒ `.stale` (FR10.3), preserving the
    ///      clock-skew fail-closed guard (Story 1.4 #1).
    ///   4. else fresh ⇒ `.vert`.
    ///
    /// `tailscaleLocalUp` is a **required** parameter — no default. A default
    /// (`= true`) would be a fail-open by omission: a caller that forgot the
    /// fact would silently skip rule 1. Every caller must pass it explicitly.
    ///
    /// `metrics` are opaque and never interpreted (Q1/Q2, Story 2.3): fresh data
    /// with no active failure always yields `.vert` here — the "metric threshold
    /// ⇒ `.rougeSeuil`" tier is GATED to 2.3 and NOT produced by this reducer.
    public static func reduce(_ snapshot: HostSnapshot,
                              now: Date,
                              tailscaleLocalUp: Bool,
                              stalenessThreshold: TimeInterval = defaultStalenessThreshold) -> HostState {
        // FR10.1 — Tailscale-local override: when the local transport is not
        // available, NO host can be guaranteed reachable, so every host is
        // forced `.stale`/grey and EVERY red is suppressed (including a host
        // with an active SSH failure). This is INTENDED (U-3/CA-5: "cannot
        // guarantee reachability ⇒ honest grey silence, zero false red"), but it
        // DEPENDS on the reliability of the Tailscale probe (Q4.3, DEBT G-2.2):
        // a probe that returns `false` in error would MASK a genuinely dead host
        // by suppressing its legitimate `.rougeInjoignable`. The cursor "avoid
        // false reds vs. do not mask real incidents" belongs to the probe
        // mechanism (Q4.3), not to this reducer — the risk is logged, not
        // arbitrated here.
        guard tailscaleLocalUp else { return .stale }
        // FR10.2 — active transport failure ⇒ unreachable, IMMEDIATELY. This
        // returns BEFORE any age computation (including the clock-skew guard
        // below): "immédiat, sans attendre le seuil" (FR6/CA-3). An unreachable
        // host with a drifting clock stays red, not grey. "Maintenu jusqu'au
        // premier poll réussi" is carried by the PERSISTENCE of
        // `sshFailureActive` in the snapshot (Story 1.3) — SnapshotStore.record
        // raises it only on `.transportFailure` and clears it on any successful
        // transport — NOT by any memory in this reducer (which stays pure; no
        // "previous state" field — that is Story 2.4). F2 Option A: a report
        // invalid/absent over a healthy transport leaves `sshFailureActive ==
        // false`, so this rule does not fire and the host follows the staleness
        // path (rule 3), never `.rougeInjoignable` (AD-10, T-CONTRACT).
        if snapshot.sshFailureActive { return .rougeInjoignable }
        // FR10.3 — staleness. Freshness is anchored on the client's reception
        // instant of the last valid report (AD-10). No valid report ever
        // received ⇒ no fresh data.
        guard let receivedAt = snapshot.lastValidReceivedAt else {
            return .stale
        }
        let age = now.timeIntervalSince(receivedAt)
        // Clock skew (fail-closed, provisional — consistent with the Q4.1
        // staleness policy, preserved from Story 1.4 #1): a negative age means
        // the last reception is timestamped in the FUTURE relative to `now`.
        // Since freshness is anchored on the client clock that also stamps `now`
        // (AD-10), this is a wall-clock jump backward (wake from sleep, NTP
        // step, manual correction) — the reception time is not reliably fresh
        // data. We NEVER claim vert on an impossible age: age < 0 ⇒ .stale. This
        // closes the fail-open where a dead host could show vert during the skew
        // window. (An unreachable host at a skewed clock already returned
        // `.rougeInjoignable` at rule 2 above — this guard only governs the
        // no-active-failure branch.)
        guard age >= 0 else { return .stale }
        // Boundary (provisional Q4.1): age ≤ threshold ⇒ vert; age > threshold
        // ⇒ stale. A host is NOT yet stale exactly at the threshold ("stale
        // AFTER 3 minutes", FR5). A truth-table row at age == threshold pins
        // this and fails if `<=` is flipped to `<`.
        if age > stalenessThreshold { return .stale }
        // FR10 tier 4 — fresh data, no active failure, Tailscale up ⇒ vert. The
        // "client metric threshold ⇒ .rougeSeuil" tier (spine item 4) is GATED
        // to Story 2.3 (Q1 metric set, Q2 threshold values): NEVER produced
        // here.
        return .vert
    }
}
