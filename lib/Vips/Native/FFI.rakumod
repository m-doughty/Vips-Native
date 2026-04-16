unit module Vips::Native::FFI;

use NativeCall;

# === Library resolution ===
#
# Resolve libvips and libgobject-2.0 in this order:
#
#   1. $VIPS_NATIVE_LIB_DIR env var — explicit override. Full path
#      to a directory containing both libs. Escape hatch for custom
#      vips builds; you take responsibility for ABI.
#   2. XDG-staged dir (Build.rakumod's prebuilt-download path) —
#      $XDG_DATA_HOME/Vips-Native/<binary-tag>/lib/. Filenames
#      preserved (libvips.42.dylib, libgobject-2.0.0.so, etc.) so
#      the inter-lib refs vips bakes in via @loader_path / $ORIGIN /
#      sibling-DLL all resolve correctly.
#   3. Bare library name — let the OS dynamic loader find it via
#      LD_LIBRARY_PATH / DYLD_FALLBACK_LIBRARY_PATH / Windows DLL
#      search order. This is the system-libvips fallback (matches
#      0.1.x behaviour for systems with libvips installed via
#      package manager).

constant $os = $*KERNEL.name.lc;
constant $ext = $os ~~ /darwin/ ?? 'dylib'
             !! $*DISTRO.is-win ?? 'dll'
             !! 'so';

sub _staged-lib-dir(--> IO::Path) {
    # %?RESOURCES<BINARY_TAG> can misbehave during zef's dep-
    # resolution compile pass — it sometimes returns the resources
    # directory itself (stringified-from-Any) when the resources
    # dict isn't fully populated. Insist on .f (regular file) and
    # try {} the slurp so a bad value falls through cleanly to the
    # system-libvips fallback instead of dying.
    my $res = %?RESOURCES<BINARY_TAG>;
    my Str $tag = '';
    if $res.defined && $res.IO.f {
        $tag = (try $res.IO.slurp.trim) // '';
    }
    return Nil unless $tag.chars;
    my Str $base = %*ENV<VIPS_NATIVE_DATA_DIR>
        // %*ENV<XDG_DATA_HOME>
        // ($*DISTRO.is-win
                ?? (%*ENV<LOCALAPPDATA>
                        // "{%*ENV<USERPROFILE> // '.'}\\AppData\\Local")
                !! "{%*ENV<HOME> // '.'}/.local/share");
    "$base/Vips-Native/$tag/lib".IO;
}

# Find a lib by basename (without ext) in $dir, accepting versioned
# variants since vips ships per-platform names like libvips.42.dylib,
# libvips.so.42, libvips-42.dll.
sub _find-in(IO::Path $dir, Str $name --> Str) {
    return Str unless $dir.defined && $dir.d;
    my $exact = $dir.add("$name.$ext");
    return $exact.Str if $exact.e;

    for $dir.dir -> $entry {
        next unless $entry.e;
        my $bn = $entry.basename;
        return $entry.Str if $bn.starts-with("$name.") && $bn.contains(".$ext");
        return $entry.Str if $bn.starts-with("$name-") && $bn.ends-with(".$ext");
    }
    Str;
}

#| Resolve a lib by name. Returns either an absolute path (env
#| override or XDG-staged) or the bare short name (system loader
#| fallback — e.g. 'vips', 'gobject-2.0' — which lets NativeCall
#| use the OS dynamic loader to find a system-installed libvips).
sub _resolve-lib(Str $name, Str $short-name --> Str) {
    if (my $override = %*ENV<VIPS_NATIVE_LIB_DIR>) && $override.IO.d {
        with _find-in($override.IO, $name) { return $_ }
    }
    with _find-in(_staged-lib-dir(), $name) { return $_ }
    $short-name;
}

#| Runtime env setup for the staged-bundle case. Must run before
#| NativeCall evaluates the `is native(...)` bindings below, since
#| the first call through any of them triggers `LoadLibrary` /
#| `dlopen` on libvips, which in turn resolves libvips's own
#| dependencies using the then-current environment.
#|
#| Two problems we fix here:
#|
#|   * Windows DLL search order: when NativeCall loads libvips-42.dll
#|     by absolute path, Windows resolves libvips's own dep DLLs
#|     (libglib-2.0-0.dll, libgobject-2.0-0.dll, libintl-8.dll, …)
#|     starting from the *loading process's* directory (raku.exe),
#|     not from libvips-42.dll's directory. Linux's `$ORIGIN` rpath
#|     has no equivalent here. Prepending the staged lib dir to
#|     PATH makes the sibling DLLs findable. (No-op on macOS/Linux
#|     — @loader_path / $ORIGIN handles sibling lookup natively.)
#|
#|   * libvips 8.15+ format loaders (pngload, jpegload, heifload, …)
#|     live as separately-dlopen'd modules under $VIPS_MODULEDIR.
#|     Homebrew and build-win64-mxe both ship the split layout;
#|     conda-forge's Linux build still has loaders baked into
#|     libvips.so.42, which is why Linux passes the full test suite
#|     without this env set. We point VIPS_MODULEDIR at the sibling
#|     vips-modules dir in the bundle — harmless on builds where it
#|     doesn't exist, load-bearing on the ones where it does.
sub _configure-runtime-env() {
    # Respect $VIPS_NATIVE_LIB_DIR override — user pointed us at a
    # custom vips install and takes responsibility for its env.
    return if %*ENV<VIPS_NATIVE_LIB_DIR>;

    my $lib-dir = _staged-lib-dir();
    return without $lib-dir;
    return unless $lib-dir.d;

    if $*DISTRO.is-win {
        my $lib-str = $lib-dir.Str;

        # Belt: prepend to PATH so any loader search that consults
        # it (including third-party tools / subprocess spawns) sees
        # the staged lib dir.
        my $current = %*ENV<PATH> // '';
        unless $current.starts-with("$lib-str;") || $current eq $lib-str {
            %*ENV<PATH> = "$lib-str;$current";
        }

        # Braces: Raku's `%*ENV` writes go through the CRT
        # (`_putenv`), which on some Windows + CRT combinations
        # doesn't propagate to `GetEnvironmentVariableW` — the
        # function the Win32 loader consults when resolving
        # dependent DLLs during LoadLibrary(absolute-path). Call
        # kernel32's SetDllDirectoryW directly so the loader
        # definitely sees our staged dir regardless of CRT state.
        #
        # kernel32.dll is pre-loaded in every Windows process, so
        # `is native('kernel32')` resolves cheaply without a
        # disk probe. Using the W (wide) variant because the CI
        # runner's home path is pure ASCII today, but end users'
        # paths (especially %LOCALAPPDATA%) routinely contain
        # non-ASCII when accounts have accented names.
        #
        # SetDllDirectory's semantics: it *replaces* the "extra"
        # DLL search entry (Win32 supports one at a time, not a
        # list). This module is the only thing in the process that
        # touches it, so replace is fine; if a future module also
        # wants to set it, switch to AddDllDirectory
        # (Windows 8+ only, additive, paired with
        # SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_USER_DIRS)).
        {
            use NativeCall;
            # NativeCall encoding name is `utf16` (no dash). The W
            # (wide) variant takes UTF-16LE on Windows — which is
            # what Raku's `utf16` marshals to on little-endian hosts
            # (every Windows target we support is LE).
            my sub SetDllDirectoryW(Str is encoded('utf16'))
                returns int32 is native('kernel32') { * };
            SetDllDirectoryW($lib-str);
        }
    }

    # Bundle layout: $lib-dir holds libvips + its siblings; format
    # loader plugins live in $lib-dir/vips-modules/ (child, not
    # sibling — the tarball is extracted into $lib-dir and contains
    # a top-level vips-modules/ entry). Only set if present — avoids
    # pointing vips at a non-existent dir, which would make it skip
    # its default search and miss system-installed modules entirely.
    my $modules = $lib-dir.add('vips-modules');
    if $modules.d && !%*ENV<VIPS_MODULEDIR> {
        %*ENV<VIPS_MODULEDIR> = $modules.Str;
    }

    # Disable GIO extension-module loading entirely.
    #
    # Our bundled libgio was compiled with GIO_MODULE_DIR baked to
    # the builder's prefix (Homebrew's cellar on macOS, conda's
    # prefix on Linux). At g_type_init time, GIO scans that dir and
    # dlopens every .so — and those modules are linked against the
    # *builder's* libgio, not our bundled one. On macOS specifically
    # this ends with two libgio-2.0.0.dylibs loaded and ObjC classes
    # (GNotificationCenterDelegate, GCocoaNotificationBackend, etc.)
    # registered twice, which macOS treats as a duplicate-class
    # error and bails.
    #
    # libvips only needs GIO's core type system (GObject, GType),
    # which is statically linked into libgio — the extension modules
    # (GSettings backends, proxy resolvers, network monitors) aren't
    # touched. Pointing GIO_MODULE_DIR at a guaranteed-nonexistent
    # path makes GIO find nothing to load; g_dir_open returns NULL
    # silently without logging.
    #
    # /dev/null is a file on every POSIX system, so /dev/null/anything
    # can never be a valid directory path — safe portable sentinel.
    # Windows uses NUL; we gate the whole block on POSIX since the
    # duplicate-class crash is ObjC-specific and GIO's module system
    # doesn't present the same way on Windows.
    if $os ~~ /darwin|linux/ && !%*ENV<GIO_MODULE_DIR> {
        %*ENV<GIO_MODULE_DIR> = '/dev/null/vips-native-no-gio-modules';
    }
}
_configure-runtime-env();

constant $vips-lib    is export = _resolve-lib('libvips',         'vips');
constant $gobject-lib is export = _resolve-lib('libgobject-2.0',  'gobject-2.0');

# VipsInteresting
constant VIPS_INTERESTING_NONE      is export = 0;
constant VIPS_INTERESTING_CENTRE    is export = 1;
constant VIPS_INTERESTING_ENTROPY   is export = 2;
constant VIPS_INTERESTING_ATTENTION is export = 3;
constant VIPS_INTERESTING_LOW       is export = 4;
constant VIPS_INTERESTING_HIGH      is export = 5;
constant VIPS_INTERESTING_ALL       is export = 6;

# VipsKernel
constant VIPS_KERNEL_NEAREST    is export = 0;
constant VIPS_KERNEL_LINEAR     is export = 1;
constant VIPS_KERNEL_CUBIC      is export = 2;
constant VIPS_KERNEL_MITCHELL   is export = 3;
constant VIPS_KERNEL_LANCZOS2   is export = 4;
constant VIPS_KERNEL_LANCZOS3   is export = 5;
constant VIPS_KERNEL_MKS2013    is export = 6;
constant VIPS_KERNEL_MKS2021    is export = 7;

# VIPS booleans (for gboolean)
constant VIPS_FALSE is export = 0;
constant VIPS_TRUE  is export = 1;

# vips_init
sub vips_init(Str --> int32) is native($vips-lib) is export { * }

# VipsImage* is just an OpaquePointer
class VipsImage is repr('CPointer') is export { }

# vips_image_new_from_file(const char* name, ...)
sub vips_image_new_from_file(Str, Str --> VipsImage) is native($vips-lib) is export { * }

# Get dimensions
sub vips_image_get_width(VipsImage --> int32) is native($vips-lib) is export { * }
sub vips_image_get_height(VipsImage --> int32) is native($vips-lib) is export { * }

# Smartcrop
sub vips_smartcrop(
	VipsImage,              # in
	CArray[VipsImage],      # out (pointer to VipsImage*)
	int32,                     # width
	int32,                     # height
	Str,                       # "interesting"
	int32,                     # VIPS_INTERESTING_*
	Str                        # NULL terminator for varargs
) returns int32 is native($vips-lib) is export { * }

# Resize
sub vips_resize(
	VipsImage,                 # in
	CArray[VipsImage],         # out (pointer to VipsImage*)
	num64,                     # scale
	Str,                       # "kernel"
	int32,                     # VIPS_KERNEL_*
	Str                        # NULL terminator for varargs
) returns int32 is native($vips-lib) is export { * }

# Save PNG
sub vips_pngsave(
	VipsImage,                  # in
	Str,                        # filename
	Str                         # NULL terminator for varargs
) returns int32 is native($vips-lib) is export { * }

# Memory cleanup for images (from GLib/GObject)
sub g_object_unref(VipsImage) is native($gobject-lib) is export { * }

