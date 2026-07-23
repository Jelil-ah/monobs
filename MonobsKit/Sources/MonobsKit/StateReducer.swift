import Foundation

/// The single reducer (AD-11). One place — and only one — derives a host's
/// state from its snapshot and the global facts. Surfaces consume this output
/// and never re-derive it.
///
/// Codomain (Story 2.3): the reducer applies the full strict FR10 precedence
/// and produces the **complete closed enum** `{.vert, .rougeSeuil,
/// .rougeInjoignable, .stale}`. `.rougeSeuil` is the tier-4 outcome (spine item
/// 4, Q1/Q2, ratified 2026-07-23): fresh data with no active failure that
/// breaches at least one client-side threshold. The reducer stays **pure**:
/// `(snapshot, now, tailscaleLocalUp, stalenessThreshold, thresholds) ⇒ state`,
/// with no side effect and no memory — no "previous state" field and no
/// notification (AD-13, Story 2.4). Thresholds are injected named constants
/// (`SeuilConfig`), never literals — the reducer reads facts and constants only.
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
    /// (Story 2.1) + staleness threshold + injected `thresholds` ⇒ `{.vert,
    /// .rougeSeuil, .rougeInjoignable, .stale}`.
    ///
    /// The ORDER of the guards **is** the precedence — do not reorder. Each rule
    /// short-circuits before the next is evaluated (FR10):
    ///
    ///   1. `tailscaleLocalUp == false` overrides EVERYTHING ⇒ `.stale` (FR10.1).
    ///   2. else `sshFailureActive` ⇒ `.rougeInjoignable`, IMMEDIATELY, before
    ///      any age evaluation (FR10.2).
    ///   3. else no/stale valid data ⇒ `.stale` (FR10.3), preserving the
    ///      clock-skew fail-closed guard (Story 1.4 #1).
    ///   4. else fresh: at least one client-computed threshold breached ⇒
    ///      `.rougeSeuil` (Story 2.3, Q2); otherwise `.vert`.
    ///
    /// `.rougeSeuil` sits UNDER `.rougeInjoignable` by construction: it is only
    /// reachable at tier 4, i.e. AFTER the Tailscale override, the active-failure
    /// short-circuit and the staleness path (AD-17: injoignable > seuil > stale >
    /// vert). An unreachable host, or one masked by Tailscale-down, never reaches
    /// the threshold evaluation.
    ///
    /// `tailscaleLocalUp` is a **required** parameter — no default. A default
    /// (`= true`) would be a fail-open by omission: a caller that forgot the
    /// fact would silently skip rule 1. Every caller must pass it explicitly.
    /// `thresholds` defaults to `.defaults`, so callers from Stories 2.2/2.4/3.1/
    /// 3.2 are unchanged (Q2 forbids an override system; the parameter is only a
    /// named injectable seam).
    public static func reduce(_ snapshot: HostSnapshot,
                              now: Date,
                              tailscaleLocalUp: Bool,
                              stalenessThreshold: TimeInterval = defaultStalenessThreshold,
                              thresholds: SeuilConfig = .defaults) -> HostState {
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
        // FR10 tier 4 (Story 2.3) — fresh data, no active failure, Tailscale up.
        // The client computes each ratio from the raw facts (AD-8) and compares
        // it to the injected named thresholds. Any single breach ⇒ .rougeSeuil;
        // otherwise .vert. Missing/non-numeric facts or a zero denominator make a
        // criterion NON-firing (graceful degradation) — never a false red.
        if breachesAnyThreshold(snapshot.lastValidFacts?.metrics, thresholds) {
            return .rougeSeuil
        }
        return .vert
    }

    /// Pure tier-4 predicate: does any client-computed ratio breach its named
    /// threshold? OR of three independent criteria. Graceful degradation is the
    /// invariant (AD-10): a criterion fires ONLY when BOTH of its facts are
    /// present AND numeric AND its denominator is > 0 AND the numerator is inside
    /// its physical domain — otherwise it is silently skipped (returns no breach),
    /// so an old report that omits the new keys, a non-numeric value, a zero
    /// denominator, or an out-of-domain value (e.g. a negative `avail`, which is a
    /// valid JSON number yet physically impossible) can NEVER produce a false
    /// `.rougeSeuil`. Without the domain guard a negative `avail` would sail
    /// through `numericFact` and manufacture a false red: disk `1 − (−1000/1000)
    /// = 2.0 ≥ 0.90`, RAM `−0.05 ≤ 0.10`. `nil` metrics (never a valid report)
    /// short-circuit to no breach — though a snapshot in that state never reaches
    /// tier 4 anyway.
    ///
    /// Severity within a breach (disk ≈ RAM outrank load) is documented (Q2) for
    /// a future sub-cause label but NOT materialized: this returns a plain Bool
    /// and the reducer yields the bare `.rougeSeuil` case.
    private static func breachesAnyThreshold(_ metrics: [String: JSONValue]?,
                                             _ thresholds: SeuilConfig) -> Bool {
        guard let metrics else { return false }

        // Disk `/`: 1 − avail/total ≥ diskUsedFraction (used ≥ 90 % by default).
        // Domain: 0 ≤ avail ≤ total (an available space that is negative or
        // exceeds the total is impossible ⇒ skip, never a false red).
        if let total = numericFact(metrics, "disk_total_kib"),
           let avail = numericFact(metrics, "disk_avail_kib"),
           total > 0,
           avail >= 0, avail <= total,
           1 - avail / total >= thresholds.diskUsedFraction {
            return true
        }
        // RAM: avail/total ≤ 1 − ramUsedFraction (used ≥ 90 % by default).
        // Domain: avail ≥ 0 (a negative available would make the ratio negative
        // and cross the `≤` threshold ⇒ false red; an avail > total only lifts the
        // ratio above 1 and never breaches, so the lower bound is the fix).
        if let total = numericFact(metrics, "mem_total_kib"),
           let avail = numericFact(metrics, "mem_available_kib"),
           total > 0,
           avail >= 0,
           avail / total <= 1 - thresholds.ramUsedFraction {
            return true
        }
        // Normalized load: loadavg_1m/nproc ≥ loadPerCPU (≥ 2.0 by default).
        // Domain: load ≥ 0 (a negative load can never breach the `≥` threshold, so
        // this only rejects impossible input for coherence — no behavior change).
        if let load = numericFact(metrics, "loadavg_1m"),
           let nproc = numericFact(metrics, "nproc"),
           nproc > 0,
           load >= 0,
           load / nproc >= thresholds.loadPerCPU {
            return true
        }
        return false
    }

    /// A metric fact usable in a ratio: present AND a JSON number. A missing key,
    /// or a value of any other JSON type, yields `nil` (the criterion is skipped
    /// — graceful degradation, never a false red).
    private static func numericFact(_ metrics: [String: JSONValue], _ key: String) -> Double? {
        if case .number(let value)? = metrics[key] { return value }
        return nil
    }
}
