import Foundation

/// Story 2.4: the rising-edge notification layer, built ON TOP of the pure
/// reducer (AD-13) — it never makes `StateReducer.reduce` impure. It splits the
/// pure DECISION (`(previous, current) ⇒ notify?`, no I/O, exhaustively tested)
/// from the injected EFFECT (the emitter seam). The real `UserNotifications`
/// implementation of that seam lives app-side in `Monobs/`, never here.
///
/// The "reducer emits" of AD-13 = THIS derivation layer (the coordinator), not
/// the pure `reduce` function (left untouched, absent from the 2.4 diff). The
/// coordinator consumes the states already derived by the single reducer (via
/// `projection.hosts`, AD-11) — it re-derives nothing.

/// The injected emission effect (AD-13). Same seam pattern as `pollHost:` /
/// `probe:` / `now:` (Stories 1.3–2.1): a `@Sendable` closure, **injected** (never
/// instantiated in `MonobsKit`), **fire-and-forget** and **non-throwing** — the
/// decision and the write-back NEVER depend on its success (graceful degradation
/// if notification permission is denied). Tests inject a spy that COUNTS; the
/// real `UNUserNotificationCenter` implementation lives app-side.
public typealias RisingEdgeEmitter = @Sendable (String, HostState) -> Void

/// The pure rising-edge decision (Story 2.4, Task 1) — no state, no I/O, no
/// permission, no dependency. Fully testable via `swift test` everywhere Swift
/// exists.
public enum RisingEdge {
    /// Is `state` a red state? Exhaustive `switch` (NOT a `Set` + `default`) so a
    /// future 5th `HostState` forces a compiler decision — fail-closed, closing
    /// piège (a) of the story. "rouge" = `{.rougeInjoignable, .rougeSeuil}` is
    /// treated GENERICALLY so Story 2.3 (which will make the reducer PRODUCE
    /// `rougeSeuil`) rewires nothing: `rougeSeuil` counts as red here even though
    /// 2.4's reducer never produces it.
    public static func isRed(_ state: HostState) -> Bool {
        switch state {
        case .rougeInjoignable, .rougeSeuil: return true
        case .vert, .stale: return false
        }
    }

    /// Emit a notification SSI `previous ∈ non-rouge ∧ current ∈ rouge`.
    /// `previous == nil` (cold start / host never seen) ⇒ NEVER emit: the very
    /// first cycle is a silent baseline (AD-13), even if the host is already red.
    /// A red→red change of label (`rougeInjoignable ↔ rougeSeuil`) ⇒ zero, since
    /// `!isRed(previous)` is false when the previous state was already red.
    public static func shouldNotify(previous: HostState?, current: HostState) -> Bool {
        guard let previous else { return false }
        return isRed(current) && !isRed(previous)
    }

    /// The pure, deterministic cycle step: given the previous and current
    /// per-host states, return the (sorted) host IDs to notify and the NEW
    /// previous map. `next == current` UNCONDITIONALLY — the write-back is
    /// `previous := current` for every host present this cycle; hosts absent from
    /// `current` are dropped; hosts new this cycle (previous nil) are silent.
    /// Sorting makes the emission order deterministic (testable, no I/O).
    public static func step(previous: [String: HostState],
                            current: [String: HostState]) -> (emit: [String], next: [String: HostState]) {
        var emit: [String] = []
        for (id, state) in current where shouldNotify(previous: previous[id], current: state) {
            emit.append(id)
        }
        return (emit.sorted(), current)
    }
}

/// The rising-edge coordinator (Story 2.4, Task 2): the ONE derivation-layer
/// module that owns the per-host "previous state" memory and drives the injected
/// emitter. Legitimately introduces the previous-state memory forbidden until now
/// (1.4/2.2 kept `reduce` pure, memory-free) — held HERE, not in `HostSnapshot`
/// (which stays facts-only) and not in `reduce` (which stays pure).
public final class NotificationCoordinator: @unchecked Sendable {
    /// F-1 (Mary review): the coordinator owns MUTABLE state (`previousStates`).
    /// Under the nominal wiring it is touched only by the poll-loop thread (like
    /// `TailscaleFactStore`/`SnapshotStore`), but a FUTURE manual refresh (AD-16,
    /// Story 3.1) could call `processCycle` off that thread — an unsynchronized
    /// read/write of the map would then be a data race, invisible in single-thread
    /// `swift test` and revealed only under TSan or in prod. So the lock is the
    /// DEFAULT, not "optional": it guards the whole decide→emit→write-back
    /// sequence, matching the codebase's defense-in-depth `NSLock` pattern.
    private let lock = NSLock()
    /// Starts EMPTY ⇒ the first `processCycle` sees `previous == nil` for every
    /// host ⇒ zero emission, and the write-back lays the baseline (cold start
    /// muet by construction, AC3 — no special-case guard).
    private var previousStates: [String: HostState] = [:]
    /// The injected emission effect (the seam). Real impl is app-side.
    private let emit: RisingEdgeEmitter

    public init(emitter: @escaping RisingEdgeEmitter) {
        self.emit = emitter
    }

    /// End-of-cycle step (call from `onCycleComplete`, AFTER the projection —
    /// never on the pre-poll initial projection, or the baseline would seed from
    /// data-less stale and the first real red would wrongly fire).
    ///
    /// F-2 (Mary review): the `emit(...)` call below is the ONE AND ONLY call site
    /// of the emitter seam in the whole codebase. Rising-edge notifications
    /// originate here and nowhere else — no surface (menu bar / future popover /
    /// widget) calls the emitter, and there is no second wiring of `processCycle`.
    /// This single call site is what guarantees AC1's "exactly one" per rising
    /// transition and AD-13's anti-duplication intent.
    public func processCycle(currentStates: [String: HostState]) {
        lock.lock()
        defer { lock.unlock() }
        let (ids, next) = RisingEdge.step(previous: previousStates, current: currentStates)
        for id in ids {
            guard let state = currentStates[id] else { continue }
            emit(id, state)  // fire-and-forget effect — one emission per rising edge
        }
        // Write-back is UNCONDITIONAL, every cycle, even when nothing was emitted
        // (incl. the Tailscale-override cycles that force all hosts stale). This
        // baseline reset is exactly what lets a later recovery be seen as a fresh
        // rising edge (AC4): without it, `previous` would stay red and recovery
        // would read as red→red (0 — a bug). R1 (burst amortization) is GATED and
        // NOT implemented here: K hosts grey→red ⇒ K emissions, no debounce.
        previousStates = next
    }
}
