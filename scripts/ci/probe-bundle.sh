#!/usr/bin/env bash
# Release gate for a packaged Vips-Native prebuilt archive, run by each
# macOS and Linux job in build-binaries.yml after it packages:
#
#     bash scripts/ci/probe-bundle.sh <archive.tar.gz> <binary-tag> [<work-dir>]
#
# Extracts the archive exactly where and how Build.rakumod stages it
# (<data>/Vips-Native/<binary-tag>/lib/), sets the environment
# FFI.rakumod sets for a staged bundle (VIPSHOME at the staged lib
# directory, where libvips finds vips-modules-<M>.<m>/ directly or through
# the bundle's lib/ link; GIO_MODULE_DIR at a path that cannot exist),
# with no loader search variables left over from the build, then
# compiles and runs scripts/ci/vips-loader-probe.c against the staged
# libvips. The probe fails unless every loader — including
# heif, jxl, openslide and pdf, which live in the dlopen'd modules —
# decodes a real file, ImageMagick's magickload is absent (these packs
# leave its module out), and nothing loaded from outside the stage. See
# vips-loader-probe.c.
#
# Without <work-dir> the work happens in a temporary directory that is
# removed afterwards; with it, everything is left there to inspect.
#
# Written for bash 3.2 (macOS's /bin/bash).
set -euo pipefail

fail() {
    echo "::error::$*" >&2
    echo "❌ $*" >&2
    exit 1
}

[[ $# -eq 2 || $# -eq 3 ]] || fail "usage: $0 <archive.tar.gz> <binary-tag> [<work-dir>]"
ARCHIVE=$1
TAG=$2
[[ -f "$ARCHIVE" ]] || fail "no archive at $ARCHIVE"
[[ -n "$TAG" ]] || fail "empty binary tag"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE_SRC="$REPO_ROOT/scripts/ci/vips-loader-probe.c"

if [[ $# -eq 3 ]]; then
    WORK=$3
    [[ ! -e "$WORK" ]] || [[ -d "$WORK" && -z "$(ls -A "$WORK")" ]] \
        || fail "$WORK exists and is not an empty directory."
    mkdir -p "$WORK"
else
    WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vips-probe.XXXXXX")
    trap 'rm -rf "$WORK"' EXIT
fi
WORK="$(cd "$WORK" && pwd)"

case "$(uname -s)" in
    Darwin) LIBVIPS='libvips.42.dylib'; LDLIBS='' ;;
    Linux)  LIBVIPS='libvips.so.42';    LDLIBS='-ldl' ;;
    *)      fail "unsupported OS $(uname -s)" ;;
esac

STAGE="$WORK/data/Vips-Native/$TAG/lib"
mkdir -p "$STAGE" "$WORK/fixtures"
tar -xzf "$ARCHIVE" -C "$STAGE"
[[ -f "$STAGE/$LIBVIPS" ]] || fail "$ARCHIVE has no $LIBVIPS at its top level."
# The notices kit stages with the libraries (Build.rakumod refuses an
# archive without it); a pack must never ship without one.
[[ -f "$STAGE/THIRD-PARTY.md" && -f "$STAGE/LICENSES/GPL-3.0.txt" ]] \
    || fail "$ARCHIVE carries no THIRD-PARTY.md + LICENSES/ notices kit."

# shellcheck disable=SC2086  # LDLIBS is empty or one flag
cc -std=c99 -O2 -Wall -Wextra -o "$WORK/vips-loader-probe" "$PROBE_SRC" $LDLIBS

echo "--- probing $(basename "$ARCHIVE") staged at $STAGE ---"
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES \
    -u LD_LIBRARY_PATH -u LD_PRELOAD \
    VIPSHOME="$STAGE" \
    GIO_MODULE_DIR=/dev/null/vips-native-no-gio-modules \
    "$WORK/vips-loader-probe" "$STAGE/$LIBVIPS" "$STAGE" "$WORK/fixtures" \
    || fail "$(basename "$ARCHIVE") failed the loader probe — see the FAIL lines above."
echo "✅ $(basename "$ARCHIVE"): every loader decodes, nothing loaded from outside the bundle."
