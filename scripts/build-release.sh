#!/usr/bin/env bash
#
# build-release.sh — build the Release configuration of Monobs, PROVE the produced
# binary is a universal (arm64 + x86_64) Mach-O, package it, and print the SHA-256
# of the zip for the release notes.
#
# RUN THIS ON A MAC. It needs the macOS toolchain (xcodebuild, lipo, ditto,
# shasum) — it cannot run on the Linux CI host.
#
# Why this script exists: v0.2.0 shipped a thin arm64 binary that a Mac Intel
# cannot launch, and nobody noticed. This script makes that defect impossible to
# publish: if the built binary is not universal, it FAILS before any zip is made
# (invariant I6).

set -euo pipefail

# --- Locations (all local to the repo — no absolute machine paths) -------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT="${REPO_ROOT}/Monobs.xcodeproj"
SCHEME="Monobs"
CONFIGURATION="Release"
BUILD_DIR="${REPO_ROOT}/build"          # local build output — the only path we delete
PRODUCT_DIR="${BUILD_DIR}/Build/Products/${CONFIGURATION}"
APP="${PRODUCT_DIR}/Monobs.app"
APP_BINARY="${APP}/Contents/MacOS/Monobs"
ZIP="${BUILD_DIR}/Monobs.zip"

REQUIRED_ARCHS=(arm64 x86_64)

# --- Helpers -------------------------------------------------------------------
step()  { printf '\n==> %s\n' "$1"; }
info()  { printf '    %s\n' "$1"; }
fail()  { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

# assert_universal <mach-o binary path> <human label>
# Fails (non-zero exit) unless BOTH arm64 and x86_64 are present.
assert_universal() {
    local binary="$1" label="$2" archs missing=()
    [ -f "${binary}" ] || fail "${label}: binary not found at ${binary}"

    archs="$(lipo -archs "${binary}")" || fail "${label}: lipo could not read ${binary}"
    info "${label} architectures: ${archs}"

    local a
    for a in "${REQUIRED_ARCHS[@]}"; do
        case " ${archs} " in
            *" ${a} "*) ;;
            *) missing+=("${a}") ;;
        esac
    done

    if [ "${#missing[@]}" -ne 0 ]; then
        fail "${label} is NOT universal — missing: ${missing[*]} (found: ${archs}). \
Refusing to package. This is the v0.2.0 defect (I6): a mono-architecture binary \
will not launch on the missing family."
    fi
    info "${label}: universal OK (${REQUIRED_ARCHS[*]})"
}

# --- Preconditions -------------------------------------------------------------
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found — run this on a Mac."
command -v lipo       >/dev/null 2>&1 || fail "lipo not found — run this on a Mac."
command -v ditto      >/dev/null 2>&1 || fail "ditto not found — run this on a Mac."
command -v shasum     >/dev/null 2>&1 || fail "shasum not found — run this on a Mac."
[ -d "${PROJECT}" ] || fail "project not found at ${PROJECT}"

# --- Clean the local build directory (explicit, local, non-destructive elsewhere)
step "Cleaning local build directory: ${BUILD_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# --- Build the Release configuration, forcing a universal build ----------------
step "Building ${SCHEME} (${CONFIGURATION}) as a universal binary"
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${BUILD_DIR}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

[ -d "${APP}" ] || fail "build finished but ${APP} is missing"

# --- Prove the produced binaries are universal (BLOCKING gate) -----------------
step "Verifying architectures (blocking gate — I6)"
assert_universal "${APP_BINARY}" "Monobs.app main binary"

# Embedded extensions must match the app so the whole bundle runs on both families.
while IFS= read -r appex; do
    [ -n "${appex}" ] || continue
    name="$(basename "${appex}" .appex)"
    assert_universal "${appex}/Contents/MacOS/${name}" "${name}.appex"
done < <(find "${APP}/Contents/PlugIns" -maxdepth 1 -name '*.appex' 2>/dev/null || true)

# --- Package -------------------------------------------------------------------
step "Packaging ${ZIP}"
# ditto preserves the .app bundle structure and resource forks correctly (a plain
# `zip` mangles macOS bundles).
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"
[ -f "${ZIP}" ] || fail "packaging failed — ${ZIP} not produced"
info "created ${ZIP}"

# --- Checksum for the release notes --------------------------------------------
step "SHA-256 of the published asset (paste this into the release notes)"
shasum -a 256 "${ZIP}"

step "Done."
info "Universal build verified and packaged: ${ZIP}"
info "Recette (T12): re-verify the architectures on the asset DOWNLOADED from the"
info "release, not on this working tree — see docs/release-process.md."
