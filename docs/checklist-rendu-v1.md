# Checklist de preuve de rendu — Monobs v1

Template de **preuve de rendu manuelle** (question Q3 tranchée : checklist signée, pas de
cible de tests UI). Aucune preuve de rendu ne peut sortir de la CI — le VPS d'intégration
est Linux, sans toolchain de build macOS. Ces vérifications se font **à la main sur un Mac**,
sur l'application **réellement installée** (T11 du plan).

## Comment remplir

- Une entrée par **capacité visuelle** : CAP-2, CAP-3, CAP-6, CAP-10.
- Chaque passage remplit une **ligne datée** — ne pas pré-cocher les résultats.
- **Famille de machine** : « Apple Silicon » ou « Intel » uniquement. Ne jamais écrire le
  nom réel de la machine, son nom d'hôte, ou un nom d'utilisateur (repo public, lint T-PRIV
  bloquant).
- **Verdict** : `PASS` / `FAIL`. Un `FAIL` bloque la release ; consigner l'observation.
- Idéalement, chaque CAP est rejouée sur **une machine de chaque famille** (Apple Silicon et
  Intel) — ajouter autant de lignes que nécessaire.

---

## CAP-2 — Icône d'application présente partout

L'icône Monobs doit apparaître dans **Finder**, **Dock** (au lancement), **Spotlight**, et la
fenêtre **À propos**. Vérifier les quatre emplacements pour chaque ligne.

| Date | Famille (Apple Silicon / Intel) | Version macOS | Emplacement vérifié (Finder / Dock / Spotlight / À propos) | Résultat observé | Verdict |
|------|--------------------------------|---------------|------------------------------------------------------------|------------------|---------|
|      |                                |               |                                                            |                  |         |
|      |                                |               |                                                            |                  |         |
|      |                                |               |                                                            |                  |         |
|      |                                |               |                                                            |                  |         |

---

## CAP-3 — Glyphe de barre de menu (deux formes)

Le glyphe de barre de menu doit présenter **deux formes distinguables à l'œil** — une forme
**nominale** et une forme **incident** — et **suivre l'état réel** de l'agrégat (bascule quand
la flotte passe en incident, revient quand elle récupère).

| Date | Famille (Apple Silicon / Intel) | Version macOS | Forme observée (nominale / incident) | Suit l'état réel ? | Résultat observé | Verdict |
|------|--------------------------------|---------------|--------------------------------------|--------------------|------------------|---------|
|      |                                |               |                                      |                    |                  |         |
|      |                                |               |                                      |                    |                  |         |
|      |                                |               |                                      |                    |                  |         |

---

## CAP-6 — Lisibilité sous réglages d'accessibilité

Vérifier la lisibilité des surfaces avec chaque réglage **activé** (Réglages Système →
Accessibilité → Affichage). Une ligne par réglage actif.

| Date | Famille (Apple Silicon / Intel) | Version macOS | Réglage actif (Réduire la transparence / Augmenter le contraste) | Résultat observé (fond, contours, texte lisibles ?) | Verdict |
|------|--------------------------------|---------------|------------------------------------------------------------------|-----------------------------------------------------|---------|
|      |                                |               | Réduire la transparence                                          |                                                     |         |
|      |                                |               | Augmenter le contraste                                           |                                                     |         |
|      |                                |               | Réduire la transparence                                          |                                                     |         |
|      |                                |               | Augmenter le contraste                                           |                                                     |         |

---

## CAP-10 — Premier lancement sans configuration → ajout d'un hôte depuis l'app

Parcours complet, sur une machine **sans** `~/.config/monobs/hosts.toml` préexistant :
premier lancement → l'app guide vers l'ajout d'un hôte → ajout depuis l'interface → la
surveillance démarre **sans relancer l'app**.

| Date | Famille (Apple Silicon / Intel) | Version macOS | Config préexistante ? (oui/non) | Étape (premier lancement guidé / ajout d'hôte / polling démarre sans relance) | Résultat observé | Verdict |
|------|--------------------------------|---------------|---------------------------------|-------------------------------------------------------------------------------|------------------|---------|
|      |                                |               |                                 | Premier lancement guide vers l'ajout                                           |                  |         |
|      |                                |               |                                 | Ajout d'un hôte depuis l'app                                                   |                  |         |
|      |                                |               |                                 | Surveillance démarre sans relancer l'app                                       |                  |         |

---

## Signature de rendu

| Version | Date de complétion | Machines couvertes (familles) | Toutes CAP en PASS ? | Signé par |
|---------|--------------------|-------------------------------|----------------------|-----------|
| v1      |                    |                               |                      |           |
