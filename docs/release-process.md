# Processus de release — Monobs

Cette procédure produit et publie une release universelle de Monobs. Elle **doit
s'exécuter sur un Mac** : le VPS d'intégration continue est Linux, sans toolchain
de build macOS (pas de `xcodebuild`, pas de `lipo`). Aucune preuve de rendu ni
d'architecture ne peut donc sortir de la CI.

## Invariant qui gouverne cette procédure

**I6 — Le binaire publié doit être universel `arm64` + `x86_64`.** La v0.2.0 a
livré un binaire thin `arm64` : un Mac Intel ne peut pas le lancer, et le défaut
est passé inaperçu. Le critère de recette ci-dessous rend ce défaut **impossible à
publier**.

## 1. Construire et empaqueter (sur un Mac)

```sh
./scripts/build-release.sh
```

Le script :

1. construit la configuration **Release** de l'app en forçant `ARCHS="arm64 x86_64"`
   et `ONLY_ACTIVE_ARCH=NO` ;
2. **vérifie que le binaire produit est universel** en lisant ses architectures
   (`lipo -archs`) et **échoue immédiatement (exit non nul)** si `arm64` ou
   `x86_64` manque — sur le binaire principal **et** sur l'extension widget
   embarquée ;
3. empaquette `Monobs.app` dans `build/Monobs.zip` (via `ditto`, qui préserve la
   structure du bundle) ;
4. affiche le **SHA-256** de `Monobs.zip`, à coller dans les notes de release.

Si le script échoue à l'étape 2, **ne rien publier** : le build n'est pas
universel, corriger avant tout (cf. réglages `ONLY_ACTIVE_ARCH` / `ARCHS` en
Release dans `Monobs.xcodeproj/project.pbxproj`).

## 2. Publier

1. Créer la release sur GitHub (tag de version).
2. Y attacher `build/Monobs.zip`.
3. Coller le **SHA-256** affiché par le script dans les notes de release, en le
   présentant comme une **vérification optionnelle** pour l'utilisateur (hors du
   chemin d'installation nominal — cf. `README.md`).

## 3. Critère de recette — sur l'asset PUBLIÉ, pas sur l'arbre de travail

La preuve se fait sur **l'asset réellement téléchargé depuis la release**, jamais
sur le `build/Monobs.zip` local : c'est le seul moyen de garantir que ce qui est
publié est bien ce qui a été vérifié.

1. **Télécharger** `Monobs.zip` depuis la page de la release GitHub.
2. **Décompresser** et **relire l'en-tête Mach-O** du binaire de l'app pour
   confirmer qu'il est universel :

   ```sh
   unzip Monobs.zip
   lipo -archs Monobs.app/Contents/MacOS/Monobs      # doit afficher : arm64 x86_64
   file  Monobs.app/Contents/MacOS/Monobs            # doit mentionner deux architectures
   ```

   Les deux architectures **doivent** être présentes. Sinon, la release est
   invalide : la dépublier.
3. **(Optionnel)** vérifier le SHA-256 du zip téléchargé :

   ```sh
   shasum -a 256 Monobs.zip   # doit correspondre à la valeur des notes de release
   ```

## 4. Démarrage démontré sur chaque famille de machine

Installer et lancer l'app **en suivant `README.md` verbatim** sur :

- une machine **Apple Silicon**, et
- une machine **Intel**.

Sur chaque famille, confirmer que l'app :

- s'installe depuis `/Applications` (copiée **avant** ouverture — jamais depuis un
  emplacement en quarantaine `AppTranslocation`) ;
- démarre au premier lancement via **clic droit → Ouvrir** (app non signée, I5) ;
- affiche son glyphe de barre de menu et poll les hôtes configurés.

> Convention de confidentialité (repo public, lint T-PRIV bloquant) : désigner les
> machines par **famille** (« un Mac Apple Silicon », « un Mac Intel »), jamais par
> leur nom d'hôte, nom de machine ou nom d'utilisateur réels. Pour les exemples,
> utiliser des valeurs de documentation (`example.com`, `192.0.2.x`).

## Rappel des gates de release

Les gates complets (checklist de rendu, compat descendante CAP-10, démo CAP-1,
etc.) sont listés dans `docs/specs/spec-monobs-v1/PLAN.md`, section « Avant la
release v1 ». Le présent document couvre spécifiquement CAP-9 (build universel +
recette sur l'asset publié) et le volet CAP-4 lié au démarrage par famille.
