#!/usr/bin/env bash
# '$ORIGIN' below is patchelf's, not the shell's: the single quotes are
# the point.
# shellcheck disable=SC2016
# Build Vips-Native's Linux glibc prebuilt bundle out of a conda-forge
# environment holding libvips. build-binaries.yml's build-linux job runs
# it after creating that environment (for linux-x86_64-glibc and
# linux-aarch64-glibc alike):
#
#     bash scripts/ci/bundle-linux.sh "$CONDA/envs/vipsenv/lib" bundle
#
# In order:
#
#   1. Copy libvips.so.42 and walk its dependencies with ldd (resolving
#      through the conda env first), copying each library the env
#      provides beside it — including the env's C++ runtime (libstdc++,
#      libgcc_s; libgomp, LibRaw's OpenMP runtime, comes the same way),
#      which is newer than an Ubuntu 22.04 system's and which libheif and
#      poppler require. glibc itself, and anything the env does not
#      provide, stays the system's.
#   2. Copy conda-forge's dlopen'd loader modules (lib/vips-modules-
#      <M>.<m>/: heif, jxl, openslide, poppler) under the same versioned
#      directory name, and walk their dependencies the same way. Without
#      this step a Linux install opens none of HEIF / AVIF, JPEG XL, PDF
#      or OpenSlide files — the r11 bundles shipped without them. Step 3
#      also links lib/vips-modules-<M>.<m> to it; see there for why. The
#      ImageMagick module (vips-magick) is left out, and with it
#      everything only it links: ImageMagick's libraries, and Graphviz,
#      whose EPL-1.0 does not sit with the GPL code (FFTW, poppler) in the
#      same pack on the FSF's reading (see EXCLUDED_MODULES).
#   3. Set every library's run path to $ORIGIN (the modules' to
#      $ORIGIN/.., one directory down), so they find each other wherever
#      the bundle is unpacked.
#   4. Compile the varargs shim against the bundle and write its
#      .srchash sidecar.
#   5. Audit: every ELF file in the bundle resolves every dependency with
#      no loader search path set, and none of them into the conda env;
#      and nothing of ImageMagick or Graphviz is in it (FORBIDDEN_LIBS).
#   6. Write the notices kit — THIRD-PARTY.md + LICENSES/ — attributing
#      every bundled file to the conda package it came from
#      (scripts/ci/third-party.py), and fail if any file can't be.
#
# Inputs:
#   $1           the conda environment's lib directory
#   $2           bundle directory to create (must not exist, or be empty)
#   BINARY_TAG   the release tag the bundle is for
#   PACK_NAME    the archive it will be packaged as (vips-<platform>.tar.gz)
#   CONDA_SPECS  the package specs the environment was created from,
#                space-separated (recorded in THIRD-PARTY.md)
set -euxo pipefail

fail() {
    set +x
    echo "::error::$*" >&2
    echo "❌ $*" >&2
    exit 1
}

[[ $# -eq 2 ]] || fail "usage: $0 <conda-env-lib-dir> <bundle-dir>"
BINARY_TAG="${BINARY_TAG:?BINARY_TAG must be set}"
PACK_NAME="${PACK_NAME:?PACK_NAME must be set}"
CONDA_SPECS="${CONDA_SPECS:?CONDA_SPECS must be set}"
ENV_LIB=$1
[[ -d "$ENV_LIB" ]] || fail "no conda env lib dir at $ENV_LIB"
ENV_LIB="$(cd "$ENV_LIB" && pwd)"
ENV_PREFIX="$(dirname "$ENV_LIB")"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHIM_SRC="$REPO_ROOT/src/vips_native_shim.c"

BUNDLE=$2
if [[ -e "$BUNDLE" ]]; then
    [[ -d "$BUNDLE" && -z "$(ls -A "$BUNDLE")" ]] \
        || fail "$BUNDLE exists and is not an empty directory."
fi
mkdir -p "$BUNDLE"
BUNDLE="$(cd "$BUNDLE" && pwd)"

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

# --- 1. libvips and its dependency closure ---------------------------

# Start from libvips.so.42 and walk transitive deps via ldd. (The
# unversioned libvips.so symlink is made in step 3.)
cp "$ENV_LIB"/libvips.so.42* "$BUNDLE"/
[[ -f "$BUNDLE/libvips.so.42" ]] || fail "no libvips.so.42 in $ENV_LIB"

declare -A SEEN
process_deps() {
    local lib="$1"
    local depth="${2:-0}"
    (( depth > 12 )) && return 0
    local key
    key="$(basename "$lib")"
    [[ -n "${SEEN[$key]:-}" ]] && return 0
    SEEN[$key]=1
    # LD_LIBRARY_PATH so ldd resolves transitive deps via the conda env
    # first, not whatever the runner happens to have system-installed.
    # Without this, glib/gobject etc come from /lib/<triple> and get
    # skipped as "system libs" — the bundle ships missing its core deps.
    LD_LIBRARY_PATH="$ENV_LIB:${LD_LIBRARY_PATH:-}" \
      ldd "$lib" 2>/dev/null \
      | sed -nE 's/^[[:space:]]*([^ ]+) => ([^ ]+) .*/\1\t\2/p' \
      | while IFS=$'\t' read -r name path; do
          [[ -z "$path" ]] && continue
          # `=> not found` parses as path="not" — skip cleanly; the audit
          # below fails the build if it is still unresolved there.
          [[ "$path" == "not" ]] && {
            echo "WARN: $name unresolved by ldd ('not found') — skipping"
            continue
          }
          # Path must be absolute + a real file.
          [[ "$path" != /* || ! -f "$path" ]] && continue
          # Skip system libs — these stay dynamic.
          case "$path" in
            /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*) continue ;;
          esac
          # Skip the C runtime and the linker itself. NOT the C++ runtime:
          # conda-forge builds with a newer GCC than the oldest distro we
          # promise (glibc 2.35, Ubuntu 22.04: GCC 12's libstdc++, up to
          # GLIBCXX_3.4.30), and libheif and poppler (behind the heif and
          # poppler modules) need GLIBCXX_3.4.31/32 and CXXABI_1.3.15. The
          # env's libstdc++.so.6 and libgcc_s.so.1 are bundled; being
          # newer, they also serve any older C++ library a process loads
          # after them.
          case "$name" in
            ld-linux*|linux-vdso*|libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*) continue ;;
          esac
          if [[ ! -f "$BUNDLE/$name" ]]; then
            cp "$path" "$BUNDLE/$name"
            echo "Bundled: $name (from $path)"
            process_deps "$BUNDLE/$name" $((depth + 1))
          fi
        done
}

for lib in "$BUNDLE"/libvips.so*; do
  [[ -L "$lib" ]] && continue
  process_deps "$lib"
done

# --- 2. the loader modules -------------------------------------------

MODULES_SRC=''
for d in "$ENV_LIB"/vips-modules-*; do
  [[ -d "$d" ]] || continue
  [[ -z "$MODULES_SRC" ]] || fail "more than one vips-modules-* directory in $ENV_LIB."
  MODULES_SRC=$d
done
[[ -n "$MODULES_SRC" ]] || fail "no vips-modules-* directory in $ENV_LIB — conda-forge's \
libvips ships its heif/jxl/openslide/poppler loaders as modules; without them the \
bundle opens none of those formats."
MODULES_DIR="$BUNDLE/$(basename "$MODULES_SRC")"
mkdir -p "$MODULES_DIR"
for m in $MODULES; do
  [[ -f "$MODULES_SRC/vips-$m.so" ]] \
    || fail "$MODULES_SRC has no vips-$m.so (has: $(cd "$MODULES_SRC" && echo *))."
done
excluded() {
  local m
  for m in $EXCLUDED_MODULES; do
    [[ "$(basename "$1")" == "vips-$m.so" ]] && return 0
  done
  return 1
}
for mod in "$MODULES_SRC"/*.so; do
  [[ -f "$mod" ]] || continue
  if excluded "$mod"; then
    echo "Leaving out $(basename "$mod") (EXCLUDED_MODULES)."
    continue
  fi
  cp -L "$mod" "$MODULES_DIR/"
  process_deps "$MODULES_DIR/$(basename "$mod")"
done

# --- 3. run paths ----------------------------------------------------

# $ORIGIN on every top-level library so they find each other by
# sibling lookup at runtime, regardless of where the user installs the
# bundle dir on disk; $ORIGIN/.. on the modules, which load libvips and
# their codec libraries from the directory above.
for so in "$BUNDLE"/*.so*; do
  [[ -L "$so" ]] && continue
  patchelf --set-rpath '$ORIGIN' "$so" || true
done
for mod in "$MODULES_DIR"/*.so; do
  patchelf --set-rpath '$ORIGIN/..' "$mod"
done

# Convenience symlink for the unversioned name.
ln -sf libvips.so.42 "$BUNDLE/libvips.so"

# Where libvips looks for the modules: <libdir>/vips-modules-<M>.<m>/,
# with libdir = $VIPSHOME followed by the last path component of the
# libdir it was configured with. In conda-forge's Linux build that
# component comes out empty (GCC folds the strrchr() into a pointer into
# the string literal at compile time, and conda's install-time prefix
# relocation then shortens the string under it), so this build looks in
# $VIPSHOME/vips-modules-<M>.<m>/ — while the macOS build looks in
# $VIPSHOME/lib/vips-modules-<M>.<m>/. FFI.rakumod sets VIPSHOME to the
# staged lib directory itself on both, and both bundles carry this link,
# so either reading finds the modules.
mkdir -p "$BUNDLE/lib"
ln -s "../$(basename "$MODULES_DIR")" "$BUNDLE/lib/$(basename "$MODULES_DIR")"

# Same for libglib — needed to link the shim's vips_shim_free wrapper
# (which calls g_free, a libglib symbol). The bundled file is
# libglib-2.0.so.<major>; symlink the unversioned name so `-lglib-2.0`
# finds it.
GLIB_SO=''
for f in "$BUNDLE"/libglib-2.0.so.*; do
  if [[ -f "$f" ]]; then
    GLIB_SO=$f
    break
  fi
done
[[ -n "$GLIB_SO" ]] || fail "no libglib-2.0.so.* in the bundle — can't link the shim."
ln -sf "$(basename "$GLIB_SO")" "$BUNDLE/libglib-2.0.so"

# --- 4. varargs shim -------------------------------------------------
#
# Same rationale as macOS. Linux aarch64 has the same AAPCS64 variadic
# ABI divergence as Apple arm64 (named args in registers, varargs on
# stack). The x86_64 ABI is forgiving (no register/stack split for
# varargs), but shipping the shim on both arches is cheap insurance
# and eliminates the latent UB entirely.
gcc -O2 -shared -fPIC \
    -Wl,-soname,libvips_shim.so \
    -o "$BUNDLE/libvips_shim.so" \
    "$SHIM_SRC" \
    -L"$BUNDLE" -lvips -lglib-2.0
patchelf --set-rpath '$ORIGIN' "$BUNDLE/libvips_shim.so"
# Sidecar for Build.rakumod's content-based freshness check — see
# scripts/ci/bundle-macos-arm64.sh for the full rationale.
sha256sum "$SHIM_SRC" | awk '{print $1}' > "$BUNDLE/libvips_shim.so.srchash"

# --- 5. audit --------------------------------------------------------

set +x
echo "--- audit: every ELF resolves inside the bundle or to the system ---"
problems=0
elf_count=0
while IFS= read -r f; do
  head -c 4 "$f" | grep -q 'ELF' || continue
  elf_count=$((elf_count + 1))
  out=$(env -u LD_LIBRARY_PATH -u LD_PRELOAD ldd "$f" 2>&1) || true
  if grep -q 'not found' <<<"$out"; then
    echo "::error::${f#"$BUNDLE"/} has unresolved dependencies:"
    grep 'not found' <<<"$out" | sed 's/^/     /'
    problems=$((problems + 1))
  fi
  if grep -qF "$ENV_PREFIX/" <<<"$out"; then
    echo "::error::${f#"$BUNDLE"/} still resolves libraries from the conda env:"
    grep -F "$ENV_PREFIX/" <<<"$out" | sed 's/^/     /'
    problems=$((problems + 1))
  fi
done < <(find "$BUNDLE" -type f | sort)
for m in $MODULES; do
  [[ -f "$MODULES_DIR/vips-$m.so" ]] \
    || { echo "::error::vips-$m.so missing from $MODULES_DIR"; problems=$((problems + 1)); }
done
for m in $EXCLUDED_MODULES; do
  [[ ! -e "$MODULES_DIR/vips-$m.so" ]] \
    || { echo "::error::vips-$m.so is in the bundle (EXCLUDED_MODULES)"; problems=$((problems + 1)); }
done
for pattern in "${FORBIDDEN_LIBS[@]}"; do
  while IFS= read -r f; do
    echo "::error::${f#"$BUNDLE"/} is in the bundle (FORBIDDEN_LIBS: $pattern)"
    problems=$((problems + 1))
  done < <(find "$BUNDLE" -name "$pattern")
done
[[ -d "$BUNDLE/lib/$(basename "$MODULES_DIR")" ]] \
  || { echo "::error::lib/$(basename "$MODULES_DIR") does not lead to the modules"; problems=$((problems + 1)); }
(( problems == 0 )) || fail "$problems audit problem(s) — not packaging this bundle."
echo "✅ $elf_count ELF files; every dependency resolves inside the bundle or to the system."

# --- 6. notices kit --------------------------------------------------

# read -a, not an unquoted expansion: the specs hold globs
# (imagemagick=*=imagemagick_*) that must not meet the filesystem.
read -r -a specs <<<"$CONDA_SPECS"
spec_args=()
for spec in "${specs[@]}"; do
  spec_args+=(--spec "$spec")
done
python3 "$REPO_ROOT/scripts/ci/third-party.py" conda \
  --prefix "$ENV_PREFIX" \
  --bundle "$BUNDLE" \
  --pack "$PACK_NAME" \
  --tag "$BINARY_TAG" \
  "${spec_args[@]}"

echo "--- bundle contents ---"
ls -la "$BUNDLE" "$BUNDLE/lib" "$MODULES_DIR"
