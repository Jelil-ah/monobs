# Distribution, installation et désinstallation — Monobs v1

Companion de `SPEC.md`. Porte CAP-4 (installation guidée), CAP-5 (désinstallation propre) et CAP-9 (distribution universelle).

## Le problème observé

Le README ne documente **pas** l'installation (aucune mention de `install`, `zip` ou clic droit). Conséquence constatée sur le Mac de travail :

| Symptôme | Cause |
|---|---|
| L'app tournait depuis `/private/var/folders/.../AppTranslocation/...` | Lancée **depuis le zip** au lieu d'être copiée d'abord → macOS l'a mise en quarantaine et exécutée dans une copie translocatée en lecture seule |
| Deux copies concurrentes (`/Applications` + Bureau) | Aucun geste d'installation canonique documenté |

Ce n'est pas un bug de code : c'est le comportement normal de Gatekeeper face à une app **non signée** téléchargée depuis Internet. La v1 vit avec cette contrainte (pas de compte développeur Apple payant) et la documente au lieu de la contourner.

## Le défaut de distribution : binaire mono-architecture (CAP-9)

L'en-tête Mach-O de l'asset **réellement publié en v0.2.0** a été lu octet par octet :

| Constat | Valeur |
|---|---|
| Magic | `0xcffaedfe` |
| Type | **Thin binary** — pas un fat binary |
| Architecture | **`arm64` uniquement** |

Or le parc comporte un **Mac Intel** (`x86_64`), utilisé comme machine de test. L'app publiée **refuse de s'y lancer**, ou dépendrait d'une couche de traduction indisponible dans ce sens. Défaut réel, pas théorique : une release qui ne démarre pas sur une des machines cibles n'est pas « finie ».

**v1 publie un binaire universel** contenant `arm64` **et** `x86_64`. Un build mono-architecture limité à celle de la machine de build est exclu — c'est exactement ce qui a produit le thin `arm64`.

Critère de recette : lire l'en-tête Mach-O de l'asset publié et y constater un fat binary avec les deux architectures, puis démontrer le démarrage sur au moins une machine de chaque famille.

## Le geste à documenter (CAP-4)

Ordre obligatoire — l'inversion des étapes 2 et 3 est exactement ce qui a produit la translocation :

1. Télécharger `Monobs.zip` depuis la page de release GitHub.
2. Décompresser, puis **glisser `Monobs.app` dans `/Applications`** — avant tout lancement.
3. **Clic droit sur l'app → Ouvrir**, puis confirmer dans la boîte de dialogue. Un double-clic simple sera refusé par macOS : l'app n'est ni signée ni notarisée.
4. Les lancements suivants se font normalement.

Le README doit nommer explicitement le piège : lancer l'app depuis le zip la fait tourner en quarantaine depuis un chemin temporaire, avec des comportements imprévisibles.

## Intégrité du téléchargement : checksum SHA-256

Les notes de release publient le **checksum SHA-256 de `Monobs.zip`**. Justification : l'app n'étant ni signée ni notarisée, le checksum est le seul moyen offert à l'utilisateur de vérifier que son téléchargement est intact. Coût de production nul.

Nuance assumée : comparer un checksum sur macOS passe par un terminal, ce que le parcours nominal exclut. La vérification est donc **optionnelle et hors du chemin d'installation** — proposée à qui la veut, jamais présentée comme une étape obligatoire.

## La désinstallation à documenter (CAP-5)

**Documentation seule — v1 ne livre pas de script.** Le geste a été exécuté à la main en moins d'une minute (arrêt du process, puis déplacement des deux copies) ; l'outiller serait de l'abstraction prématurée pour un besoin ponctuel.

La doc doit lister **chaque** emplacement écrit par Monobs et le geste associé, y compris le cas des copies multiples déjà observé. Après application, il ne doit rester ni binaire, ni élément de barre de menu, ni résidu. Critère de rédaction : Jelil, non-développeur, doit pouvoir l'exécuter sans terminal.

## Contraintes portées

- Repo public + lint CI `scripts/t-priv` bloquant : la documentation d'installation ne cite **aucun** chemin de machine de dev ni identifiant d'infra réel. Les machines sont désignées par famille — « Mac Apple Silicon », « Mac Intel ».
- Pas de signature ni de notarisation : ne jamais promettre un double-clic qui fonctionne au premier lancement.
- Pas d'auto-update in-app : la mise à jour se fait en refaisant le geste d'installation sur la nouvelle release.
