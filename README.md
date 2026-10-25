[![Actions Status](https://github.com/m-doughty/Vips-Native/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/Vips-Native/actions)

NAME
====

Vips::Native - Raku FFI wrapper for libvips with bundled prebuilts

SYNOPSIS
========

```raku
use Vips::Native;

# 1. Smart-crop + resize to fixed output dimensions, saved as PNG.
smart-resize("input.png", "thumb.png", 128, 128);

# 2. Letterbox-resize to a fixed square + return raw 8-bit RGB pixels.
#    Aspect ratio preserved; gap filled with the chosen background.
#    Output is suitable to feed to ML inference engines.
my Buf[uint8] $bytes = letterbox-to-buffer(
    'photo.png'.IO,
    :size(448),
    :bg(255, 255, 255),
);
say $bytes.bytes;   # 448 × 448 × 3 = 602112
```

DESCRIPTION
===========

`Vips::Native` is a Raku NativeCall wrapper around [libvips](https://www.libvips.org/), shipped with prebuilt platform bundles so the common case (install, import, run) doesn't require a working libvips toolchain on the host.

The module exposes two high-level helpers:

  * [smart-resize](#smart-resize) — thumbnail-style: smart-crop to the requested aspect ratio (using libvips's saliency / entropy / attention model), then Lanczos3-resize, then save as PNG.

  * [letterbox-to-buffer](#letterbox-to-buffer) — ML-preprocess: scale-to-fit inside a square canvas (no crop), pad the gap with a chosen colour, composite RGBA over that colour, and return the raw RGB pixel buffer in NHWC byte order. The preprocess pipeline image classifiers want.

The full (variadic) libvips C API is available via direct `is native` bindings under [Vips::Native::FFI](Vips::Native::FFI) — see the module's SYNOPSIS for the bindings exported. Most of those go through a tiny non-variadic C shim (`src/vips_native_shim.c`) for ABI safety on Apple arm64 / Linux aarch64, where Raku's NativeCall can't marshal C variadics correctly.

INSTALLATION
============

`Vips::Native` tries three lookup paths at install + load time, in order:

  * **Prebuilt bundle (default)** — fetched from the project's GitHub Releases at install time, sha256-pinned against `resources/checksums.txt`, staged under `$XDG_DATA_HOME/Vips-Native/<binary-tag>/lib/`. Bundles include libvips, libglib, libgio, libgobject, the format loaders (jpeg/png/webp/tiff/gif/svg/heif/avif/jxl/openslide/pdf, and magick on Windows only) and all their transitive deps with `@loader_path` (macOS) / `$ORIGIN` (Linux) / sibling-DLL (Windows) relocations baked in, so the bundle is self-contained — and a `THIRD-PARTY.md` + `LICENSES/` notices kit, staged beside the libraries (see *BINARY DISTRIBUTIONS AND LICENSING* below).

  * **System libvips** — fallback when the prebuilt download fails or no prebuilt exists for your platform. `Vips::Native` probes for an installed libvips itself and loads it by absolute path: first the dynamic loader's own search variables (`DYLD_LIBRARY_PATH` and `DYLD_FALLBACK_LIBRARY_PATH` on macOS, `LD_LIBRARY_PATH` on Linux, `PATH` on Windows), then the platform's library directories — including Homebrew's per-formula opt kegs, so an **unlinked** `brew install vips` is still found — and finally `ldconfig -p`'s cache listing on Linux. It must be libvips 8.12 or later (Ubuntu 22.04 ships 8.12, Debian 12 8.14): an older one is refused when the module loads, with the version found and what to do. Older distributions get the prebuilt, which needs only glibc 2.17.

  * On macOS: `brew install vips`

  * On Debian/Ubuntu: `sudo apt install libvips-dev`

  * **Custom install** — set `VIPS_NATIVE_LIB_DIR=/path/to/dir` to point at a directory containing `libvips.{dylib,so,dll}` and `libgobject-2.0.{dylib,so,dll}`. Caller takes responsibility for ABI compatibility, and for that install's own environment (`VIPSHOME`, GIO modules); on Windows the directory is still made the DLL search directory, since its libvips cannot load its own dependencies otherwise. A `libvips_shim` in the same directory is used in preference to the staged one. A value that is not a directory is ignored, by everything, and the staged bundle is used.

Supported platforms
-------------------

  * macOS arm64 (Apple silicon, macOS 11 or later)

  * Linux x86_64 + aarch64 (glibc 2.17+)

  * Windows x86_64 + arm64

Every supported platform ships a working bundle with the varargs shim included.

x86_64 macOS has no prebuilt: neither an Intel Mac nor an x86_64 Raku running under Rosetta on Apple silicon (which reports itself as x86_64). There, installing falls back to a system libvips, and that libvips has to be x86_64 too — an arm64 one, such as Homebrew's on Apple silicon, cannot load into an x86_64 process. Install an x86_64 libvips (MacPorts, or your own build) and `Vips::Native` finds it in the usual library directories, or point `VIPS_NATIVE_LIB_DIR` at it. The install says so when it happens. An arm64 Raku on the same Mac gets the prebuilt.

Build-time environment
----------------------

  * `VIPS_NATIVE_PREFER_SYSTEM=1` — skip prebuilt download, force system libvips at runtime.

  * `VIPS_NATIVE_BINARY_ONLY=1` — refuse to fall back to system libvips; fail loudly if the prebuilt can't be installed (CI / pinned deployments).

  * `VIPS_NATIVE_DATA_DIR=/path` — override staged-libs root (default `$XDG_DATA_HOME` or `~/.local/share`).

  * `VIPS_NATIVE_CACHE_DIR=/path` — override the cache for prebuilt archives and compiled shims (default `$XDG_CACHE_HOME` or `~/.cache`; `%LOCALAPPDATA%` on Windows).

  * `VIPS_NATIVE_CC=cc` — the C compiler for the varargs shim, as a path or a name on `PATH` (default: the first of `cc`, `gcc`, `clang`).

  * `VIPS_NATIVE_BINARY_URL=https://…` — override the GitHub Release base URL (custom mirror).

  * `VIPS_NATIVE_KEEP_OLD_STAGES=1` — opt out of the orphaned-stage GC that runs after every install. Use when intentionally pinning multiple versions side-by-side.

BINARY DISTRIBUTIONS AND LICENSING
==================================

`Vips::Native` itself is Artistic-2.0. The prebuilt packs it downloads are something else: binary redistributions of libvips and the libraries it depends on, built by third parties and repackaged here unmodified apart from their load paths. The only code of `Vips::Native`'s own in them is the varargs shim (`libvips_shim`, Artistic-2.0).

**The prebuilt packs contain GPL-licensed code**, as well as LGPL-licensed code, code under the weak-copyleft MPL-2.0, and code under permissive licences:

  * **macOS arm64, Linux x86_64, Linux aarch64** — GPL: FFTW (which libvips itself links), poppler (the PDF loader), x265 (an HEVC encoder, through libheif) and LZO (through libarchive), all GPL-2.0-or-later. FreeType is dual-licensed, GPL-2.0 or the FreeType Licence. On Linux, the GCC runtime (`libstdc++`, `libgcc_s`, and `libgomp`, the OpenMP runtime LibRaw uses) is GPL-3.0 with the GCC Runtime Library Exception. LGPL: libvips, GLib, cairo, pango, librsvg (with MPL-2.0 Rust crates built into it), gdk-pixbuf, fribidi, graphite2, libexif, LibRaw, OpenSlide, libiconv, libintl (macOS), keyutils (Linux), and libheif and libde265 (LGPL-3.0). MPL-2.0: NSS and NSPR (through poppler), and the Public Suffix List built into libpsl.

  * **Windows x86_64, Windows arm64** — GPL: FFTW and poppler. Dual-licensed, GPL-2.0 or another licence: FreeType (or the FreeType Licence) and zstd (or BSD-3-Clause). LGPL: libvips, GLib (with proxy-libintl built into it), cairo, pango, librsvg, fribidi, libexif, LibRaw, OpenSlide and libheif (LGPL-3.0). MPL-2.0: the Rust crates built into librsvg — cssparser 0.37.0, cssparser-color 0.5.0, dtoa-short 0.3.5 and selectors 0.40.0.

Every pack carries a `THIRD-PARTY.md` and a `LICENSES/` directory, staged beside the libraries in `$XDG_DATA_HOME/Vips-Native/<binary-tag>/lib/` (installation refuses an archive without them). `THIRD-PARTY.md` maps every library file in the pack to the package or component it came from, with its version, its licence and where its source lives, and calls out the licences above; `LICENSES/` holds the licence texts, including the GPL-3.0 text the LGPL-3.0 incorporates, and the notices that go with them (Lerc's NOTICE on macOS and Linux, and in every pack the notices of FreeType's BDF and PCF font drivers). The Windows packs' upstream archive carries only libvips's own licence text, so every component's licence texts are taken from the source it was built from, each checked against a pinned SHA-256 when the pack is built — the components built into another's DLL (the mingw-w64 runtime and LLVM's compiler-rt in every DLL, proxy-libintl in GLib's, the Rust crates and standard library in librsvg's, Imath in OpenEXR's, uthash in libdicom's) among them. A pack is not built if a package in it declares a copyleft licence this section does not name.

**Where to get the source.** Each pack's `THIRD-PARTY.md` lists, under *Where to get the source*, the source archive of every GPL, LGPL and MPL component in it, with the SHA-256 the build checked it against, and the recipe that built it (the build script and any patches). The MPL-2.0 code's source is also at its upstreams: NSS at [https://ftp.mozilla.org/pub/security/nss/releases/](https://ftp.mozilla.org/pub/security/nss/releases/) and NSPR at [https://ftp.mozilla.org/pub/nspr/releases/](https://ftp.mozilla.org/pub/nspr/releases/) (macOS and Linux), and each Rust crate at `https://crates.io/crates/<name>/<version>` — on Windows [cssparser 0.37.0](https://crates.io/crates/cssparser/0.37.0), [cssparser-color 0.5.0](https://crates.io/crates/cssparser-color/0.5.0), [dtoa-short 0.3.5](https://crates.io/crates/dtoa-short/0.3.5) and [selectors 0.40.0](https://crates.io/crates/selectors/0.40.0); on macOS and Linux, the versions in that pack's librsvg, which its `THIRD-PARTY.md` names.

**Acknowledgements.** The licences of FreeType, of the IJG-derived JPEG libraries (libjpeg-turbo on macOS and Linux, mozjpeg on Windows) and of libultrahdr (Windows) ask the documentation of a binary distribution to carry these statements, and each pack's `THIRD-PARTY.md` carries the ones for what it holds:

  * Portions of this software are copyright © 2026 The FreeType Project ([https://freetype.org](https://freetype.org)). All rights reserved.

  * This software is based in part on the work of the Independent JPEG Group.

  * This product includes Gain Map technology under license by Adobe (Windows).

Tables derived from the Unicode Character Database are compiled into GLib, FriBidi and HarfBuzz, in every pack; the Unicode License v3 that covers them is in each pack as `LICENSES/Unicode-3.0.txt`.

The macOS and Linux packs carry no ImageMagick. conda-forge's libvips depends on it, so it is in the environment those packs are cut from, but they leave out libvips's ImageMagick loader and everything only it needs — ImageMagick's own libraries, OpenEXR, and Graphviz, whose EPL-1.0 is, on the Free Software Foundation's reading, incompatible with the GPL code beside it. There is no `magickload` or `magicksave` on those platforms, so files only ImageMagick reads do not open: BMP, ICO and CUR, PSD, TGA, OpenEXR, DDS, DPX, PCX, QOI, SGI, Sun raster, XBM, XPM, PAM, MIFF, MNG and JNG, MATLAB and VIFF files among them. The Windows packs keep ImageMagick (under its own licence), and with it all of those formats.

Where the packs come from:

  * **macOS arm64** — the [conda-forge](https://conda-forge.org/) channel, platform `osx-arm64`, libvips 8.18.7 build `h588ea66_0`.

  * **Linux x86_64** — conda-forge, `linux-64`, libvips 8.18.7 build `he268db4_0`.

  * **Linux aarch64** — conda-forge, `linux-aarch64`, libvips 8.18.7 build `h4590af0_0`.

  * **Windows x86_64 and arm64** — [libvips/build-win64-mxe](https://github.com/libvips/build-win64-mxe) release [v8.18.7](https://github.com/libvips/build-win64-mxe/releases/tag/v8.18.7) (`vips-dev-x64-all-8.18.7.zip`, `vips-dev-arm64-all-8.18.7.zip`), whose build recipe is that repository at that tag.

Each macOS and Linux pack's `THIRD-PARTY.md` lists every package of the environment the pack was cut from, by version and build string — those that contribute no file to it too, ImageMagick among them (pinned to conda-forge's `imagemagick_*` builds, which declare ImageMagick's own licence, rather than the `agpl_*` builds of the same libraries) — and, for every package in the pack, the conda-forge recipe at the commit that built it and the upstream source archive.

To use no prebuilt at all, install with `VIPS_NATIVE_PREFER_SYSTEM=1`: nothing is downloaded, `Vips::Native` loads the libvips you installed yourself (see [INSTALLATION](#INSTALLATION)), and the varargs shim is compiled from its source with your C compiler. `VIPS_NATIVE_LIB_DIR` points it at a libvips of your own build instead. Either way it must be libvips 8.12 or later. Platforms without a prebuilt (including x86_64 macOS) always take that path.

EXTERNAL API
============

smart-resize
------------

```raku
sub smart-resize(
    Str $in-path,
    Str $out-path,
    Int $out-width,
    Int $out-height,
    --> Bool
) is export
```

Smart-crop the source image to match the output aspect ratio (using libvips's `VIPS_INTERESTING_ATTENTION` saliency model — picks the visually-important rectangle, not just the centre), then Lanczos3- resize the cropped image to `$out-width × $out-height` and save as PNG to `$out-path`.

Returns `True` on success; `fail`s with the underlying error if libvips errors out.

A `vips_smart_resize` shell binary is also installed:

    vips_smart_resize --in=/path/to/image.png --out=/path/to/save.png \
                      --width=180 --height=180

letterbox-to-buffer
-------------------

```raku
sub letterbox-to-buffer(
    IO::Path() $path,
    UInt :$size = 448,
    :@bg = (255, 255, 255),
    --> Buf[uint8]
) is export
```

Resize `$path` to fit inside a `$size × $size` square while preserving aspect ratio, pad the unfilled region with the `@bg` colour, composite alpha over that colour for RGBA inputs, and return the raw 8-bit RGB pixel buffer in NHWC byte order. Length is always exactly `$size × $size × 3`.

The preprocess pipeline image classifiers want: deterministic gap fill, fixed input dimensions, no GC entanglement with libvips's heap. Pair with [ONNX::Native](ONNX::Native) or your inference engine of choice to feed RGB pixels directly.

The buffer is owned by the caller — internally we copy from the `vips_image_write_to_memory` result into a Raku-owned `buf8` and release the source via `vips_shim_free`, so there's no lifetime trap.

Inputs may be 3-band RGB or 4-band RGBA (UCHAR pixels only — 16-bit PNG / HDR / float images are out of scope for v1). Greyscale and CMYK fail loudly with details.

Vips::Native::FFI
-----------------

The complete (variadic + non-variadic) libvips C bindings are exported from `Vips::Native::FFI`:

  * `vips_init`, `vips_image_new_from_file`

  * `vips_image_get_width` / `get_height` / `get_bands` / `get_format`

  * `vips_smartcrop`, `vips_resize`, `vips_flatten`, `vips_embed`

  * `vips_pngsave`, `vips_image_write_to_memory`

  * `vips_shim_free` (libglib heap free for write-to-memory output)

  * `g_object_unref` (release VipsImage handles)

  * `VIPS_KERNEL_*`, `VIPS_INTERESTING_*`, `VIPS_EXTEND_*`, `VIPS_FORMAT_*` constants

`vips_flatten` and `vips_embed` require the libvips_shim (their options take a `VipsArrayDouble *` that's awkward to construct directly from Raku). Every prebuilt bundle includes it; if you're running against system libvips, the shim is compiled at install time via the platform's C toolchain and falls back gracefully if no toolchain is available.

A staged shim is kept only while it matches the shim source of the release being installed: a `libvips_shim.<ext>.srchash` file beside it records the SHA-256 of the source it was built from. When it does not match (a bundle cut before the source gained a function, say), install refreshes it from a content-addressed cache, or compiles it, and keeps the old one with a note only when it can do neither. On Windows that compile uses a MinGW toolchain such as MSYS2's UCRT64 (`VIPS_NATIVE_CC` to choose another), links straight against the bundle's DLLs, and replaces the staged shim only after `nm` shows it exports every `vips_shim_*` function the source defines.

AUTHOR
======

  * Matt Doughty <m.doughty@hushmail.com>

COPYRIGHT AND LICENSE
=====================

Copyright 2025-2026 Matt Doughty.

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

