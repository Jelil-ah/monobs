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
        XCTAssertEqual(WidgetPresentation.ageText(30), "30s")      // seconds
        XCTAssertEqual(WidgetPresentation.ageText(90), "2min")     // minutes — 1,5 min ARRONDI SUPÉRIEUR à 2
        XCTAssertEqual(WidgetPresentation.ageText(7200), "2h")     // hours
        XCTAssertEqual(WidgetPresentation.ageText(259_200), "3j")  // days
        XCTAssertEqual(WidgetPresentation.ageText(nil), "jamais")  // never received
    }

    // Régression trouvée en re-review #3 — LE trou de couverture : tous les autres
    // cas `ageText` ci-dessus passent des valeurs ENTIÈRES, alors que les âges
    // réels sortent de `Date.timeIntervalSince` et sont FRACTIONNAIRES par nature.
    // `AgeFormatting.tiered` arrondissait bien au supérieur, mais l'adaptateur
    // `TimeInterval → Int` arrondissait AU PLUS PROCHE juste avant l'appel, ce qui
    // annulait la garantie : 60,1 s (= 1 min et un dixième) s'affichait « 1min ».
    // Sur un moniteur, sous-estimer l'ancienneté est le MAUVAIS sens d'erreur —
    // Monobs ne doit JAMAIS présenter une donnée comme plus fraîche qu'elle n'est.
    // Ce test verrouille le ceil DE BOUT EN BOUT (`TimeInterval` → `Int` → palier).
    func testAgeTextRoundsUpFractionalIntervalsEndToEnd() {
        // Un dixième de seconde APRÈS une borne ⇒ le palier supérieur, déjà.
        XCTAssertEqual(WidgetPresentation.ageText(60.1), "2min")     // jamais « 1min »
        XCTAssertEqual(WidgetPresentation.ageText(60.4), "2min")     // sous le demi-palier : l'ancien arrondi mentait ici
        XCTAssertEqual(WidgetPresentation.ageText(3600.1), "2h")     // jamais « 1h »
        XCTAssertEqual(WidgetPresentation.ageText(86_400.1), "2j")   // jamais « 1j »

        // Sous la seconde mais NON nul : la donnée a déjà de l'âge ⇒ « 1s ».
        XCTAssertEqual(WidgetPresentation.ageText(0.3), "1s")
        // Exactement zéro reste zéro (ceil(0) = 0) — pas de « 1s » fantôme.
        XCTAssertEqual(WidgetPresentation.ageText(0.0), "0s")

        // Le ceil s'applique d'ABORD aux secondes : 59,9 → 60 ⇒ promotion en min.
        XCTAssertEqual(WidgetPresentation.ageText(59.9), "1min")

        // Le fractionnaire ne perturbe pas le cas « jamais reçu ».
        XCTAssertEqual(WidgetPresentation.ageText(nil), "jamais")
    }

    // Story E1 review #2: `AgeFormatting.tiered` is the SHARED tier source both
    // surfaces delegate to. The popover previously showed RAW seconds, so "340 s"
    // overflowed the fixed age column and broke onto two lines; routing through
    // these tiers renders it as "6min". Ce test couvre ce que ce package peut
    // réellement couvrir : le comportement de `AgeFormatting.tiered` elle-même —
    // le cas d'overflow (340 → "6min") et chaque borne de palier.
    // PORTÉE — corrigé en review #3 : la cible de tests ne compile QUE
    // `MonobsKit`. `MenuBarPresentation.ageText` et le layout du popover vivent
    // dans la cible app SwiftUI, hors d'atteinte ici. Ce test ne prouve donc PAS
    // « l'alignement des deux surfaces » : il prouve que la source de paliers
    // partagée est correcte. Que le popover l'appelle bien (et avec le même
    // arrondi supérieur) se vérifie par lecture de `Monobs/MenuBarContent.swift`,
    // pas par cette assertion.
    func testSharedAgeTiersCoverPopoverOverflowFixAndBoundaries() {
        XCTAssertEqual(AgeFormatting.tiered(4), "4s")        // small: unchanged in popover
        XCTAssertEqual(AgeFormatting.tiered(59), "59s")      // last second tier
        XCTAssertEqual(AgeFormatting.tiered(60), "1min")     // s → min boundary (60 s pile = 1 min exacte)
        XCTAssertEqual(AgeFormatting.tiered(340), "6min")    // the popover overflow case (was "340 s") ; 340 s = 5,67 min ARRONDI SUPÉRIEUR à 6
        XCTAssertEqual(AgeFormatting.tiered(3540), "59min")  // last minute tier (59 min pile)
        XCTAssertEqual(AgeFormatting.tiered(3600), "1h")     // min → h boundary (1 h pile)
        XCTAssertEqual(AgeFormatting.tiered(82_800), "23h")  // last hour tier (23 h pile)
        XCTAssertEqual(AgeFormatting.tiered(86_400), "1j")   // h → j boundary (1 j pile)
    }

    // Winston (review E1, corrigé review #3) : tronquer — et même arrondir au plus
    // proche — SOUS-ESTIME l'ancienneté d'une donnée. Sur un moniteur c'est le
    // MAUVAIS sens d'erreur (la donnée paraît plus fraîche qu'elle ne l'est).
    // Chaque palier arrondit donc au SUPÉRIEUR (ceil) : ce que l'utilisateur lit
    // est toujours une borne HAUTE de fraîcheur. Corollaire : l'arrondi peut
    // atteindre la borne haute d'un palier (3541 s = 59,02 min → 60 min), et on
    // doit alors promouvoir au palier suivant plutôt qu'afficher « 60min » / « 24h ».
    func testAgeTiersRoundUpAndPromoteOnTierSaturation() {
        // Arrondi SUPÉRIEUR, sans saturation.
        XCTAssertEqual(AgeFormatting.tiered(89), "2min")     // 1,48 min → 2 (ceil, PAS 1)
        XCTAssertEqual(AgeFormatting.tiered(90), "2min")     // 1,5 min → 2
        XCTAssertEqual(AgeFormatting.tiered(340), "6min")    // 5,67 min → 6, PAS 5 (la troncature d'avant)
        XCTAssertEqual(AgeFormatting.tiered(5400), "2h")     // 1,5 h → 2

        // Anti-sous-estimation — LA garantie « jamais plus frais que la réalité » :
        // UNE seconde après une borne, le palier supérieur doit DÉJÀ s'afficher.
        // C'est précisément ce que l'arrondi au plus proche ratait (80 s ⇒ « 1min »,
        // 3700 s ⇒ « 1h », 90000 s ⇒ « 1j » : trois mensonges dans le sens dangereux).
        XCTAssertEqual(AgeFormatting.tiered(61), "2min")     // 1 min 01 ⇒ « 2min », jamais « 1min »
        XCTAssertEqual(AgeFormatting.tiered(80), "2min")     // 1 min 20 ⇒ « 2min » (l'ancien « 1min » mentait)
        XCTAssertEqual(AgeFormatting.tiered(3601), "2h")     // 1 h 00 min 01 ⇒ « 2h », jamais « 1h »
        XCTAssertEqual(AgeFormatting.tiered(3700), "2h")     // 1 h 01 ⇒ « 2h » (l'ancien « 1h » mentait)
        XCTAssertEqual(AgeFormatting.tiered(86_401), "2j")   // 1 j 00 h 00 min 01 ⇒ « 2j », jamais « 1j »
        XCTAssertEqual(AgeFormatting.tiered(90_000), "2j")   // 1 j 01 h ⇒ « 2j » (l'ancien « 1j » mentait)

        // Saturation de palier : le ceil touche la borne haute ⇒ promotion.
        XCTAssertEqual(AgeFormatting.tiered(3541), "1h")     // 59,02 min → 60 min ⇒ « 1h », jamais « 60min »
        XCTAssertEqual(AgeFormatting.tiered(3599), "1h")     // 59,98 min ⇒ « 1h »
        XCTAssertEqual(AgeFormatting.tiered(82_801), "1j")   // 23,0003 h → 24 h ⇒ « 1j », jamais « 24h »
        XCTAssertEqual(AgeFormatting.tiered(86_399), "1j")   // idem, juste sous les 24 h pleines

        // Les secondes (<60 s) restent EXACTES — aucun arrondi.
        XCTAssertEqual(AgeFormatting.tiered(0), "0s")
        XCTAssertEqual(AgeFormatting.tiered(59), "59s")
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
