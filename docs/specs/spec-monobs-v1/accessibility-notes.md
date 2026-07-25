# Notes d'accessibilité et angles morts de rendu — Monobs v1

Companion de `SPEC.md`. Porte CAP-6, CAP-7, CAP-8 et le portage du plancher macOS.

Quatre angles morts ont été trouvés par les reviews adversariales de la story E1, tous confirmés à HEAD `0a63c2d`. **Trois restent à traiter en v1 ; le quatrième est devenu caduc** avec le passage du plancher à macOS 14.

| # | Angle mort | Preuve | Traitement v1 |
|---|---|---|---|
| 1 | Réduire la transparence / Augmenter le contraste | `Monobs/PopoverContent.swift:56` applique `.ultraThinMaterial` + stops translucides **inconditionnellement**, aucune branche d'accessibilité | **Dans le périmètre** → CAP-6 |
| 2 | Anneau de focus sur macOS 13 | `.focusEffectDisabled()` n'existe qu'à partir de macOS 14 ; sur le plancher 13 l'anneau système restait dessiné sous l'anneau neutre | **Caduc** — plancher porté à macOS 14, l'API devient inconditionnelle |
| 3 | `AgeFormatting.tiered(Int)` public sans garde négative | `tiered(-1)` rend `"-1s"` ; les deux chemins UI gardent en amont, l'API publique reste mal-employable | **Dans le périmètre** → CAP-7 |
| 4 | Aucune couverture de test du thème | Seule cible de tests : `MonobsKitTests` (`MonobsKit/Package.swift:16`). Aucun test d'app/UI, de `Theme`, de focus, de matériau ou de contraste | **Dans le périmètre** → CAP-8, par checklist manuelle |

## 1. Transparence et contraste — le repli retenu

Le popover est la surface où l'utilisateur lit l'état réel de sa flotte. Sous Réduire la transparence, le verre chaud du thème Braise se dégrade et la hiérarchie visuelle des états peut se perdre. Une app « finie » ne peut pas devenir illisible sur un réglage système standard, activé notamment par les utilisateurs sensibles au mouvement et aux contrastes faibles.

**Repli tranché : fond opaque prune sombre du thème Braise**, et non le fond système standard. L'identité visuelle doit survivre au réglage d'accessibilité — on dégrade la translucidité, pas la marque. Sous Augmenter le contraste, contours et contraste texte/fond sont renforcés dans la même palette.

## 2. Plancher macOS 14 — pourquoi l'angle mort du focus disparaît

Le plancher passe de macOS 13 à macOS 14. Raison décisive : **aucun Mac sous macOS 13 n'est disponible** pour vérifier ce palier — les machines joignables sont en 26.5.x. Un plancher qu'on ne peut pas tester est une promesse creuse.

Conséquence directe : `.focusEffectDisabled()` devient disponible **inconditionnellement**, donc l'anneau de focus est purement neutre partout. Le défaut cosmétique — sur macOS 13 l'anneau système pouvait porter l'accent utilisateur, configurable en rouge, soit exactement la couleur qui signifie « incident » — n'existe plus. Il était auparavant assumé comme non-goal ; il est maintenant **résolu**, pas contourné.

### Portage à effectuer

| Emplacement | Valeur actuelle |
|---|---|
| `MonobsKit/Package.swift:10` | `platforms: [.macOS(.v13)]` |
| `Monobs.xcodeproj/project.pbxproj` | 4 blocs `MACOSX_DEPLOYMENT_TARGET = 13.0;` (Debug et Release des cibles du projet) |

## 3. Ce que les 191 tests verts ne prouvent pas

Ils couvrent `MonobsKit` : logique d'états, seuils, parsing, formatage. Ils ne touchent **rien** de ce que l'utilisateur voit — ni le thème, ni le matériau, ni le focus, ni le contraste, ni l'icône, ni le glyphe.

## 4. La preuve de rendu retenue (CAP-8)

**Checklist manuelle signée, versionnée dans le repo.** Une cible de tests app/UI macOS est un chantier en soi, hors périmètre v1 — d'où l'arbitrage en faveur de la checklist.

Forme attendue : une entrée par capacité visuelle (CAP-2 icône, CAP-3 glyphe, CAP-6 accessibilité), chacune portant la date d'exécution, la machine par famille (Apple Silicon / Intel, sans autre identifiant), le réglage système actif le cas échéant, et le résultat.

## Contrainte de vérification

Le VPS de build est Linux **sans toolchain Swift** : aucune preuve de rendu ne peut sortir de la CI. Chaque vérification visuelle exige une session Mac. Le palier vérifié est macOS 14+ — le seul que le parc permette d'exercer.
