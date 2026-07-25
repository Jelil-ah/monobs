import XCTest
@testable import MonobsKit

// CAP-7 — la frontière de l'API de formatage d'âge.
//
// `AgeFormatting.tiered` est PUBLIC et partagé par deux surfaces. Avant ce
// correctif il n'avait aucune garde de domaine : `tiered(-1)` rendait "-1s".
// Les deux appelants gardaient en amont (le popover renvoie "—" si `age < 0`,
// `WidgetAge.age` échoue en `nil` sur horodatage futur), donc l'UI n'était pas
// cassée — mais l'API restait MAL-EMPLOYABLE : tout nouvel appelant devait
// redupliquer le garde, et un seul oubli affichait un âge négatif sur un
// moniteur. On défend donc l'invariant à la frontière, pas seulement chez les
// appelants. Ces tests verrouillent les deux bouts du domaine (`0 ... Int.max`)
// ET la non-régression du chemin valide (I7 : ceil + promotion de palier).
final class AgeFormattingGuardTests: XCTestCase {

    // MARK: - Borne basse : hors domaine

    // LE défaut corrigé. Une entrée négative ne doit JAMAIS produire une chaîne
    // qui se LIT comme un âge : "-1s" n'est pas seulement laid, il est trompeur
    // (il passe pour une durée). Repli sur le marqueur neutre, le même tiret
    // cadratin que le popover affiche déjà sur horloge décalée — vocabulaire
    // visuel unique sur toutes les surfaces.
    func testNegativeSecondsNeverRenderAnAgeString() {
        // -1 : le cas exact rapporté par la review (rendait "-1s").
        XCTAssertEqual(AgeFormatting.tiered(-1), AgeFormatting.unavailable)
        // -3600 : négatif assez grand pour atteindre les paliers min/h de l'ancien
        // code — la garde doit tomber AVANT tout calcul de palier, pas dedans.
        XCTAssertEqual(AgeFormatting.tiered(-3_600), AgeFormatting.unavailable)
        // Int.min : la borne extrême. Piège une implémentation qui normaliserait
        // par négation (`-Int.min` n'a pas de représentation ⇒ crash) ou qui
        // ajouterait `+59` avant de tester le signe.
        XCTAssertEqual(AgeFormatting.tiered(Int.min), AgeFormatting.unavailable)

        // Garantie formulée telle qu'un lecteur d'écran la vit : aucun signe
        // négatif, aucun suffixe d'unité, quelle que soit l'entrée hors domaine.
        for seconds in [-1, -59, -60, -3_600, -86_400, Int.min] {
            let rendered = AgeFormatting.tiered(seconds)
            XCTAssertFalse(rendered.contains("-"), "âge négatif rendu pour \(seconds) : \(rendered)")
            XCTAssertFalse(rendered.hasSuffix("s"), "suffixe d'unité rendu pour \(seconds) : \(rendered)")
            XCTAssertFalse(rendered.hasSuffix("min"), "suffixe d'unité rendu pour \(seconds) : \(rendered)")
            XCTAssertFalse(rendered.hasSuffix("h"), "suffixe d'unité rendu pour \(seconds) : \(rendered)")
            XCTAssertFalse(rendered.hasSuffix("j"), "suffixe d'unité rendu pour \(seconds) : \(rendered)")
        }
    }

    // Le point d'entrée qui rend l'invalidité REPRÉSENTABLE dans le type, pour
    // les appelants qui veulent leur propre repli plutôt que le marqueur neutre.
    // C'est ce qui rend le contrat vérifiable par le compilateur et non plus
    // seulement documenté.
    func testOutOfDomainIsRepresentableAsNil() {
        XCTAssertNil(AgeFormatting.tieredIfInDomain(-1))
        XCTAssertNil(AgeFormatting.tieredIfInDomain(-3_600))
        XCTAssertNil(AgeFormatting.tieredIfInDomain(Int.min))

        // Zéro est DANS le domaine : un âge nul est valide (donnée reçue à
        // l'instant), il ne doit pas basculer dans le repli.
        XCTAssertEqual(AgeFormatting.tieredIfInDomain(0), "0s")
    }

    // Les deux points d'entrée sont une seule et même fonction sur le domaine
    // valide : `tiered` n'est que `tieredIfInDomain` + repli. Verrouillé pour
    // qu'une future divergence entre les deux ne passe pas inaperçue.
    func testBothEntryPointsAgreeOnTheValidDomain() {
        for seconds in [0, 1, 59, 60, 61, 3_540, 3_600, 86_400, 259_200] {
            XCTAssertEqual(AgeFormatting.tiered(seconds),
                           AgeFormatting.tieredIfInDomain(seconds),
                           "divergence des deux points d'entrée à \(seconds) s")
        }
    }

    // MARK: - Borne haute : arithmétique du ceil

    // L'ancien idiome de ceil (`(seconds + unit - 1) / unit`) DÉBORDE près de
    // `Int.max` — et en Swift un débordement signé fait crasher le process. Un
    // moniteur ne crashe pas sur un horodatage aberrant : c'est exactement le
    // genre de valeur qu'une horloge décalée ou un fichier corrompu peut
    // produire. Les valeurs ci-dessous ciblent chacune l'une des trois additions
    // de l'ancien code (`+59`, `+3599`, `+86399`) ; le simple fait que ce test
    // se termine prouve l'absence de piège arithmétique.
    func testUpperBoundDoesNotTrapOnCeilArithmetic() {
        // `Int.max` : déborderait sur `+59` dès le palier des minutes.
        // Attendu = ceil(Int.max / 86400) = 106 751 991 167 301 jours.
        XCTAssertEqual(AgeFormatting.tiered(Int.max), "\(Int.max / 86_400 + 1)j")
        // `Int.max - 1` : idem, juste sous la borne.
        XCTAssertEqual(AgeFormatting.tiered(Int.max - 1), "\((Int.max - 1) / 86_400 + 1)j")
        // `Int.max - 3_000` : passe `+59` mais déborderait sur `+3599` (palier h).
        XCTAssertEqual(AgeFormatting.tiered(Int.max - 3_000), "\((Int.max - 3_000) / 86_400 + 1)j")
        // `Int.max - 86_000` : passe `+59` et `+3599` mais déborderait sur
        // `+86399` (palier j) — le dernier des trois pièges.
        XCTAssertEqual(AgeFormatting.tiered(Int.max - 86_000), "\((Int.max - 86_000) / 86_400 + 1)j")

        // Une valeur extrême reste un ÂGE lisible, pas un repli : la borne haute
        // est dans le domaine accepté, contrairement au négatif.
        XCTAssertNotEqual(AgeFormatting.tiered(Int.max), AgeFormatting.unavailable)
        XCTAssertNotNil(AgeFormatting.tieredIfInDomain(Int.max))
    }

    // MARK: - Non-régression du chemin valide (I7)

    // La garde de domaine et le changement d'idiome de ceil ne doivent RIEN
    // changer pour les entrées valides — c'est ce qui rend le correctif sûr pour
    // les deux appelants existants, qu'on n'a pas touchés. Chaque cas est une
    // borne : dernier de son palier, premier du suivant, ou saturation par ceil.
    func testValidDomainTiersAreUnchanged() {
        XCTAssertEqual(AgeFormatting.tiered(0), "0s")        // plancher du domaine — exact, pas d'arrondi
        XCTAssertEqual(AgeFormatting.tiered(59), "59s")      // dernière seconde avant promotion
        XCTAssertEqual(AgeFormatting.tiered(60), "1min")     // borne s → min (1 min PILE, aucun ceil à faire)
        XCTAssertEqual(AgeFormatting.tiered(61), "2min")     // 1 s après la borne ⇒ palier suivant DÉJÀ (jamais « 1min »)
        XCTAssertEqual(AgeFormatting.tiered(3_540), "59min") // dernier palier min (59 min pile)
        XCTAssertEqual(AgeFormatting.tiered(3_541), "1h")    // ceil sature à 60 min ⇒ promotion, jamais « 60min »
        XCTAssertEqual(AgeFormatting.tiered(3_601), "2h")    // 1 s après l'heure ⇒ « 2h », jamais « 1h »
        XCTAssertEqual(AgeFormatting.tiered(82_801), "1j")   // ceil sature à 24 h ⇒ promotion, jamais « 24h »
        XCTAssertEqual(AgeFormatting.tiered(86_401), "2j")   // 1 s après le jour ⇒ « 2j », jamais « 1j »
    }
}
