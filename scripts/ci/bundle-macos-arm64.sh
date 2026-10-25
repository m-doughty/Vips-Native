#!/usr/bin/env bash
# Build Vips-Native's macOS arm64 prebuilt bundle from conda-forge's
# libvips. build-binaries.yml's build-macos job runs it; it runs the
# same way on an Apple Silicon Mac:
#
#     VIPS_VERSION=8.18.7 bash scripts/ci/bundle-macos-arm64.sh bundle
#
# In order:
#
#   1. Fetch micromamba — a pinned static binary, SHA-256 checked — into
#      $WORK_DIR. No Homebrew: its libvips bottle tracks the newest macOS
#      only (8.18.7 shipped for macOS 26 alone), which would set the
#      bundle's floor to whatever Apple released last.
#   2. Create a conda prefix holding conda-forge's osx-arm64 libvips at the
#      pinned version AND build string. Link scripts are skipped: the
#      bundle uses none of what they generate (gdk-pixbuf's loader cache,
#      graphviz's plugin config).
#   3. Copy libvips.42.dylib and its dlopen'd format modules
#      (vips-modules-<M>.<m>/: heif, jxl, openslide, poppler) out of the
#      prefix, and walk every load command recursively, copying each
#      dependency beside libvips and pointing the reference at the copy:
#      @loader_path/<lib> from a top-level library, @loader_path/../<lib>
#      from a module (they live one directory down). Every LC_RPATH is
#      dropped — nothing is left to search for. The module directory
#      keeps its versioned name, because that is the name libvips looks
#      for at run time (see the lib/ link below for where it looks).
#      The ImageMagick module (vips-magick) is left out, and with it
#      everything only it links: ImageMagick's libraries, and Graphviz,
#      whose EPL-1.0 does not sit with the GPL code (FFTW, poppler) in the
#      same pack on the FSF's reading (see EXCLUDED_MODULES).
#   4. Compile the varargs shim (src/vips_native_shim.c) against the
#      bundle, check it exports every vips_shim_* the source defines,
#      and write the .srchash sidecar Build.rakumod's freshness check
#      reads.
#   5. Ad-hoc sign every Mach-O file (install_name_tool invalidates the
#      linker's signature, and arm64 macOS kills a process that maps an
#      unsigned page).
#   6. Audit the result and fail on anything that would make the bundle
#      load code from outside itself, or refuse to load on a supported
#      macOS: every Mach-O file arm64 only, minos <= $MIN_MACOS, every
#      reference either a system library (/usr/lib, /System) or an
#      @loader_path path that resolves inside the bundle, no LC_RPATH,
#      install names self-referential, signatures valid — and nothing of
#      ImageMagick or Graphviz in it (FORBIDDEN_LIBS).
#   7. Write the notices kit — THIRD-PARTY.md + LICENSES/ — attributing
#      every bundled file to the conda package it came from
#      (scripts/ci/third-party.py), and fail if any file can't be.
#
# A conda-forge package occasionally links a library by its BUILD
# machine's absolute path instead of @rpath — libheif 1.23.5 for
# osx-arm64 links /opt/homebrew/opt/webp/lib/libsharpyuv.0.dylib, which
# exists only on a Mac with Homebrew's webp installed. Such a reference is
# relinked to the prefix's library of the same name, and only when that
# library's compatibility version is at least the one the reference
# records (exactly the check dyld itself makes); each one is reported as
# a GitHub warning so the upstream bug stays visible.
#
# Inputs:
#   $1             bundle directory to create (must not exist, or be empty)
#   VIPS_VERSION   libvips version; must equal the pinned one below
#   BINARY_TAG     the release tag the bundle is for (named in THIRD-PARTY.md)
#   WORK_DIR       micromamba + conda prefix (default: ./_ci-work/macos-arm64).
#                  A prefix already holding the pinned libvips build is
#                  reused, so a local re-run doesn't re-download it.
#
# Written for bash 3.2 (macOS's /bin/bash): no associative arrays, no
# empty-array expansions.
set -euo pipefail

fail() {
    echo "::error::$*" >&2
    echo "❌ $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || fail "usage: VIPS_VERSION=<version> $0 <bundle-dir>"
VIPS_VERSION="${VIPS_VERSION:?VIPS_VERSION must be set (parsed from BINARY_TAG)}"
BINARY_TAG="${BINARY_TAG:?BINARY_TAG must be set}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHIM_SRC="$REPO_ROOT/src/vips_native_shim.c"
WORK_DIR="${WORK_DIR:-$PWD/_ci-work/macos-arm64}"

# --- Pins ------------------------------------------------------------
#
# micromamba: https://github.com/mamba-org/micromamba-releases — the
# SHA-256 is the one upstream publishes beside the binary
# (micromamba-osx-arm64.sha256), cross-checked against the downloaded
# file.
MICROMAMBA_VERSION='2.9.0-0'
MICROMAMBA_SHA256='ec2a072f028e1a7cf20f3e2e74d5a8127cf5a5f27636375b5359811565f4e5be'
MICROMAMBA_URL="https://github.com/mamba-org/micromamba-releases/releases/download/${MICROMAMBA_VERSION}/micromamba-osx-arm64"

# conda-forge's libvips, by version AND build string, so a rebuild of
# the same version cannot slip in unnoticed. Bump both with BINARY_TAG:
#   micromamba search -c conda-forge --override-channels \
#       --platform osx-arm64 'libvips==<version>'
PINNED_VIPS_VERSION='8.18.7'
LIBVIPS_BUILD='h588ea66_0'

# conda-forge's libvips depends on ImageMagick, so the prefix holds it
# even though the bundle leaves it out (EXCLUDED_MODULES). conda-forge
# builds ImageMagick twice per version, identical but for the licence each
# declares: "agpl_*" builds (AGPL-3.0-only AND ImageMagick, because their
# recipe asks to link Ghostscript — which fails, falling back to the
# external `gs` command, so nothing AGPL is linked) and "imagemagick_*"
# builds (ImageMagick). The solver prefers the agpl_ builds by build
# number; take the ones whose declaration matches what the libraries are,
# so the environment THIRD-PARTY.md records is the one audited.
IMAGEMAGICK_SPEC='imagemagick=*=imagemagick_*'

# The floor the bundle promises (README "Supported platforms"). Every
# Apple Silicon Mac runs macOS 11 or later; conda-forge builds for
# exactly that.
MIN_MACOS='11.0'

# The loader modules the bundle must carry. A libvips that lost one
# still opens PNG and JPEG, so nothing else would notice.
MODULES='heif jxl openslide poppler'

# The loader modules the bundle must NOT carry, though conda-forge's
# libvips ships them. vips-magick links ImageMagick, which links Graphviz
# (EPL-1.0); on the FSF's reading the EPL-1.0 and the GPL are incompatible,
# and FFTW and poppler put GPL code in this same pack. Left out, with
# everything only it needed, the bundle has no magickload: files only
# ImageMagick reads (BMP, ICO, PSD, TGA, OpenEXR, ...) do not open.
EXCLUDED_MODULES='magick'

# Libraries the audit refuses to find in the bundle, by file name:
# ImageMagick's and Graphviz's (the latter EPL-1.0), whichever path might
# pull them back in.
FORBIDDEN_LIBS=('libMagick*' 'libcdt.*' 'libcgraph.*' 'libgvc.*' 'libgvpr.*' 'libpathplan.*'
    'libxdot.*' 'libgvplugin*')

# --- Preconditions ---------------------------------------------------

[[ "$VIPS_VERSION" == "$PINNED_VIPS_VERSION" ]] \
    || fail "BINARY_TAG asks for libvips $VIPS_VERSION, but this script pins \
conda-forge's $PINNED_VIPS_VERSION ($LIBVIPS_BUILD). Bump PINNED_VIPS_VERSION and \
LIBVIPS_BUILD together with BINARY_TAG."
[[ "$(uname -s)" == 'Darwin' && "$(uname -m)" == 'arm64' ]] \
    || fail "must run natively on arm64 macOS (got $(uname -s)/$(uname -m))."
[[ -f "$SHIM_SRC" ]] || fail "no shim source at $SHIM_SRC"

BUNDLE="$1"
if [[ -e "$BUNDLE" ]]; then
    [[ -d "$BUNDLE" && -z "$(ls -A "$BUNDLE")" ]] \
        || fail "$BUNDLE exists and is not an empty directory."
fi
mkdir -p "$BUNDLE"
BUNDLE="$(cd "$BUNDLE" && pwd)"

mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
PREFIX="$WORK_DIR/prefix"

# --- Helpers ---------------------------------------------------------

# install_name_tool and codesign, quiet on success: every edit makes
# install_name_tool warn that it invalidates the code signature (step 5
# re-signs), which would bury real output. On failure the full output is
# shown and the build stops.
quiet() {
    local out
    if ! out=$("$@" 2>&1); then
        printf '%s\n' "$out" >&2
        fail "$* failed."
    fi
}

# micromamba with HOME pointed into $WORK_DIR: it keeps a package-cache
# index under ~/.mamba even when told a root prefix, and nothing of this
# build belongs in the caller's home directory.
mm() {
    HOME="$WORK_DIR/home" "$MM" "$@"
}

# Follow a chain of symlinks to the file at its end.
resolve_file() {
    local p=$1 link
    while [[ -L "$p" ]]; do
        link=$(readlink "$p")
        case "$link" in
            /*) p=$link ;;
            *)  p="$(dirname "$p")/$link" ;;
        esac
    done
    printf '%s\n' "$p"
}

is_macho() {
    case "$(file -b "$1")" in
        Mach-O*) return 0 ;;
        *)       return 1 ;;
    esac
}

# Every library a Mach-O file asks dyld to load, one per line, from the
# load commands themselves (`otool -L` mixes in the file's own install
# name, which is not a dependency).
dylib_refs() {
    otool -l "$1" | awk '
        $1 == "cmd" { cmd = $2 }
        $1 == "name" && (cmd == "LC_LOAD_DYLIB" || cmd == "LC_LOAD_WEAK_DYLIB" \
            || cmd == "LC_REEXPORT_DYLIB" || cmd == "LC_LOAD_UPWARD_DYLIB" \
            || cmd == "LC_LAZY_LOAD_DYLIB") { print $2 }'
}

# The file's own install name (LC_ID_DYLIB); empty for a bundle (MH_BUNDLE).
install_name() {
    otool -l "$1" | awk '$1 == "cmd" { cmd = $2 } $1 == "name" && cmd == "LC_ID_DYLIB" { print $2 }'
}

rpaths() {
    otool -l "$1" | awk '$1 == "cmd" { cmd = $2 } $1 == "path" && cmd == "LC_RPATH" { print $2 }'
}

# The compatibility version a file records for one of its references.
ref_compat_version() {
    otool -l "$1" | awk -v want="$2" '
        $1 == "cmd" { cmd = $2; hit = 0 }
        $1 == "name" && cmd ~ /^LC_(LOAD|LOAD_WEAK|REEXPORT|LOAD_UPWARD|LAZY_LOAD)_DYLIB$/ { hit = ($2 == want) }
        hit && $1 == "compatibility" { print $3; exit }'
}

# The compatibility version a library declares for itself.
own_compat_version() {
    otool -l "$1" | awk '
        $1 == "cmd" { cmd = $2 }
        cmd == "LC_ID_DYLIB" && $1 == "compatibility" { print $3; exit }'
}

# The macOS version a Mach-O file says it needs: LC_BUILD_VERSION's
# minos, or the older LC_VERSION_MIN_MACOSX's version. Empty when it
# carries neither.
min_macos() {
    otool -l "$1" | awk '
        $1 == "cmd" { cmd = $2 }
        cmd == "LC_BUILD_VERSION" && $1 == "minos" { print $2; exit }
        cmd == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2; exit }'
}

# version_ge A B — 0 when dotted version A >= B.
version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, "."); k = (n > m ? n : m)
        for (i = 1; i <= k; i++) {
            xi = (i <= n ? x[i] + 0 : 0); yi = (i <= m ? y[i] + 0 : 0)
            if (xi > yi) exit 0
            if (xi < yi) exit 1
        }
        exit 0
    }'
}

# bundle_refs <target> <reference-prefix>
#   Copy every non-system library <target> loads into the bundle (once,
#   recursing into each new copy), point <target>'s references at the
#   copies through <reference-prefix>, and drop <target>'s LC_RPATHs.
bundle_refs() {
    local target=$1 ref_prefix=$2 dep base src want have rp
    chmod u+w "$target"
    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        case "$dep" in
            /usr/lib/*|/System/*) continue ;;
        esac
        base=${dep##*/}
        src="$PREFIX/lib/$base"
        [[ -e "$src" ]] || fail "${target#"$BUNDLE"/} loads $dep, and the conda \
prefix has no $base to bundle in its place."
        case "$dep" in
            @rpath/*|@loader_path/*)
                ;;
            /*)
                want=$(ref_compat_version "$target" "$dep")
                have=$(own_compat_version "$(resolve_file "$src")")
                [[ -n "$want" && -n "$have" ]] \
                    || fail "cannot read compatibility versions for $dep (in \
${target#"$BUNDLE"/}) / $src."
                version_ge "$have" "$want" \
                    || fail "${target#"$BUNDLE"/} links $dep (compatibility version \
$want), but the prefix's $base is only compatibility version $have."
                echo "::warning::${target#"$BUNDLE"/} links $dep by absolute path \
(an upstream packaging leak); relinked to the conda prefix's $base \
(compatibility version $have >= $want)."
                ;;
            *)
                fail "${target#"$BUNDLE"/} has a load command this bundler cannot \
place: '$dep'."
                ;;
        esac
        if [[ ! -e "$BUNDLE/$base" ]]; then
            cp "$(resolve_file "$src")" "$BUNDLE/$base"
            chmod u+w "$BUNDLE/$base"
            quiet install_name_tool -id "@loader_path/$base" "$BUNDLE/$base"
            bundle_refs "$BUNDLE/$base" '@loader_path/'
        fi
        if [[ "$dep" != "$ref_prefix$base" ]]; then
            quiet install_name_tool -change "$dep" "$ref_prefix$base" "$target"
        fi
    done < <(dylib_refs "$target")
    while IFS= read -r rp; do
        [[ -n "$rp" ]] || continue
        quiet install_name_tool -delete_rpath "$rp" "$target"
    done < <(rpaths "$target")
}

# --- 1. micromamba ---------------------------------------------------

MM="$WORK_DIR/bin/micromamba"   # post-link machinery insists on this name
if [[ ! -x "$MM" ]] \
   || [[ "$(shasum -a 256 "$MM" | awk '{print $1}')" != "$MICROMAMBA_SHA256" ]]; then
    mkdir -p "$WORK_DIR/bin"
    curl -fSL --retry 5 --retry-delay 10 -o "$MM.download" "$MICROMAMBA_URL"
    got=$(shasum -a 256 "$MM.download" | awk '{print $1}')
    if [[ "$got" != "$MICROMAMBA_SHA256" ]]; then
        rm -f "$MM.download"
        fail "micromamba $MICROMAMBA_VERSION SHA-256 mismatch: got $got, pinned $MICROMAMBA_SHA256."
    fi
    mv "$MM.download" "$MM"
    chmod +x "$MM"
fi
echo "micromamba $(mm --version) ($MICROMAMBA_SHA256)"

# --- 2. conda prefix -------------------------------------------------

if [[ -f "$PREFIX/conda-meta/libvips-${VIPS_VERSION}-${LIBVIPS_BUILD}.json" ]] \
   && ls "$PREFIX"/conda-meta/imagemagick-*-imagemagick_*.json >/dev/null 2>&1; then
    echo "Reusing $PREFIX (already holds libvips $VIPS_VERSION $LIBVIPS_BUILD)."
else
    [[ ! -e "$PREFIX" ]] || fail "$PREFIX exists but does not hold libvips \
$VIPS_VERSION $LIBVIPS_BUILD — remove it, or point WORK_DIR somewhere fresh."
    mm create --yes --no-rc \
        --root-prefix "$WORK_DIR/mamba-root" \
        --prefix "$PREFIX" \
        --platform osx-arm64 \
        --override-channels --channel conda-forge \
        --skip-run-link-scripts \
        "libvips==${VIPS_VERSION}=${LIBVIPS_BUILD}" "$IMAGEMAGICK_SPEC"
fi
echo "--- conda packages the bundle is cut from ---"
mm list --no-rc --root-prefix "$WORK_DIR/mamba-root" --prefix "$PREFIX"

[[ -f "$PREFIX/lib/libvips.42.dylib" ]] || fail "no libvips.42.dylib in $PREFIX/lib"

# --- 3. bundle -------------------------------------------------------

cp "$(resolve_file "$PREFIX/lib/libvips.42.dylib")" "$BUNDLE/libvips.42.dylib"
chmod u+w "$BUNDLE/libvips.42.dylib"
quiet install_name_tool -id '@loader_path/libvips.42.dylib' "$BUNDLE/libvips.42.dylib"
bundle_refs "$BUNDLE/libvips.42.dylib" '@loader_path/'

MODULES_SRC=''
for d in "$PREFIX"/lib/vips-modules-*; do
    [[ -d "$d" ]] || continue
    [[ -z "$MODULES_SRC" ]] || fail "more than one vips-modules-* directory in $PREFIX/lib."
    MODULES_SRC=$d
done
[[ -n "$MODULES_SRC" ]] || fail "no vips-modules-* directory in $PREFIX/lib — conda-forge's \
libvips ships its heif/jxl/openslide/poppler loaders as modules; without them the \
bundle opens none of those formats."
MODULES_DIR="$BUNDLE/$(basename "$MODULES_SRC")"
mkdir -p "$MODULES_DIR"
for m in $MODULES; do
    [[ -f "$MODULES_SRC/vips-$m.dylib" ]] \
        || fail "$MODULES_SRC has no vips-$m.dylib (has: $(cd "$MODULES_SRC" && echo *))."
done
excluded() {
    local m
    for m in $EXCLUDED_MODULES; do
        [[ "$(basename "$1")" == "vips-$m.dylib" ]] && return 0
    done
    return 1
}
for mod in "$MODULES_SRC"/*; do
    [[ -f "$mod" ]] || continue
    is_macho "$mod" || continue
    if excluded "$mod"; then
        echo "Leaving out $(basename "$mod") (EXCLUDED_MODULES)."
        continue
    fi
    dest="$MODULES_DIR/$(basename "$mod")"
    cp "$(resolve_file "$mod")" "$dest"
    chmod u+w "$dest"
    if [[ -n "$(install_name "$dest")" ]]; then
        quiet install_name_tool -id "@loader_path/$(basename "$mod")" "$dest"
    fi
    bundle_refs "$dest" '@loader_path/../'
done

# The unversioned name, so a caller asking for libvips.dylib finds it.
ln -s libvips.42.dylib "$BUNDLE/libvips.dylib"

# Where libvips looks for the modules: <libdir>/vips-modules-<M>.<m>/,
# with libdir = $VIPSHOME followed by the last path component of the
# libdir it was configured with — "/lib" in principle, but nothing at all
# in conda-forge's Linux build (GCC folds that strrchr() into a pointer
# into the string literal at compile time, and conda's install-time
# prefix relocation then shortens the string under it). FFI.rakumod sets
# VIPSHOME to the staged lib directory itself, so the modules directory
# here is found either way: directly ($VIPSHOME/vips-modules-<M>.<m>), or
# through this link ($VIPSHOME/lib/vips-modules-<M>.<m>), which is what
# this macOS build looks for. The Linux bundle carries the same link.
mkdir -p "$BUNDLE/lib"
ln -s "../$(basename "$MODULES_DIR")" "$BUNDLE/lib/$(basename "$MODULES_DIR")"

# --- 4. varargs shim -------------------------------------------------
#
# vips_shim_free wraps g_free, so the shim links libglib as well as
# libvips; the bundled libglib's file name carries its ABI version.

GLIB_DYLIB=''
for f in "$BUNDLE"/libglib-2.0.*.dylib; do
    if [[ -f "$f" ]]; then
        GLIB_DYLIB=$f
        break
    fi
done
[[ -n "$GLIB_DYLIB" ]] || fail "no libglib-2.0.*.dylib in the bundle — can't link the shim."

cc -O2 -arch arm64 -mmacosx-version-min="$MIN_MACOS" \
    -dynamiclib -fPIC \
    -install_name '@loader_path/libvips_shim.dylib' \
    -o "$BUNDLE/libvips_shim.dylib" \
    "$SHIM_SRC" \
    "$BUNDLE/libvips.42.dylib" \
    "$GLIB_DYLIB"

# Every vips_shim_* the source defines (each definition opens a line,
# its return type on the line before) must be exported, by name: a
# missing one only dies at a binding's first call, in an application.
defined=$(grep -oE '^vips_shim_[A-Za-z0-9_]+' "$SHIM_SRC" | sort -u)
exported=$(nm -gU -arch arm64 "$BUNDLE/libvips_shim.dylib" \
    | sed -nE 's/.* T _(vips_shim_[A-Za-z0-9_]+)$/\1/p' | sort -u)
missing=$(comm -23 <(printf '%s\n' "$defined") <(printf '%s\n' "$exported"))
[[ -z "$missing" ]] || fail "libvips_shim.dylib does not export: $(echo "$missing" | tr '\n' ' ')"
echo "ok: libvips_shim.dylib exports all $(printf '%s\n' "$defined" | wc -l | tr -d ' ') vips_shim_* functions"

# Sidecar for Build.rakumod's content-based freshness check: the SHA-256
# of the shim source this shim was compiled from. Without it, installs
# compare cross-machine mtimes, which always find the dist's source newer.
shasum -a 256 "$SHIM_SRC" | awk '{print $1}' > "$BUNDLE/libvips_shim.dylib.srchash"

# --- 5. signatures ---------------------------------------------------

while IFS= read -r f; do
    is_macho "$f" || continue
    quiet codesign --force --sign - --timestamp=none "$f"
done < <(find "$BUNDLE" -type f)

# --- 6. audit --------------------------------------------------------

echo "--- audit ---"
problems=0
problem() {
    echo "::error::$*" >&2
    echo "❌ $*" >&2
    problems=$((problems + 1))
}

macho_count=0
max_minos='0'
while IFS= read -r f <&3; do
    rel=${f#"$BUNDLE"/}
    if ! is_macho "$f"; then
        case "$rel" in
            *.srchash) continue ;;
            *) problem "$rel is not a Mach-O file and not a known sidecar." ; continue ;;
        esac
    fi
    macho_count=$((macho_count + 1))

    archs=$(lipo -archs "$f" 2>/dev/null || true)
    [[ "$archs" == 'arm64' ]] || problem "$rel: architectures '$archs', expected exactly arm64."

    minos=$(min_macos "$f")
    if [[ -z "$minos" ]]; then
        problem "$rel carries no LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX."
    else
        version_ge "$MIN_MACOS" "$minos" \
            || problem "$rel needs macOS $minos, above the bundle's floor of $MIN_MACOS."
        version_ge "$max_minos" "$minos" || max_minos=$minos
    fi

    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        case "$dep" in
            /usr/lib/*|/System/*) ;;
            @loader_path/*)
                [[ -e "$(dirname "$f")/${dep#@loader_path/}" ]] \
                    || problem "$rel loads $dep, which is not in the bundle."
                ;;
            *) problem "$rel loads $dep — outside the bundle and not a system library." ;;
        esac
    done < <(dylib_refs "$f")

    id=$(install_name "$f")
    if [[ -n "$id" && "$id" != "@loader_path/$(basename "$f")" ]]; then
        problem "$rel has install name '$id', expected @loader_path/$(basename "$f")."
    fi

    leftover=$(rpaths "$f")
    [[ -z "$leftover" ]] || problem "$rel keeps LC_RPATH entries: $(echo "$leftover" | tr '\n' ' ')"

    codesign --verify "$f" 2>/dev/null || problem "$rel: code signature does not verify."
done 3< <(find "$BUNDLE" -type f | sort)

while IFS= read -r l; do
    target=$(readlink "$l")
    if [[ "$target" == /* ]]; then
        problem "${l#"$BUNDLE"/} -> $target is an absolute link."
    elif [[ ! -e "$l" ]]; then
        problem "${l#"$BUNDLE"/} -> $target is dangling."
    else
        resolved="$(cd "$(dirname "$l")" && cd "$(dirname "$target")" && pwd -P)"
        case "$resolved/" in
            "$(cd "$BUNDLE" && pwd -P)"/*) ;;
            *) problem "${l#"$BUNDLE"/} -> $target leads out of the bundle." ;;
        esac
    fi
done < <(find "$BUNDLE" -type l)
[[ -d "$BUNDLE/lib/$(basename "$MODULES_DIR")" ]] \
    || problem "lib/$(basename "$MODULES_DIR") does not lead to the modules."

for m in $MODULES; do
    [[ -f "$MODULES_DIR/vips-$m.dylib" ]] || problem "vips-$m.dylib missing from $MODULES_DIR."
done
for m in $EXCLUDED_MODULES; do
    [[ ! -e "$MODULES_DIR/vips-$m.dylib" ]] || problem "vips-$m.dylib is in the bundle (EXCLUDED_MODULES)."
done
for pattern in "${FORBIDDEN_LIBS[@]}"; do
    while IFS= read -r f; do
        problem "${f#"$BUNDLE"/} is in the bundle (FORBIDDEN_LIBS: $pattern)."
    done < <(find "$BUNDLE" -name "$pattern")
done

if (( problems > 0 )); then
    fail "$problems audit problem(s) — not packaging this bundle."
fi

echo "✅ $macho_count Mach-O files, all arm64-only, highest minos $max_minos (floor $MIN_MACOS);"
echo "   every reference resolves inside the bundle or to /usr/lib, /System; no LC_RPATH;"
echo "   signatures verify. $(du -sh "$BUNDLE" | awk '{print $1}') on disk."

# --- 7. notices kit --------------------------------------------------

python3 "$REPO_ROOT/scripts/ci/third-party.py" conda \
    --prefix "$PREFIX" \
    --bundle "$BUNDLE" \
    --pack vips-macos-arm64.tar.gz \
    --tag "$BINARY_TAG" \
    --spec "libvips==${VIPS_VERSION}=${LIBVIPS_BUILD}" \
    --spec "$IMAGEMAGICK_SPEC" \
    --pkgs-dir "$WORK_DIR/mamba-root/pkgs"
echo "--- bundle contents ---"
ls -la "$BUNDLE" "$BUNDLE/lib" "$MODULES_DIR"
