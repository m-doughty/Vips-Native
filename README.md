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

  * **Prebuilt bundle (default)** — fetched from the project's GitHub Releases at install time, sha256-pinned against `resources/checksums.txt`, staged under `$XDG_DATA_HOME/Vips-Native/<binary-tag>/lib/`. Bundles include libvips, libglib, libgio, libgobject, the format loaders (jpeg/png/webp/tiff/heif/avif/jxl/openslide/poppler/magick) and all their transitive deps with `@loader_path` (macOS) / `$ORIGIN` (Linux) / sibling-DLL (Windows) relocations baked in, so the bundle is self-contained.

  * **System libvips** — fallback when the prebuilt download fails or no prebuilt exists for your platform. `Vips::Native` probes for an installed libvips itself and loads it by absolute path: first the dynamic loader's own search variables (`DYLD_LIBRARY_PATH` and `DYLD_FALLBACK_LIBRARY_PATH` on macOS, `LD_LIBRARY_PATH` on Linux, `PATH` on Windows), then the platform's library directories — including Homebrew's per-formula opt kegs, so an **unlinked** `brew install vips` is still found — and finally `ldconfig -p`'s cache listing on Linux.

  * On macOS: `brew install vips`

  * On Debian/Ubuntu: `sudo apt install libvips-dev`

  * **Custom install** — set `VIPS_NATIVE_LIB_DIR=/path/to/dir` to point at a directory containing `libvips.{dylib,so,dll}` and `libgobject-2.0.{dylib,so,dll}`. Caller takes responsibility for ABI compatibility.

Supported platforms
-------------------

  * macOS arm64

  * Linux x86_64 + aarch64 (glibc 2.35+)

  * Windows x86_64 + arm64

Every supported platform ships a working bundle with the varargs shim included.

Build-time environment
----------------------

  * `VIPS_NATIVE_PREFER_SYSTEM=1` — skip prebuilt download, force system libvips at runtime.

  * `VIPS_NATIVE_BINARY_ONLY=1` — refuse to fall back to system libvips; fail loudly if the prebuilt can't be installed (CI / pinned deployments).

  * `VIPS_NATIVE_DATA_DIR=/path` — override staged-libs root (default `$XDG_DATA_HOME` or `~/.local/share`).

  * `VIPS_NATIVE_CACHE_DIR=/path` — override prebuilt-archive download cache (default `$XDG_CACHE_HOME` or `~/.cache`).

  * `VIPS_NATIVE_BINARY_URL=https://…` — override the GitHub Release base URL (custom mirror).

  * `VIPS_NATIVE_KEEP_OLD_STAGES=1` — opt out of the orphaned-stage GC that runs after every install. Use when intentionally pinning multiple versions side-by-side.

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

AUTHOR
======

  * Matt Doughty <m.doughty@hushmail.com>

COPYRIGHT AND LICENSE
=====================

Copyright 2025-2026 Matt Doughty.

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

