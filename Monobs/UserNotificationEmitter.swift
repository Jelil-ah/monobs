//
//  UserNotificationEmitter.swift
//  Monobs
//

import Foundation
import UserNotifications
import MonobsKit

/// Story 2.4, Task 3: the REAL `UserNotifications` implementation of the injected
/// `RisingEdgeEmitter` seam (AD-13). It lives app-side (`Monobs/`), never in the
/// pure `MonobsKit` — `UNUserNotificationCenter.current()` requires a valid `.app`
/// bundle, so this effect is NEVER exercised in `swift test` (tests inject a spy);
/// the real smoke is deferred to the controller verification (B4).
///
/// `UserNotifications` is an Apple SYSTEM framework, not a third-party dependency
/// (respects the zero-dependency rule 1.1→2.2). Local notifications need NO
/// entitlement (unlike push / `aps-environment`): compatible with sandbox-OFF
/// (B5) and off-App-Store (B4); an `LSUIElement` agent may post them.
enum UserNotificationEmitter {

    /// Request notification authorization ONCE at startup. PROVISIONAL posture
    /// (§Blocker.1, analogous to B5 sandbox): if the user denies or leaves it
    /// pending, the system simply shows nothing — but the DECISION and WRITE-BACK
    /// never depend on the effect's success (fire-and-forget). A denial degrades
    /// visibility, it does NOT break the state.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Fire-and-forget: the outcome is intentionally ignored — the rising-
            // edge state machine runs identically whether or not it is granted.
        }
    }

    /// The emitter closure conforming to the `RisingEdgeEmitter` seam. Fire-and-
    /// forget and non-throwing. Each emission carries a UNIQUE request identifier
    /// (`UUID`, app-side) so K rising edges yield K VISIBLE notifications — the
    /// system REPLACES same-identifier requests, which would mask emissions
    /// (R1 not amortized here; K to the letter, FR9).
    ///
    /// PRIVACY (AD-15): the body is a FORMAT STRING + the injected `hostID`
    /// variable + the state label from `MenuBarPresentation.label(for:)` — NO host
    /// literal in this code. In prod `hostID` is a real hostname shown LOCALLY on
    /// the operator's machine (acceptable, NFR1 — not a repo leak). Tests/fixtures
    /// use RFC 2606 only and never reach this code (spy injected instead).
    static let emit: RisingEdgeEmitter = { hostID, state in
        let content = UNMutableNotificationContent()
        content.title = "Monobs"
        content.body = "\(hostID) — \(MenuBarPresentation.label(for: state))"
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        // Non-throwing at the seam: any add error is swallowed (fire-and-forget) —
        // the state must never depend on the effect.
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
