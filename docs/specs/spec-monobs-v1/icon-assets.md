# Assets d'icône et de glyphe — Monobs v1

Companion de `SPEC.md`. Porte CAP-2 (identité visuelle) et CAP-3 (glyphe de barre de menu).

## Direction validée

Octogone cristal 3D **prune translucide** flottant sur fond quasi-noir, **orbe d'état verte au cœur** (rouge en incident), glow façon Thaw. Direction confirmée par Jelil (« on poursuis »). Cohérente avec le thème D2 « Braise » porté en story E1.

## Assets existants (hors repo)

Racine : `<design-workspace>/monobs/icon-d2/`

| Asset | Contenu | Usage v1 |
|---|---|---|
| `appicon.png` | Icône d'app, état nominal | Source de `AppIcon.appiconset` (CAP-2) |
| `appicon.svg` | Même icône, vectoriel | Source pour les grandes tailles / re-export propre |
| `appicon-incident.png` | Icône d'app, état incident | **Hors v1** — l'icône du Dock reste nominale (A2). Asset conservé pour plus tard |
| `glyph-frames/` | 24 PNG : 12 frames pouls nominal + 12 frames incident | **2 frames retenues** : une par état, comme formes statiques du glyphe (CAP-3). Les 22 autres ne sont pas embarquées |
| `glyph-anim-spec.md` | Timings d'animation (nominal ≈135 ms/frame, incident ≈55 ms/frame) | **Hors v1** — conservé pour une éventuelle v2 animée |

## État actuel dans le repo

- `Monobs/Assets.xcassets/AppIcon.appiconset/` ne contient que `Contents.json` — **zéro image**. L'app porte l'icône générique macOS.
- `Monobs/MonobsApp.swift:170` affiche un `Image(systemName:)` — un symbole **système** statique, pas un glyphe Monobs.

## Livrables v1

1. Peupler `AppIcon.appiconset` avec l'ensemble des tailles macOS requises, dérivées de `appicon.svg`/`appicon.png`.
2. Embarquer le glyphe de barre de menu Monobs sous ses deux formes statiques (nominale, incident) et remplacer le `Image(systemName:)`. Choisir la frame la plus représentative de chaque état dans `glyph-frames/`.

## Pourquoi le glyphe n'est pas animé en v1

L'animation était l'unique exception au « pas de mouvement » du produit. Tranché contre : un mouvement permanent consomme CPU et batterie en continu, et embarquer 24 PNG pour un élément de ~16 px ne se justifie pas quand l'identité visuelle — un glyphe qui appartient à Monobs, distinct du nominal à l'incident — est déjà acquise sans lui. Report explicite, pas abandon : les frames et les timings restent disponibles pour recandidater en v2.

## Contraintes portées

- Les assets doivent entrer dans le repo **public** sans métadonnée de chemin de machine de dev : le lint CI `scripts/t-priv` est bloquant.
- Zéro dépendance externe : le rendu se fait en SwiftUI/AppKit natif.
- Aucune surface animée en v1. Le glow subsiste comme traitement **statique** réservé à l'état incident : popover, widget et barre de menu restent immobiles.
- La conformité visuelle de ces deux livrables se prouve par la checklist manuelle signée de CAP-8 (`accessibility-notes.md`), pas par la suite unitaire.
