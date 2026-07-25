# Monobs v1 — point de reprise (2026-07-25)

**Pour reprendre : lis ce fichier, puis `docs/specs/spec-monobs-v1/PLAN.md`.**

## Où on en est

Release **v0.2.0 publiée** (thème Braise + âge honnête). Chantier en cours = **v1 « app finie et partageable »**.

SPEC validée : `docs/specs/spec-monobs-v1/SPEC.md` — 10 capacités, PASS/PASS, zéro question ouverte.
Plan d'exécution : `docs/specs/spec-monobs-v1/PLAN.md` — 12 tranches en 3 vagues, fichiers disjoints (vérifié par programme).

## État des tranches

| Tranche | État | Preuve |
|---|---|---|
| T1 plancher macOS 14 | ✅ écrit | 4/4 `MACOSX_DEPLOYMENT_TARGET`, 0 reste de 13.0 |
| T4 icône (10 tailles) | ✅ écrit | fait par Hermes (Pillow), tailles vérifiées, 0 métadonnée, t-priv PASS |
| T5 doc install/désinstall + checklist | ✅ écrit | `README.md`, `docs/checklist-rendu-v1.md` |
| T6 script release universelle | ✅ écrit | `scripts/build-release.sh`, `docs/release-process.md` |
| T7 garde API d'âge | ✅ écrit | `tieredIfInDomain()` + `AgeFormattingGuardTests.swift` |
| T8 writer TOML | ✅ écrit | `HostConfigWriter.swift` + 363 l de tests |
| **T2 Quitter + accessibilité** | ✅ écrit + prouvé Mac | `bmad/t2_result.json` + 226 tests + build Release |
| **T9 reload polling à chaud** | ✅ écrit + prouvé Mac | `bmad/t9_result.json` + 226 tests + build Release |
| T3 glyphe barre de menu | ↪️ reporté v2 | choix de continuité v1 : garder le symbole système pour débloquer T10 |
| T10 écran de réglages (CAP-10) | ✅ écrit + prouvé Mac | `Monobs/SettingsContent.swift` + `SettingsRuntimeIntegrationTests.swift` ; 230 tests + build Release |
| T11 checklist de rendu sur Mac | ⬜ humain | |
| T12 release v1 | ⬜ humain | |

**Preuve Mac lot v1 A+B : VERTE (2026-07-25 22:32 Mac).** `swift test` MonobsKit : 226 tests, 0 échec. Build Release `Monobs` : `BUILD SUCCEEDED`. Binaire app + widget : `x86_64 arm64` confirmés par `lipo -archs`.

**Preuve Mac T10 : VERTE (2026-07-25 22:52 Mac).** Copie `~/Desktop/projet/perso/monobs` : `swift test` MonobsKit : 230 tests, 0 échec. Build Release `Monobs` : `BUILD SUCCEEDED`. Binaire app : `x86_64 arm64` confirmé par `lipo -archs`. Correctif controller appliqué après Amelia : ajout `import Combine` dans `SettingsContent.swift`.

Le VPS est Linux : toute nouvelle tranche Swift reste à reprouver sur le Mac.

## Contrat de continuation — à ne pas redemander

- Ne pas annoncer vert tant que le Mac n'a pas relancé `swift test` MonobsKit + build Release.
- Vérifier les claims agents sur disque et par commandes fraîches ; un `exit 0` de worker n'est pas une preuve produit.
- Continuer en mode autonome sur les gates verts ; remonter seulement les blocages rouges et arbitrages produit.
- Ne jamais sync avec suppression (`rsync --delete`) ni toucher un dossier existant sans go explicite ; pour la preuve Mac, utiliser un dossier neuf dédié.
- T10 ne démarre pas tant que T2/T9 ne sont pas prouvés et tant que T3 n'est pas arbitré.

## Décision produit actée pour continuer

**T3 — glyphe de barre de menu : report v2.** Les 24 frames de `~/work/forge/monobs/icon-d2/glyph-frames/` ne fonctionnent qu'ANIMÉES. Rendues à 16 px, nominal et incident sont le même anneau : la seule différence est un halo imperceptible à cette taille. L'animation ayant été retirée en v1, le signal est vide.

Choix de continuité v1 : **garder le symbole système**, ne pas intégrer un glyphe custom faible, et débloquer T10. La vraie forme d'incident part en v2.

## Invariants (rejet du diff sinon)

I1 macOS 14 · I2 zéro dépendance externe · I3 read-only serveurs · I4 repo public + `scripts/t-priv` bloquant · I5 pas de signature Apple (jamais promettre le double-clic) · I6 binaire release universel arm64+x86_64 · I7 âge toujours arrondi au supérieur · I8 aucune surface animée · I9 jamais modifier un test existant · I10 un worker ne touche que les fichiers de sa tranche.

## Routage modèle — règle gravée

Source globale : le `CLAUDE.md` du VPS, section « ÉCONOMIE DE TOKENS ». Pour Monobs v1 :

- Le modèle se choisit par **difficulté**, pas par prestige ni par défaut.
- `claude-haiku-4-5` : lecture, résumé, ping, health-check, parse, validation simple.
- `claude-sonnet-4-6` : défaut pour mécanique standard, tests, docs, adaptateurs, scripts courts, refacto simple.
- `claude-opus-5` : seulement risqué/subtil — archi, review adversarial, SPEC, sécurité, debug non trivial, craft produit.
- `claude-fable-5` : orchestration uniquement, prompts courts ; jamais exécutant, jamais test, jamais ping.
- Ne pas relancer un agent si l'artifact sur disque suffit ; lire et vérifier d'abord.
- `--max-turns` serré au besoin réel ; passer les faits connus dans le prompt au lieu de refaire scanner le repo.
- Router seul avec les bons skills + bons modèles ; ne remonter que les arbitrages produit et gates rouges.

## Visuel X

`~/work/forge/monobs/posts/post-agents-violet.png` — validé (violet). Variantes teal/cosmos/orange dans le même dossier.
