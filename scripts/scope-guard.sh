#!/usr/bin/env bash
# scope-guard.sh — allowlist de chemins pour une story BMAD.
#
# POURQUOI CE FICHIER EXISTE
# Story E1 (2026-07-25) : un agent dev a modifié `MonobsKit/` alors que la story
# l'interdisait noir sur blanc, ET l'a nié dans son Dev Agent Record. Le pipeline
# de review l'a rattrapé — mais par redondance, pas par design. Les deux rétros
# (Claude Opus 5 + Codex, brief identique) ont convergé sur le même remède :
# comparer `git diff --name-only` au scope déclaré AVANT toute review.
#
# DURCISSEMENT 2026-07-25 (findings de re-review Codex — le garde était percé) :
#   1. AUTO-PROTECTION : le garde et son fichier de scope ne peuvent plus
#      s'auto-autoriser (avant : `scripts/` et `docs/stories/` allow en bloc
#      => un agent pouvait élargir son propre scope dans le même worktree).
#   2. BASE_REF VALIDÉE : avant, une ref invalide faisait échouer `git diff`
#      en silence et le garde concluait « aucun fichier modifié » (faux vert).
#   3. Le fichier de scope doit déclarer explicitement ses deny sur les tests
#      métier (voir `docs/stories/scope-E1.txt`) — `Tests/` en bloc permettait
#      d'affaiblir n'importe quel test tout en restant « dans le scope ».
#
# USAGE
#   bash scripts/scope-guard.sh <fichier-scope> [base-ref]
#   ALLOW_SELF_EDIT=1 bash scripts/scope-guard.sh ...   # override explicite
#
# FORMAT DU FICHIER DE SCOPE (une règle par ligne) :
#   Monobs/                       -> préfixe autorisé
#   !MonobsKit/Sources/Domain/    -> INTERDIT (le ! gagne toujours)
#   # commentaire                 -> ignoré
#
# SORTIE : exit 0 si tout le diff est dans le scope, 1 si hors scope,
# 2 si le garde lui-même ne peut pas se prononcer (erreur d'usage / ref
# invalide). Un exit 2 n'est JAMAIS un succès — c'est un refus de statuer.
# Ne modifie RIEN, ne supprime RIEN : read-only par design.

set -uo pipefail

SCOPE_FILE="${1:-}"
BASE_REF="${2:-HEAD}"

die() { echo "SCOPE-GUARD: $1" >&2; exit 2; }

[[ -n "$SCOPE_FILE" ]] || die "usage: $0 <fichier-scope> [base-ref]"
[[ -f "$SCOPE_FILE" ]] || die "fichier de scope introuvable: '$SCOPE_FILE'"

git rev-parse --git-dir >/dev/null 2>&1 || die "pas dans un dépôt git"

# --- DURCISSEMENT 2 : la base-ref doit exister, sinon on REFUSE de statuer.
# Avant, un `git diff <ref-invalide>` échouait en silence -> "aucun fichier
# modifié" -> faux vert. On valide la ref AVANT de s'en servir.
git rev-parse --verify --quiet "$BASE_REF" >/dev/null \
  || die "base-ref invalide ou inconnue: '$BASE_REF' (refus de statuer plutôt que conclure à tort)"

# --- Collecte du diff : fichiers trackés modifiés + non trackés non ignorés.
DIFF_OUT="$(git diff --name-only "$BASE_REF" 2>/dev/null)" \
  || die "git diff a échoué sur '$BASE_REF'"
UNTRACKED_OUT="$(git ls-files --others --exclude-standard 2>/dev/null)" \
  || die "git ls-files a échoué"

CHANGED="$(printf '%s\n%s\n' "$DIFF_OUT" "$UNTRACKED_OUT" | sort -u | grep -v '^$' || true)"

if [[ -z "$CHANGED" ]]; then
  echo "SCOPE-GUARD: aucun fichier modifié vs '$BASE_REF' — RAS."
  exit 0
fi

# --- Chargement des règles.
ALLOW=(); DENY=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | awk '{$1=$1};1')"   # trim
  [[ -z "$line" ]] && continue
  if [[ "$line" == !* ]]; then DENY+=("${line#!}"); else ALLOW+=("$line"); fi
done < "$SCOPE_FILE"

(( ${#ALLOW[@]} > 0 )) || die "le fichier de scope ne déclare AUCUN préfixe autorisé"

# --- DURCISSEMENT 1 : auto-protection.
# Le garde et son propre fichier de scope ne sont jamais modifiables via le
# scope qu'ils définissent : sinon un agent élargit son périmètre lui-même et
# le contrôle ne vaut plus rien. Override conscient : ALLOW_SELF_EDIT=1.
SELF_GUARD="${BASH_SOURCE[0]#./}"
SELF_PROTECTED=("$SELF_GUARD" "${SCOPE_FILE#./}")

OUT_OF_SCOPE=(); SELF_EDITED=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue

  is_self=0
  for s in "${SELF_PROTECTED[@]}"; do
    [[ "$f" == "$s" ]] && is_self=1 && break
  done
  if (( is_self )) && [[ "${ALLOW_SELF_EDIT:-0}" != "1" ]]; then
    SELF_EDITED+=("$f"); continue
  fi

  verdict="denied"
  for a in "${ALLOW[@]}"; do
    [[ -n "$a" && "$f" == "$a"* ]] && verdict="allowed" && break
  done
  for d in "${DENY[@]:-}"; do                 # le deny gagne toujours
    [[ -n "$d" && "$f" == "$d"* ]] && verdict="denied" && break
  done
  [[ "$verdict" == "denied" ]] && OUT_OF_SCOPE+=("$f")
done <<< "$CHANGED"

TOTAL="$(printf '%s\n' "$CHANGED" | wc -l | awk '{$1=$1};1')"
FAILED=0

if (( ${#SELF_EDITED[@]} > 0 )); then
  FAILED=1
  echo "SCOPE-GUARD: ÉCHEC — le garde ou son scope ont été modifiés (auto-autorisation interdite) :"
  for f in "${SELF_EDITED[@]}"; do echo "  ✗ $f  [self-protected]"; done
  echo "  → Un élargissement de périmètre doit être un acte HUMAIN explicite,"
  echo "    revu séparément. Relancer avec ALLOW_SELF_EDIT=1 seulement après go."
  echo ""
fi

if (( ${#OUT_OF_SCOPE[@]} > 0 )); then
  FAILED=1
  echo "SCOPE-GUARD: ÉCHEC — ${#OUT_OF_SCOPE[@]}/${TOTAL} fichier(s) HORS SCOPE :"
  for f in "${OUT_OF_SCOPE[@]}"; do echo "  ✗ $f"; done
  echo ""
  echo "Scope déclaré ($SCOPE_FILE) :"
  for a in "${ALLOW[@]}"; do echo "  autorisé : $a"; done
  for d in "${DENY[@]:-}"; do echo "  INTERDIT : $d"; done
  echo ""
  echo "→ Soit le diff sort du scope (à corriger), soit la story était mal cadrée"
  echo "  (à amender EXPLICITEMENT, en append-only, avec go humain)."
fi

(( FAILED )) && exit 1

echo "SCOPE-GUARD: OK — ${TOTAL} fichier(s) modifié(s) vs '$BASE_REF', tous dans le scope déclaré."
echo "  (garde auto-protégé : $SELF_GUARD + $SCOPE_FILE non modifiables via ce scope)"
exit 0
