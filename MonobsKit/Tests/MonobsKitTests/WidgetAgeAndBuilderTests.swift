import XCTest
@testable import MonobsKit

// Story 3.2 (AC3/AC4/AC8): the age is a PURE projection of the ABSOLUTE freshness
// instant, and the writer's core serializes that instant — NOT the age duration.
// Together these prove Mary #1: the widget age GROWS while the app is stopped.
final class WidgetAgeAndBuilderTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func host(_ id: String) -> ObservedHost {
        ObservedHost(name: id, host: id, user: "monobs", port: 22)
    }

    // AC4 (the crux): with a FIXED absolute freshnessTimestamp and an advancing
    // `now`, the projected age STRICTLY GROWS. This is exactly what a frozen
    // duration could not do — proof the contract must carry the instant.
    func testAgeGrowsAsNowAdvancesAgainstFixedTimestamp() {
        let freshness = t0                      // fixed instant, app "stopped"
        let base = t0                           // local copy so the closure captures a value, not `self`
        let ageAt = { (offset: TimeInterval) in
            WidgetAge.age(freshnessTimestamp: freshness, now: base.addingTimeInterval(offset))
        }
        XCTAssertEqual(ageAt(0), 0)
        XCTAssertEqual(ageAt(30), 30)
        XCTAssertEqual(ageAt(300), 300)
        // Strictly increasing across three distinct timeline instants.
        XCTAssertLessThan(ageAt(30)!, ageAt(300)!)
        XCTAssertGreaterThan(ageAt(600)!, ageAt(300)!)
    }

    // AC3 fail-closed: never-received (nil timestamp) ⇒ nil age (rendered
    // "jamais"), and a future timestamp (clock skew) ⇒ nil, never negative.
    func testAgeFailClosedForNilAndFutureTimestamp() {
        XCTAssertNil(WidgetAge.age(freshnessTimestamp: nil, now: t0))
        XCTAssertNil(WidgetAge.age(freshnessTimestamp: t0.addingTimeInterval(45), now: t0),
                     "future timestamp must project nil, never a negative age")
    }

    // AC8 / Mary #1: the writer core serializes the ABSOLUTE freshness instant
    // from the SnapshotStore, NOT the projected `HostProjection.age` duration.
    // Built at t0, then decoded and aged at a LATER instant ⇒ the age reflects
    // the later instant (it grew), which only works because the instant — not a
    // frozen duration — was serialized.
    func testBuilderSerializesAbsoluteInstantSoAgeGrowsAfterWrite() throws {
        let receivedAt = t0.addingTimeInterval(-30)     // last report 30 s before build
        let snapshots: [String: HostSnapshot] = [
            "vps-a.example": HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: receivedAt, sshFailureActive: false),
        ]
        // Project at t0 (age would be 30 s here)...
        let projection = MenuBarProjector.project(hosts: [host("vps-a.example")],
                                                  snapshots: snapshots,
                                                  now: t0,
                                                  tailscaleLocalUp: true)
        let container = SharedSnapshotBuilder.build(projection: projection, snapshots: snapshots)
        // The serialized field is the absolute instant, not the 30 s duration.
        XCTAssertEqual(container.hosts.first?.freshnessTimestamp, receivedAt)

        // ...round-trip, then age at t0 + 300 s (app has been stopped). The age
        // must be 330 s (grew), NOT frozen at 30 s.
        let data = try SharedSnapshotCodec.encode(container)
        guard case .ok(let decoded) = SharedSnapshotCodec.decode(data) else {
            return XCTFail("must decode")
        }
        let later = t0.addingTimeInterval(300)
        let agedLater = WidgetAge.age(freshnessTimestamp: decoded.hosts[0].freshnessTimestamp, now: later)
        XCTAssertEqual(agedLater, 330, "age must grow to 330 s, not freeze at the 30 s write-time duration")
    }

    // D-3 / FR5: age text is formatted in legible, deterministic tiers
    // (s → min → h → j). Covers each tier at a representative value plus the
    // never-received fallback. Manual tiers (not a localized formatter) keep this
    // assertion stable regardless of test-host locale.
    func testAgeTextIsFormattedInLegibleTiers() {
        XCTAssertEqual(WidgetPresentation.ageText(30), "il y a 30s")     // seconds
        XCTAssertEqual(WidgetPresentation.ageText(90), "il y a 1min")    // minutes
        XCTAssertEqual(WidgetPresentation.ageText(7200), "il y a 2h")    // hours
        XCTAssertEqual(WidgetPresentation.ageText(259_200), "il y a 3j") // days
        XCTAssertEqual(WidgetPresentation.ageText(nil), "jamais")        // never received
    }

    // AC8: the builder carries the reducer's DERIVED state verbatim (no
    // re-derivation) and preserves per-host mapping.
    func testBuilderCarriesDerivedStateVerbatim() {
        let snapshots: [String: HostSnapshot] = [
            "vps-a.example": HostSnapshot(lastValidFacts: nil, lastValidReceivedAt: t0, sshFailureActive: true),
        ]
        let projection = MenuBarProjector.project(hosts: [host("vps-a.example")],
                                                  snapshots: snapshots,
                                                  now: t0,
                                                  tailscaleLocalUp: true)
        let container = SharedSnapshotBuilder.build(projection: projection, snapshots: snapshots)
        // Active failure + Tailscale up ⇒ reducer says rougeInjoignable; the
        // builder must carry exactly that (AD-11 — not recomputed).
        XCTAssertEqual(container.hosts.first?.state, projection.hosts.first?.state)
        XCTAssertEqual(container.hosts.first?.state, .rougeInjoignable)
    }
}
