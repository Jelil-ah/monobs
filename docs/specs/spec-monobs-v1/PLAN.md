---
id: PLAN-monobs-v1
spec: SPEC-monobs-v1
author: Winston (bmad-agent-architect)
date: 2026-07-25
---

# Plan d'exécution — Monobs v1

Contrat amont : `SPEC.md` + companions (`icon-assets.md`, `accessibility-notes.md`, `installation-notes.md`). Ce plan ajoute **CAP-10**, postérieure à la SPEC, et découpe le tout en tranches à fichiers disjoints. Un worker par tranche. Personne ne code hors de sa liste de fichiers.

## CAP-10 — Configuration depuis l'app (formulation canonique)

- **intent :** Un destinataire non-développeur configure sa flotte depuis Monobs — ajouter, modifier, retirer un hôte — sans éditer de fichier ni ouvrir un terminal. C'est le déblocage du partage : aujourd'hui, sans `~/.config/monobs/hosts.toml` écrit à la main, l'app affiche une liste vide (`HostConfig.swift:50`, aucun écran de réglages dans l'app).
- **success :**
  1. Au premier lancement sans configuration, l'app guide vers l'ajout d'un hôte depuis l'interface ; l'ajout démarre la surveillance **sans relancer l'app**.
  2. Ajout, modification et retrait s'écrivent dans `~/.config/monobs/hosts.toml` — le TOML reste **la source de vérité sur disque**.
  3. Compatibilité descendante : un `hosts.toml` préexistant valide est lu à l'identique (mêmes hôtes, mêmes diagnostics) et ses entrées apparaissent dans l'éditeur, pré-remplies.
  4. Fail-closed sur l'illisible : un fichier hors du subset documenté (déjà rejeté par le parser) n'est **jamais écrasé silencieusement** — l'édition est refusée avec le diagnostic existant.
  5. Couvert par tests `MonobsKitTests` (round-trip écriture→lecture, reconfiguration du polling) + entrée dédiée dans la checklist CAP-8.

Note d'arbitrage assumée ici : l'écriture in-app régénère le fichier dans le subset documenté (5 clés connues). Les commentaires `#` d'un fichier écrit à la main ne survivent pas à une édition in-app — perte acceptée et documentée dans `docs/host-config.md`. La *lecture* d'un fichier commenté reste inchangée (point 3).

## Invariants NON NÉGOCIABLES (tous workers, toutes tranches)

| # | Invariant |
|---|---|
| I1 | Plancher **macOS 14** (décidé, remplace 13 — cf. `.memlog.md` Q4). Aucune API 15+ sans repli explicite. |
| I2 | **Zéro dépendance externe.** SwiftUI/AppKit natif ou rien. Pas de lib TOML tierce : le writer suit le pattern du parser maison. |
| I3 | **Read-only serveurs.** Aucune action distante. « Quitter » agit sur le process local : conforme. |
| I4 | Repo **public**, lint `scripts/t-priv` **bloquant** : aucun chemin de machine de dev, aucune IP, aucun nom d'hôte réel — y compris dans les **métadonnées des PNG** (strip avant commit). |
| I5 | Pas de signature Apple. Ne jamais promettre le double-clic au premier lancement. |
| I6 | Binaire de release **universel** `arm64` + `x86_64` (le thin arm64 de v0.2.0 est le défaut à fermer). |
| I7 | L'âge s'arrondit **toujours au supérieur** ; jamais d'âge négatif affiché. |
| I8 | **Aucune surface animée.** Le glow reste un traitement statique réservé à l'incident. |
| I9 | Un worker ne modifie **JAMAIS** un test existant pour le faire passer. Test existant devenu faux → STOP, signalement à l'orchestrateur. |
| I10 | Un worker ne touche que les fichiers de sa tranche. Besoin hors liste → STOP, signalement. |

Note structurelle : le projet est au format Xcode 16 (dossiers synchronisés) — ajouter un `.swift` ou un imageset **ne** passe **pas** par `project.pbxproj`. Seule T1 touche ce fichier.

## Tranches

### Vague 1 — parallèle (fichiers tous disjoints)

| ID | CAP | Classe | Fichiers (créer ➕ / modifier ✏️) | Hors périmètre | Preuve | Dépend de |
|---|---|---|---|---|---|---|
| **T1** | plancher + archi | MÉCANIQUE | ✏️ `MonobsKit/Package.swift` (`.v13`→`.v14`, ligne 10) ; ✏️ `Monobs.xcodeproj/project.pbxproj` (4 blocs `MACOSX_DEPLOYMENT_TARGET = 13.0;` → `14.0`, lignes ~288/345/440/470 + audit `ONLY_ACTIVE_ARCH`/`ARCHS` en Release pour garantir I6) | Tout autre réglage du pbxproj | `swift test` MonobsKit vert (191 tests) + build Release sur Mac sans warning | — |
| **T2** | CAP-1, CAP-6 | RISQUÉE | ✏️ `Monobs/PopoverContent.swift` (action Quitter atteignable en ≤2 gestes depuis l'icône de barre — A3 ; branche `accessibilityReduceTransparency` → fond **opaque prune sombre Braise**, jamais le fond système ; renfort contours sous contraste augmenté) ; ✏️ `Monobs/MonobsTheme.swift` (couleurs opaques/contraste du repli) | Layout du popover (non-goal), widget, `MonobsApp.swift` | Build Mac + démo : Quitter → zéro Monobs dans le Moniteur d'activité ; entrées checklist CAP-6 (réglages activés) | T1 (logique : plancher 14) |
| **T3** | CAP-3 | RISQUÉE | ➕ `Monobs/Assets.xcassets/MenuBarGlyphNominal.imageset/`, `MenuBarGlyphIncident.imageset/` (2 frames retenues de `glyph-frames/`, métadonnées strippées — I4) ; ✏️ `Monobs/MonobsApp.swift` (remplacer `Image(systemName:)` ligne 170 par le glyphe Monobs, forme selon l'agrégat) ; ✏️ `MonobsKit/Sources/MonobsKit/MenuBarProjection.swift` (**nouvelle** API aggregate→forme de glyphe, sans casser `aggregateSymbol` — I9, `MenuBarProjectionTests` intouchable) | Animation (non-goal), skins, icône d'app | Build Mac + entrée checklist CAP-3 (deux formes distinguables à l'œil, suit l'état réel) | T1 ; **humain** : fourniture des frames (assets hors repo) + validation du choix de frame |
| **T4** | CAP-2 | MÉCANIQUE | ✏️➕ `Monobs/Assets.xcassets/AppIcon.appiconset/` (`Contents.json` + toutes les tailles macOS dérivées de `appicon.svg`/`appicon.png`, métadonnées strippées) | `appicon-incident.png` (hors v1, A2/Q6), tout fichier Swift | Build Release **zéro warning d'icône** + entrée checklist CAP-2 (Finder, Dock, Spotlight, À propos) | **humain** : fourniture des assets (hors repo) ; génération des tailles sur Mac (`sips`/`iconutil`) |
| **T5** | CAP-4, CAP-5, CAP-8 (scaffold) | MÉCANIQUE | ✏️ `README.md` (install : télécharger → copier dans `/Applications` **AVANT** d'ouvrir → clic droit → Ouvrir ; piège quarantaine/AppTranslocation nommé ; checksum SHA-256 optionnel hors chemin nominal ; désinstallation : chaque emplacement écrit + geste, cas des copies multiples ; « macOS 13 » → **14** ; retirer la mention du glyphe « dashed-circle ») ; ➕ `docs/checklist-rendu-v1.md` (template : une entrée datée par CAP visuelle — CAP-2, CAP-3, CAP-6, CAP-10 — machine par famille, réglage actif, résultat) | Aucun script de désinstallation (Q2) ; aucun fichier Swift | Relecture : un non-développeur exécute sans terminal ; `t-priv` vert (machines désignées par famille uniquement) | — |
| **T6** | CAP-9 (outillage) | MÉCANIQUE | ➕ `scripts/build-release.sh` (build Release universel, vérif `lipo -archs` = `arm64 x86_64` **bloquante**, zip, `shasum -a 256`) ; ➕ `docs/release-process.md` (procédure + critère de recette : lecture en-tête Mach-O de l'asset publié) | Exécution de la release (humain, vague 3) ; CI (le VPS est Linux sans toolchain) | Script relu ; exécution prouvée en vague 3 | T1 (réglages archi) |
| **T7** | CAP-7 | RISQUÉE | ✏️ `MonobsKit/Sources/MonobsKit/AgeFormatting.swift` (garde à la frontière : entrée négative → comportement explicite, jamais `"-1s"`, jamais plus frais que la réalité — I7) ; ➕ `MonobsKit/Tests/MonobsKitTests/AgeFormattingGuardTests.swift` | Tout chemin UI (déjà gardé en amont) ; tests existants (I9) | `swift test` : nouveaux tests verts, 191 existants intacts | — |
| **T8** | CAP-10 (writer) | RISQUÉE | ➕ `MonobsKit/Sources/MonobsKit/HostConfigWriter.swift` (sérialise `[ObservedHost]` → subset TOML documenté, écriture **atomique**, création de `~/.config/monobs/` si absent, même seam `MONOBS_HOSTS_FILE`) ; ➕ `MonobsKit/Tests/MonobsKitTests/HostConfigWriterTests.swift` (round-trip writer→`HostConfigLoader.parse` = identité ; refus d'écraser un fichier que le parser rejette — fail-closed) | `HostConfig.swift` reste **intouché** (lecture inchangée = compat descendante) ; toute UI | `swift test` vert, round-trip prouvé | — |
| **T9** | CAP-10 (reload) | RISQUÉE | ✏️ `MonobsKit/Sources/MonobsKit/HostPollingLoop.swift` (reconfiguration de la liste d'hôtes à chaud, sérialisée sur la **même** queue que poll/refresh manuel — pas de cycle concurrent) ; ✏️ `MonobsKit/Sources/MonobsKit/Snapshot.swift` si purge des snapshots d'hôtes retirés nécessaire ; ➕ `MonobsKit/Tests/MonobsKitTests/HostPollingLoopReconfigureTests.swift` | UI ; writer ; `HostPollingLoopTests.swift` existant intouchable (I9) | `swift test` vert ; test prouvant qu'un hôte retiré cesse d'être pollé et qu'un ajouté entre au cycle suivant | — |

Parallélisme : T1–T9 n'ont **aucun fichier en commun** (vérifié ligne à ligne ci-dessus). Les « dépend de T1 » de T2/T3/T6 sont logiques (plancher, archi), pas des conflits de fichiers — elles peuvent démarrer en parallèle, mais leur preuve de build ne compte qu'après merge de T1.

### Vague 2 — sérialisée (conflits de fichiers réels)

| ID | CAP | Classe | Fichiers | Hors périmètre | Preuve | Dépend de |
|---|---|---|---|---|---|---|
| **T10** | CAP-10 (UI) | RISQUÉE — la plus lourde | ➕ `Monobs/SettingsContent.swift` (formulaire ajout/modif/retrait : name, host, user, port, identity ; état vide premier lancement → guide vers l'ajout) ; ✏️ `Monobs/MonobsApp.swift` (câblage fenêtre réglages + reconfiguration du runtime via T9) ; ✏️ `Monobs/PopoverContent.swift` (point d'entrée réglages, y compris depuis l'état vide) ; ✏️ `docs/host-config.md` (édition in-app, perte des commentaires documentée) | Validation réseau des hôtes saisis (read-only, on ne sonde pas à la saisie) ; migration (A5 : aucune) ; toute animation | `swift test` vert ; démo Mac : premier lancement sans config → ajout in-app → polling démarre sans relance ; config v0.2.0 préexistante lue à l'identique ; entrée checklist CAP-10 | **T2, T3** (conflit fichiers `PopoverContent.swift`, `MonobsApp.swift`) ; **T8, T9** (APIs) |

Sérialisation justifiée : T10 modifie `MonobsApp.swift` (aussi touché par T3) et `PopoverContent.swift` (aussi touché par T2) — conflit de fichiers réel, pas de la prudence. Et elle consomme les APIs de T8/T9 — dépendance réelle.

### Vague 3 — humaine + release (non automatisable)

| ID | Quoi | Classe | Nature |
|---|---|---|---|
| **T11** | Exécution de la checklist `docs/checklist-rendu-v1.md` sur Mac : CAP-2 (icône partout), CAP-3 (deux formes du glyphe), CAP-6 (réglages accessibilité **activés**), CAP-10 (parcours premier lancement) — entrées datées, signées, commit | **ACTION HUMAINE** | Aucune preuve de rendu ne peut sortir de la CI (VPS Linux sans toolchain) |
| **T12** | Release v1 : exécuter `scripts/build-release.sh` sur Mac, lire l'en-tête Mach-O de l'asset **publié** (fat, `arm64`+`x86_64`), publier `Monobs.zip` + SHA-256 dans les notes, démontrer le démarrage sur **une machine de chaque famille** (Apple Silicon + Intel), installation en suivant le README verbatim → l'app tourne depuis `/Applications`, jamais `AppTranslocation` | **ACTION HUMAINE** | CAP-9 + CAP-4 se prouvent sur l'asset publié, pas sur l'arbre de travail |

## Ordre d'exécution

```
Vague 1 :  T1  T2  T3  T4  T5  T6  T7  T8  T9   (parallèle, fichiers disjoints)
Vague 2 :  T10                                   (après T2+T3 [fichiers] et T8+T9 [APIs])
Vague 3 :  T11 puis T12                          (humain, sur Mac)
```

## Gates

### Avant chaque commit (toutes tranches)

1. `scripts/t-priv` — **PASS** (bloquant ; inclut métadonnées d'assets pour T3/T4).
2. `swift test` sur `MonobsKit` — 191 tests existants verts **inchangés** + nouveaux tests verts. Tout test existant modifié = rejet du diff (I9).
3. Build Release sur Mac sans warning (dont zéro warning d'icône après T4).
4. Diff contenu dans la liste de fichiers de la tranche — tout écart = rejet.

### Avant la release v1 (dans cet ordre)

1. Gates de commit tous verts à HEAD, CI (`monobskit.yml`, `t-priv.yml`, `report-contract.yml`) verte.
2. `docs/checklist-rendu-v1.md` complète : entrées datées CAP-2, CAP-3, CAP-6, CAP-10, résultats consignés, committée (T11).
3. Compat descendante CAP-10 : un `hosts.toml` d'époque v0.2.0 (avec commentaires) lu à l'identique ; jamais écrasé sans action d'édition explicite.
4. Démo CAP-1 : Quitter depuis la barre de menu → zéro process Monobs résiduel.
5. Asset de release : en-tête Mach-O du binaire dans `Monobs.zip` **publié** = fat `arm64`+`x86_64` (CAP-9).
6. Démarrage démontré sur une machine Apple Silicon **et** une machine Intel, installation suivant le README verbatim, exécution depuis `/Applications` (CAP-4/CAP-9).
7. Notes de release : SHA-256 de `Monobs.zip` publié, vérification présentée comme optionnelle (CAP-4).
8. Désinstallation rejouée en suivant `README.md` : aucun résidu, aucun élément de barre de menu (CAP-5).
