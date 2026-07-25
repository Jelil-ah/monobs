---
id: SPEC-monobs-v1
companions:
  - icon-assets.md
  - accessibility-notes.md
  - installation-notes.md
sources: []
---

> **Contrat canonique.** Ce SPEC et les fichiers listés dans `companions:` forment le contrat complet de ce qu'il faut construire, tester et valider.

# Monobs v1 — l'app finie

## Why

Une douleur, constatée par Jelil sur ses propres Macs. Monobs v0.2.0 fait son travail de fond — quatre états surveillés, quatre surfaces, seuils calibrés, 191 tests verts — mais reste inutilisable comme *application*. Il n'existe aucun moyen de la quitter : il faut tuer le process. Elle porte l'icône générique de macOS, donc rien ne la distingue dans le Dock ni dans le Finder. Son glyphe de barre de menu est un symbole système emprunté. Son installation n'est documentée nulle part, ce qui l'a fait tourner depuis un dossier de quarantaine avec deux copies concurrentes sur la machine. Et le binaire publié est mono-architecture `arm64` : sur le Mac Intel du parc, l'app ne démarre pas du tout. Jelil est non-développeur : chacun de ces manques le renvoie au terminal ou à un forum. v1 est la version qu'il installe sur n'importe lequel de ses Macs, reconnaît, utilise toute la journée et retire — sans jamais ouvrir un terminal. C'est le passage de « ça marche » à « c'est une app ».

## Capabilities

- **CAP-1 — Quitter**
  - **intent:** L'utilisateur peut arrêter Monobs depuis Monobs, sans outil externe.
  - **success:** Depuis l'icône de barre de menu, une action « Quitter » est atteignable et termine le process ; aucun Monobs ne subsiste dans le Moniteur d'activité. Vérifié sur Mac par démonstration.

- **CAP-2 — Identité visuelle**
  - **intent:** L'utilisateur reconnaît Monobs à son icône partout où macOS l'affiche.
  - **success:** L'app apparaît avec l'icône prune du thème D2 dans le Finder, le Dock, Spotlight et la fenêtre « À propos » ; aucune icône générique nulle part. `AppIcon.appiconset` contient toutes les tailles requises et le build Release ne remonte aucun avertissement d'icône manquante.

- **CAP-3 — Glyphe de barre de menu propre à Monobs**
  - **intent:** L'état de la flotte se lit dans la barre de menu à travers un glyphe qui appartient à Monobs, distinct du nominal à l'incident.
  - **success:** Le glyphe affiché n'est plus un symbole système ; il présente deux formes statiques distinguables à l'œil, nominale et incident, et suit l'état réel. Voir `icon-assets.md`.

- **CAP-4 — Installation guidée**
  - **intent:** Un non-développeur installe Monobs correctement du premier coup en suivant la documentation publique, sur une machine où l'app n'est pas signée.
  - **success:** Le README décrit le geste complet — télécharger, copier dans `/Applications` AVANT d'ouvrir, puis clic droit → Ouvrir au premier lancement — et nomme explicitement le piège de la quarantaine. Une installation suivant ce texte tourne depuis `/Applications`, jamais depuis un chemin `AppTranslocation`. Les notes de release publient le checksum SHA-256 du zip ; le vérifier est optionnel et ne figure pas sur le chemin nominal d'installation. Voir `installation-notes.md`.

- **CAP-5 — Désinstallation propre**
  - **intent:** L'utilisateur retire Monobs et tout ce qu'il laisse derrière lui, en sachant qu'il n'a rien oublié.
  - **success:** La documentation liste chaque emplacement écrit par Monobs et le geste pour chacun, y compris le cas des copies multiples ; après application, aucune copie résiduelle ni élément de barre de menu ne subsiste. Documentation seule — v1 ne livre pas de script de désinstallation.

- **CAP-6 — Lisibilité sous réglages d'accessibilité**
  - **intent:** L'état de la flotte reste lisible quand l'utilisateur active Réduire la transparence ou Augmenter le contraste.
  - **success:** Sous Réduire la transparence, le popover présente un fond opaque prune sombre du thème Braise — pas le fond système — et conserve la distinction des états. Sous Augmenter le contraste, contours et contraste texte/fond sont préservés. Aucun élément ne devient illisible ni ne disparaît. Vérifié par démonstration sur Mac avec le réglage activé. Voir `accessibility-notes.md`.

- **CAP-7 — Invariant de fraîcheur défendu à la frontière de l'API**
  - **intent:** Aucun appelant du formatage d'âge ne peut produire un affichage absurde ou plus frais que la donnée réelle, quel que soit l'usage de l'API publique.
  - **success:** Une entrée hors domaine (âge négatif) ne produit jamais une chaîne d'âge trompeuse ; le comportement est explicite et couvert par un test dans `MonobsKitTests`.

- **CAP-8 — Preuve de rendu**
  - **intent:** L'équipe peut affirmer que l'apparence de v1 est conforme, avec une preuve, et pas seulement parce que la suite unitaire est verte.
  - **success:** Une checklist manuelle signée, versionnée dans le repo, porte une entrée datée par capacité visuelle (CAP-2, CAP-3, CAP-6), chacune exécutée sur Mac avec son résultat consigné. Pas de cible de tests app/UI en v1.

- **CAP-9 — Distribution universelle**
  - **intent:** L'app s'installe et démarre sur les Macs Apple Silicon comme sur les Macs Intel du parc, sans manipulation particulière.
  - **success:** Le binaire de la release contient les deux architectures — vérifiable en lisant l'en-tête Mach-O : fat binary, `arm64` + `x86_64`. Démarrage démontré sur au moins une machine de chaque famille. Voir `installation-notes.md`.

## Constraints

- **Plancher macOS 14** (`MonobsKit/Package.swift`, cibles Xcode). Exclut de promettre un support macOS 13, qu'aucune machine disponible ne permet de vérifier ; rend `.focusEffectDisabled()` disponible inconditionnellement ; exclut toute API macOS 15+ sans repli explicite.
- **Binaire de release universel** (`arm64` + `x86_64`). Exclut tout build mono-architecture limité à celle de la machine de build — ce qui a produit le thin `arm64` de v0.2.0, injouable sur Intel.
- **Zéro dépendance externe.** Exclut toute bibliothèque tierce d'animation, de rendu d'icône ou d'auto-update : tout se fait en SwiftUI/AppKit natif ou ne se fait pas.
- **Read-only.** Monobs observe, n'agit jamais sur les serveurs surveillés. Exclut tout bouton d'action distante, y compris « redémarrer », y compris en v1. « Quitter » agit sur le process local et ne viole pas cette règle.
- **Repo public + lint CI `scripts/t-priv` bloquant.** Exclut de committer un chemin de machine de dev, un identifiant d'infra réel, ou un asset portant ces métadonnées. Le lint a déjà fait échouer un build sur cette règle.
- **Pas de compte développeur Apple payant** → app non signée, non notarisée. Exclut l'installation par simple double-clic et tout auto-update signé. Impose de documenter le geste clic droit → Ouvrir plutôt que de le contourner, et de publier un checksum à défaut de signature.
- **Build et tests sur Mac distant** (le VPS de build est Linux sans toolchain Swift). Exclut toute preuve de rendu produite en CI : la vérification visuelle passe forcément par une session Mac.
- **Aucune surface animée en v1.** Le glow subsiste comme traitement visuel statique réservé à l'état incident. Exclut tout mouvement dans le popover, le widget et la barre de menu.
- **L'âge s'arrondit toujours au supérieur.** Exclut la troncature et tout affichage d'un âge négatif : ne jamais présenter une donnée comme plus fraîche qu'elle ne l'est.

## Non-goals

- **Animation du glyphe de barre de menu** — le mouvement permanent coûte du CPU et de la batterie, et 24 PNG embarqués pour un élément de ~16 px ne se justifient pas quand l'identité visuelle est acquise sans lui. Reporté, pas abandonné : recandidate en v2.
- **Skins multi-formes de glyphe** (plusieurs personnages type RunCat) — reporté explicitement par Jelil.
- **Icône d'app à état variable** — `appicon-incident.png` reste hors v1 ; l'icône du Dock demeure nominale et l'état se lit sur la barre de menu (cf. A2). Asset conservé pour plus tard.
- **Lancement au démarrage (login item)** — périmètre déjà large et jamais demandé par l'utilisateur.
- **Signature et notarisation Apple** — hors budget ; v1 assume l'app non signée et documente le geste correspondant.
- **Toute action sur les serveurs surveillés** — le read-only n'est pas relâché en v1.
- **Refonte du layout du popover** — le thème D2 « Braise » livré en story E1 est acquis ; v1 ne rejoue pas la mise en page.
- **Cible de tests app/UI** — la conformité visuelle de v1 s'appuie sur une checklist manuelle signée (CAP-8), pas sur une cible de tests macOS à construire.
- **Auto-update in-app** — incompatible avec l'absence de signature et avec la contrainte zéro dépendance.

## Success signal

Jelil télécharge le zip de la release v1 depuis GitHub, suit le README, et l'app démarre aussi bien sur son Mac Apple Silicon que sur son Mac Intel — avec son icône prune dans `/Applications` et son propre glyphe, statique et calme, dans la barre de menu. Il l'utilise une journée entière, active Réduire la transparence et retrouve un fond prune opaque toujours lisible, puis quitte l'app depuis l'app et la désinstalle en suivant la doc. Aucun terminal ouvert, aucun process tué, aucune copie oubliée, aucune question posée à Bianca pendant le parcours.

## Assumptions

- **A1** — Les assets de `<design-workspace>/monobs/icon-d2/` sont finaux ; v1 les décline sans nouvelle passe de design.
- **A2** — L'icône d'app du Dock/Finder reste nominale en permanence ; le changement d'état se lit sur la barre de menu, pas sur l'icône d'app.
- **A3** — Le geste « quitter » doit être atteignable en 2 gestes au plus depuis l'icône de barre de menu ; sa forme exacte reste au design.
- **A4** — v1 est publiée comme release GitHub avec `Monobs.zip`, même canal que v0.2.0.
- **A5** — Aucune migration de réglages n'est nécessaire entre v0.2.0 et v1.
- **A6** — Le parc cible compte trois Macs : deux Apple Silicon (dont la machine principale, hors ligne et non auditable à ce jour) et un Mac Intel de test. v1 doit être installable sur les trois sans traitement particulier — ce que CAP-9 garantit. Une seule des trois a été auditée directement, d'où l'hypothèse.

## Open Questions

Aucune question ouverte. Les huit questions de la première passe ont été tranchées le 2026-07-25 ; les décisions et leurs raisons sont dans `.memlog.md`.
