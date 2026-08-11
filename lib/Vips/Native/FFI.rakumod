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
#   3. System probe (`_find-system-lib`) — the system-libvips
#      fallback, for people who installed libvips from a package
#      manager. We walk, in order: the dynamic loader's own search
#      env vars (DYLD_LIBRARY_PATH / DYLD_FALLBACK_LIBRARY_PATH on
#      macOS, LD_LIBRARY_PATH on Linux, PATH on Windows), then the
#      platform's standard library dirs (Homebrew prefix *and* its
#      per-formula opt kegs on macOS, Debian multiarch triple dirs
#      + /usr/lib{,64} on Linux), then `ldconfig -p`'s cache listing
#      on Linux. Always yields an ABSOLUTE path.
#   4. Last resort: the fully-formed relative filename
#      ("libvips.dylib" / "libvips.so" / "libvips.dll"), which the
#      loader can still resolve against its own default search
#      paths, and which names something sensible in the error
#      message when it can't.
#
# !!! Step 3/4 must never degrade to a bare short name ('vips'). !!!
#
# Every binding below uses the *Callable* form of the trait —
# `is native(&vips-lib)` — and NativeCall hands a Callable's return
# value to dlopen() / LoadLibrary() VERBATIM. No 'lib' prefix, no
# '.so'/'.dylib' suffix, no version guessing. Verified empirically:
# a callable returning "zzznope" produces dlopen("zzznope"), whereas
# the *string* form `is native("zzznope")` produces
# dlopen("libzzznope.dylib"). Only the string form gets NativeCall's
# name mangling.
#
# That distinction is exactly what 0.6.0 tripped over. Before it,
# these were `constant $vips-lib is export = _resolve-lib(...)` used
# as `is native($vips-lib)` — the string form — so the bare 'vips'
# fallback got mangled into a real filename and the system-libvips
# lane worked. 0.6.0 (bb4a4d3) moved to state-cached subs +
# `is native(&vips-lib)` to stop the resolved path being baked into
# precompiled bytecode (a real bug: see the vips-lib comment for the
# BINARY_TAG-bump staleness it fixes), and the fallback silently
# became dlopen("vips") — "Cannot locate native library 'vips'" on
# every OS. The sub/Callable structure is correct and stays; what
# changed here is what the fallback *returns*. Keep it an absolute
# path or a fully-formed filename, forever.
#
# Also note, for macOS specifically: dyld's default search does NOT
# include /opt/homebrew/lib (confirmed in a DYLD_PRINT_LIBRARIES
# trace), so on Apple silicon even a well-formed "libvips.dylib"
# can't find a Homebrew vips. The probe *must* produce an absolute
# path there.

constant $os = $*KERNEL.name.lc;
constant $ext = $os ~~ /darwin/ ?? 'dylib'
             !! $*DISTRO.is-win ?? 'dll'
             !! 'so';

# Separator for the loader's PATH-shaped env vars.
constant $env-path-sep = $*DISTRO.is-win ?? ';' !! ':';

sub _staged-lib-dir(--> IO::Path) {
    # %?RESOURCES<BINARY_TAG> can misbehave during zef's dep-
    # resolution compile pass — it sometimes returns the resources
    # directory itself (stringified-from-Any) when the resources
    # dict isn't fully populated. Insist on .f (regular file) and
    # try {} the slurp so a bad value falls through cleanly to the
    # system-libvips fallback instead of dying.
    #
    # Returns the IO::Path *type object* (not Nil) on failure:
    # callers pass the result straight into `IO::Path $dir`
    # parameters, and Nil doesn't type-check against that — a
    # missing/unreadable BINARY_TAG would have died inside the
    # binder instead of falling through to the system probe.
    my $res = %?RESOURCES<BINARY_TAG>;
    my Str $tag = '';
    if $res.defined && $res.IO.f {
        $tag = (try $res.IO.slurp.trim) // '';
    }
    return IO::Path unless $tag.chars;
    my Str $base = %*ENV<VIPS_NATIVE_DATA_DIR>
        // %*ENV<XDG_DATA_HOME>
        // ($*DISTRO.is-win
                ?? (%*ENV<LOCALAPPDATA>
                        // "{%*ENV<USERPROFILE> // '.'}\\AppData\\Local")
                !! "{%*ENV<HOME> // '.'}/.local/share");
    "$base/Vips-Native/$tag/lib".IO;
}

# Is $s a dot-separated run of digits ("42", "42.17.1")? Used to
# validate the *version* part of a library filename — the part that
# distinguishes libvips.so.42 (ours) from libvips-cpp.so (not ours).
# Empty string and empty components ("42..1") are rejected.
my sub _digit-run(Str $s --> Bool) {
    return False unless $s.defined && $s.chars;
    so $s.split('.').all ~~ /^ \d+ $/;
}

#| Strict "is this file the shared library named $name?" predicate,
#| for a stem like 'libvips' / 'libgobject-2.0' and an extension
#| like 'so' / 'dylib' / 'dll'. Accepts exactly four shapes:
#|
#|     libvips.so            unversioned / dev symlink
#|     libvips.so.42         ELF SONAME + version tail
#|     libvips.42.dylib      Mach-O compatibility version
#|     libvips-42.dll        Windows versioned DLL
#|
#| …and nothing else. The "nothing else" is the whole point. libvips
#| ships libvips-cpp.<ver> — the C++ binding — in the SAME directory
#| as libvips in every distro package and Homebrew keg. A lenient
#| `starts-with("libvips-")` rule matches it, and directory order is
#| not something we control, so a lenient matcher is a coin flip
#| between the right library and a silent mis-link: libvips-cpp does
#| export the C entry points (it links libvips) so the failure would
#| not be a clean "symbol not found" — we'd just be dragging a whole
#| C++ runtime into the process and pinning ourselves to a second
#| ABI. Same trap for anything else sharing a prefix with
#| libgobject-2.0.
#|
#| $ext is a parameter rather than the module-level constant so the
#| matcher is unit-testable for all three platforms from any host.
my sub _lib-name-match(Str $basename, Str $name, Str $ext --> Bool)
    is export(:INTERNAL)
{
    return True if $basename eq "$name.$ext";

    # ELF: everything after "<name>.<ext>." must be the version.
    my Str $elf-prefix = "$name.$ext.";
    if $basename.starts-with($elf-prefix) {
        return _digit-run($basename.substr($elf-prefix.chars));
    }

    # Mach-O ("<name>.<version>.<ext>") and Windows
    # ("<name>-<version>.<ext>") differ only in the separator, and
    # in both cases the middle slice has to be a pure version.
    my Str $tail = ".$ext";
    return False unless $basename.ends-with($tail);
    return False unless $basename.starts-with("$name.")
                     || $basename.starts-with("$name-");
    _digit-run($basename.substr(
        $name.chars + 1,
        $basename.chars - $name.chars - 1 - $tail.chars));
}

#| Strict lookup of $name in $dir; absolute path, or an undefined
#| Str when the directory holds no match (or doesn't exist, or
#| can't be read — an unreadable /usr/local/lib must not abort the
#| whole probe).
#|
#| Entries are sorted before scanning: real installs routinely hold
#| several acceptable variants (a Homebrew keg has both
#| libvips.dylib and libvips.42.dylib), and a resolver that picks a
#| different one depending on filesystem iteration order is a
#| debugging nightmare. Exact name wins, then the first versioned
#| match in sorted order.
my sub _find-strict(IO::Path $dir, Str $name, Str $ext --> Str)
    is export(:INTERNAL)
{
    return Str unless $dir.defined && $dir.d;

    my $exact = $dir.add("$name.$ext");
    return $exact.absolute if $exact.e;

    for ((try $dir.dir.sort(*.basename)) // ()) -> $entry {
        next unless $entry.e;   # skip dangling symlinks
        return $entry.absolute
            if _lib-name-match($entry.basename, $name, $ext);
    }
    Str;
}

# Lookup inside a directory *we* populated — the $VIPS_NATIVE_LIB_DIR
# override or the staged prebuilt bundle.
#
# Strict first, so libvips.42.dylib always beats a co-packaged
# libvips-cpp.42.dylib regardless of directory order. The historical
# lenient rule stays as a backstop *only here*: these bundles are
# produced by our own build-binaries.yml, so inside them an
# unrecognised-but-genuine filename is a likelier failure mode than
# a wrong-library collision. The system probe below gets no such
# latitude — it walks directories full of other people's libraries.
sub _find-in(IO::Path $dir, Str $name --> Str) {
    with _find-strict($dir, $name, $ext) { return $_ }
    return Str unless $dir.defined && $dir.d;

    for ((try $dir.dir.sort(*.basename)) // ()) -> $entry {
        next unless $entry.e;
        my $bn = $entry.basename;
        return $entry.absolute
            if $bn.starts-with("$name.") && $bn.contains(".$ext");
        return $entry.absolute
            if $bn.starts-with("$name-") && $bn.ends-with(".$ext");
    }
    Str;
}

#| Directories named by the dynamic loader's own search-path env
#| vars, in the order the loader itself consults them.
#|
#| We have to re-implement this search rather than lean on the
#| loader: we hand dlopen an absolute path (see the header block on
#| Callable-verbatim resolution), and once a path contains a slash
#| the loader skips its env-var search entirely. Without this step a
#| user's LD_LIBRARY_PATH / DYLD_LIBRARY_PATH pointing at a custom
#| vips would be silently ignored in favour of a system one.
my sub _loader-env-dirs(--> Seq) {
    my @vars = $os ~~ /darwin/
                    ?? <DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH>
            !! $*DISTRO.is-win
                    ?? <PATH>
            !!         <LD_LIBRARY_PATH>;

    @vars.map({ (%*ENV{$_} // '').split($env-path-sep) })
         .flat
         .grep(*.chars)
         .map(*.IO);
}

# uname -m spellings that don't match the Debian multiarch tuple.
constant %ARCH-ALIASES = %(
    arm64 => 'aarch64',
    amd64 => 'x86_64',
    x64   => 'x86_64',
    i486  => 'i386',
    i586  => 'i386',
    i686  => 'i386',
);

#| Debian/Ubuntu multiarch tuples to try (x86_64-linux-gnu,
#| aarch64-linux-gnu, arm-linux-gnueabihf, …).
#|
#| Belt: compute the tuple from $*KERNEL.hardware, normalising the
#| spellings that differ from uname -m (see %ARCH-ALIASES — notably
#| 'arm64' on kernels that report the Apple/BSD spelling).
#|
#| Braces: also list whatever *-linux-* directories actually exist
#| under /usr/lib and /lib. That covers the suffixed tuples
#| (gnueabihf, musl), 32-bit arm, and any distro convention we
#| haven't met. The computed tuple is ordered first because it's the
#| right answer on every mainstream distro, so the common case
#| resolves before we start probing globbed candidates.
my sub _linux-multiarch-dirs(--> Seq) {
    my Str $hw = ($*KERNEL.hardware // '').lc;
    my Str $arch = %ARCH-ALIASES{$hw} // $hw;

    # Braces around $arch: "$arch-linux-gnu" would parse the hyphens
    # as part of the variable name.
    my Str @tuples = $arch.chars ?? ("{$arch}-linux-gnu",) !! ();
    for </usr/lib /lib> -> Str $root {
        next unless $root.IO.d;
        my @found = ((try $root.IO.dir(test => *.contains('-linux-')))
                        // ()).grep(*.d).map(*.basename).sort;
        @tuples.append: @found;
    }

    @tuples.unique.map({ ("/usr/lib/$_", "/lib/$_") }).flat;
}

#| The platform's conventional library directories, most-specific
#| first.
#|
#| @formulae are Homebrew formula names known to ship the library
#| we're after. They are load-bearing, not a nicety: a brew keg is
#| reachable at <prefix>/opt/<formula>/lib whether or not it's
#| linked into <prefix>/lib, and vips is very commonly left unlinked
#| (it is on this author's machine — /opt/homebrew/lib has no
#| libvips at all, while /opt/homebrew/opt/vips/lib has the whole
#| keg). Probing only <prefix>/lib makes a perfectly good
#| `brew install vips` invisible.
my sub _platform-lib-dirs(@formulae --> Seq) {
    my Str @dirs;

    if $os ~~ /darwin/ {
        # HOMEBREW_PREFIX first (custom prefixes are deliberate),
        # then the two standard ones. /opt/local is MacPorts.
        my Str @prefixes = ((%*ENV<HOMEBREW_PREFIX> // ''),
                            '/opt/homebrew', '/usr/local'
                           ).grep(*.chars).unique;
        for @prefixes -> Str $prefix {
            @dirs.push: "$prefix/lib";
            @dirs.append: @formulae.map({ "$prefix/opt/$_/lib" });
        }
        @dirs.push: '/opt/local/lib';
    }
    elsif !$*DISTRO.is-win {
        @dirs.append: _linux-multiarch-dirs();
        @dirs.append: </usr/local/lib /usr/lib /usr/lib64 /lib /lib64>;
    }
    # Windows has no filesystem convention beyond the DLL search
    # order, which is PATH — already covered by _loader-env-dirs.

    @dirs.unique.map(*.IO);
}

#| Ask `ldconfig -p` for the loader cache listing. Returns '' when
#| ldconfig is missing (musl, non-glibc, or simply not on a
#| non-root PATH — hence the sbin fallbacks) or fails.
#|
#| Note the explicit Proc handling. A *sunk* failing Proc throws
#| when it's GC'd, which is outside the `try` that was supposed to
#| contain it — so the Proc is assigned, its handles are drained,
#| and .exitcode is checked by hand.
my sub _ldconfig-text(--> Str) {
    for <ldconfig /sbin/ldconfig /usr/sbin/ldconfig> -> Str $exe {
        my $proc = try run $exe, '-p', :out, :err;
        next without $proc;
        my Str $out = (try $proc.out.slurp(:close)) // '';
        try $proc.err.slurp(:close);
        next unless (try $proc.exitcode) === 0;
        next unless $out.chars;
        return $out;
    }
    '';
}

#| Pull the first strictly-matching library path out of `ldconfig -p`
#| output. Lines look like (leading tab, parenthesised ABI tags):
#|
#|     libvips.so.42 (libc6,x86-64) => /usr/lib/x86_64-linux-gnu/libvips.so.42
#|
#| Takes the text rather than running the subprocess so it can be
#| unit-tested on any host. It does stat the arrow target, though:
#| the cache regularly outlives the file it points at (package
#| removed with no subsequent `ldconfig` run), and handing dlopen a
#| path that isn't there would turn a recoverable miss into a hard
#| failure. Matching is on the SONAME with the same strict rule as
#| everywhere else, so a `libvips-cpp.so.42` entry is skipped.
my sub _ldconfig-pick(Str $text, Str $name, Str $ext --> Str)
    is export(:INTERNAL)
{
    for ($text // '').lines -> Str $line {
        my ($lhs, $rhs) = $line.split(' => ', 2);
        next unless $rhs.defined;
        my Str $soname = $lhs.trim.words.head // '';
        next unless _lib-name-match($soname, $name, $ext);
        my Str $path = $rhs.trim;
        next unless $path.chars && $path.IO.e;
        return $path;
    }
    Str;
}

#| Locate a system-installed library. Always returns something
#| dlopen-shaped: an absolute path when the probe hits, otherwise
#| the fully-formed relative filename "$name.$ext" so the loader
#| gets one more chance on its default search paths (and so the
#| "Cannot locate native library" message names a real filename).
#|
#| Never returns a bare short name — see the header block.
my sub _find-system-lib(Str $name, @formulae = () --> Str)
    is export(:INTERNAL)
{
    for _loader-env-dirs() -> $dir {
        with _find-strict($dir, $name, $ext) { return $_ }
    }
    for _platform-lib-dirs(@formulae) -> $dir {
        with _find-strict($dir, $name, $ext) { return $_ }
    }
    unless $*DISTRO.is-win || $os ~~ /darwin/ {
        with _ldconfig-pick(_ldconfig-text(), $name, $ext) { return $_ }
    }
    "$name.$ext";
}

#| Resolve a lib by stem (e.g. 'libvips'). Returns an absolute path
#| from the $VIPS_NATIVE_LIB_DIR override, the staged prebuilt
#| bundle or the system probe — falling back to the plain filename
#| "$name.$ext" when nothing is found.
#|
#| :@formulae is the Homebrew formula hint threaded through to the
#| system probe (see _platform-lib-dirs).
#|
#| There is deliberately no "short name" parameter any more. The
#| result of this sub goes to dlopen() verbatim via
#| `is native(&vips-lib)`, so returning 'vips' produces
#| dlopen("vips"), which fails on every OS — that was the 0.6.0
#| system-libvips regression. Anything this sub returns must be an
#| absolute path or a complete filename.
my sub _resolve-lib(Str $name, :@formulae --> Str) is export(:INTERNAL) {
    if (my $override = %*ENV<VIPS_NATIVE_LIB_DIR>) && $override.IO.d {
        with _find-in($override.IO, $name) { return $_ }
    }
    with _find-in(_staged-lib-dir(), $name) { return $_ }
    _find-system-lib($name, @formulae);
}

#| Set an env var that will actually be visible to C `getenv()` in
#| the current process — not just to Raku's `%*ENV` view.
#|
#| Raku's `%*ENV<X> = Y` on macOS writes to a Raku-internal env
#| table and *doesn't* propagate to the Darwin C runtime's
#| `__environ` array; verified empirically by having libvips's
#| `g_getenv("VIPSHOME")` return NULL despite Raku reporting the
#| value set. Same class of issue as Windows' CRT-vs-kernel32
#| env split. Libvips / GLib / anything linked against libc reads
#| via `getenv(3)`, so we call `setenv(3)` directly via NativeCall.
#|
#| We still update `%*ENV` too: (a) Raku code and Raku tooling see
#| the value, (b) subprocess spawns via `run`/`shell` inherit a
#| correct environ.
#|
#| Windows has a separate `_putenv_s` CRT path and we don't use
#| env vars for DLL lookup there (SetDllDirectoryW handles it), so
#| this is a POSIX-only helper.
sub _setenv-c(Str $name, Str $value) {
    %*ENV{$name} = $value;
    return if $*DISTRO.is-win;
    use NativeCall;
    # POSIX setenv: int setenv(const char *name, const char *value, int overwrite);
    # overwrite=1 matches our "caller already checked existing value" contract.
    #
    # Library name varies by platform:
    #   macOS:  'c' → /usr/lib/libSystem.B.dylib (works)
    #   Linux:  'libc.so.6' → glibc. NativeCall's default 'c' lookup
    #           appends '.so' to get 'libc.so', which on Debian/Ubuntu
    #           is a *linker script* (GROUP ( /lib/.../libc.so.6 )),
    #           not a shared object — dlopen chokes on the ELF header
    #           check. The versioned SONAME bypasses that.
    my sub mac_setenv(Str, Str, int32 --> int32)
        is native('c') is symbol('setenv') { * };
    my sub linux_setenv(Str, Str, int32 --> int32)
        is native('libc.so.6') is symbol('setenv') { * };
    if $*KERNEL.name.lc ~~ /darwin/ {
        mac_setenv($name, $value, 1);
    }
    else {
        linux_setenv($name, $value, 1);
    }
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

    # The staged dir merely *existing* does not mean we're running
    # the bundled libraries. On the system-libvips path Build.rakumod
    # still creates it and drops the compiled varargs shim inside
    # (and nothing else) — see !try-compile-shim. Everything below
    # exists purely to correct prefixes baked into OUR bundle, and
    # applying it to a system libvips actively breaks it:
    #
    #   * VIPSHOME would point the system libvips at a directory with
    #     no vips-modules-<M>.<m>/ in it, so every split-out format
    #     loader (pngload, jpegload, heifload, …) quietly vanishes.
    #     Homebrew ships exactly that split layout, so this is the
    #     macOS system lane, not a hypothetical.
    #   * The GIO_MODULE_DIR sentinel would disable system glib's
    #     extension modules for nothing. The duplicate-ObjC-class
    #     crash it defends against needs a *second* libgio in the
    #     process, which can only happen when we've loaded a bundled
    #     one.
    #
    # So gate on libvips itself being staged. Strict matcher, because
    # the dir also holds libvips_shim.<ext> and we want an
    # unambiguous answer to "is the real libvips here".
    return unless _find-strict($lib-dir, 'libvips', $ext).defined;

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

    # Make libvips look at OUR bundle for its modules instead of
    # the builder's compile-time prefix.
    #
    # libvips has no VIPS_MODULEDIR env var (I assumed there was
    # one; there isn't). At init time it uses `vips_guess_prefix`,
    # which tries in order:
    #   1. $VIPSHOME env var
    #   2. Probe `argv[0]` on PATH to find the vips install tree
    #   3. Compile-time VIPS_PREFIX (baked at build)
    #
    # When the entry-point binary isn't `vips` (e.g. `raku`), the
    # argv[0] probe fails and libvips falls back to the compile-time
    # prefix — which on our Homebrew-bottle-sourced macOS bundle is
    # `/opt/homebrew/Cellar/vips/<ver>`. libvips then enumerates
    # Homebrew's vips-modules-<major>.<minor>/ and dlopens each
    # module; those modules have LC_LOAD_DYLIBs against Homebrew's
    # libgio / libglib / etc. — which drags Homebrew's libgio into
    # the process alongside our bundled one and lights up macOS's
    # duplicate-ObjC-class crash.
    #
    # Setting VIPSHOME shortcuts the argv[0] probe. libvips computes
    # the module dir as $VIPSHOME/lib/vips-modules-<M>.<m>/, which
    # is exactly where build-binaries.yml stages our bundled modules
    # (preserving Homebrew's / build-win64-mxe's versioned dir
    # name). Respects a user-set VIPSHOME so people pointing at a
    # custom vips install keep control.
    unless %*ENV<VIPSHOME> {
        _setenv-c('VIPSHOME', $lib-dir.parent.Str);
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
        _setenv-c('GIO_MODULE_DIR', '/dev/null/vips-native-no-gio-modules');
    }
}
_configure-runtime-env();

# Library-path resolvers. State-cached subs rather than `constant`
# bindings: `constant X = _resolve-lib(...)` evaluates at compile
# time and bakes the resolved path into the precompiled bytecode,
# and Rakudo doesn't track `resources/BINARY_TAG` as a precomp
# dependency. A BINARY_TAG bump (which moves staged libs to a new
# versioned directory and may GC the previous one) would leave the
# precomp pointing at the old path — producing "Cannot locate
# native library" errors on freshly installed packages until the
# user nuked `~/.raku/precomp/`. Deferring resolution to first
# sub-call means each process picks up the current tag, regardless
# of when the precomp was built. `state $r` caches the result so
# the lookup is O(1) after the first call. Pair with
# `is native(&vips-lib)` on each binding (not `is native($vips-lib)`)
# so NativeCall invokes the resolver lazily. Non-negotiable
# consequence of the Callable form: whatever these return is passed
# to dlopen unmangled — see the header block.
#
# The `formulae` hints are the Homebrew formulae that ship each
# library — vips's own keg for libvips, glib's for libgobject-2.0.
# They let the system probe find an *unlinked* keg under
# <brew-prefix>/opt/<formula>/lib.
# (List literals, not <vips> — a single-word <> yields a Str, which
# won't bind to :@formulae.)
sub vips-lib    is export { state $r = _resolve-lib('libvips',        formulae => ['vips']); $r }
sub gobject-lib is export { state $r = _resolve-lib('libgobject-2.0', formulae => ['glib']); $r }

# --- Varargs ABI shim ---
#
# libvips's public API is heavily variadic: every loader, saver,
# and operation takes a NULL-terminated (key, value, ...) option
# list. Raku's NativeCall can't mark a bound C function as
# variadic, so it marshals every declared argument according to
# the *non*-variadic ABI. On Apple arm64 specifically, that
# diverges from the variadic ABI — named args go in registers
# (x0–x7) for both, but unnamed / variadic args go on the stack
# for variadic calls and in registers for non-variadic. When our
# binding declares the NULL terminator as a fixed arg, NativeCall
# puts it in register x1, libvips reads the stack looking for the
# first vararg, finds random memory there, and fails with
# "pngload: no property named `<garbage>`".
#
# Linux x86_64 and Windows x64 happen not to exhibit the bug
# because their variadic ABIs reuse the same registers as
# non-variadic for the first several args, so our register-based
# marshal accidentally works. arm64 Apple is the platform that
# actually surfaces the ABI lie.
#
# The fix is a tiny C shim (src/vips_native_shim.c) with honest
# non-variadic signatures. On macOS, build-binaries.yml compiles
# it into libvips_shim.dylib and ships it in the staged bundle
# alongside libvips. When present, we bind the variadic entry
# points through the shim; when absent (other platforms, or a
# future macOS bundle pre-dating this fix), we fall back to the
# direct libvips bindings that happen to work there.
sub _resolve-shim-lib(--> Str) {
    with _staged-lib-dir() -> $dir {
        return Str unless $dir.d;
        with _find-in($dir, 'libvips_shim') { return $_ }
    }
    Str;
}
# Same state-cached-sub pattern as vips-lib / gobject-lib above —
# see those for the precomp-staleness rationale.
sub shim-lib is export { state $r = _resolve-shim-lib(); $r }

# `.f` on a stale path (e.g. cached r7 path, r7 dir since deleted)
# returns a Failure rather than False. `so try ...` collapses both
# False and the absent-file Failure into a clean Bool.
#
# Memoised in a `state` so we only stat the shim once per process
# even though every variadic binding consults it. shim-lib() is
# now a sub call rather than the old `$shim-lib` constant.
sub USE-SHIM(--> Bool) {
    state $r = shim-lib().defined && (so try shim-lib().IO.f);
    $r
}

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

# VipsExtend — fill mode for vips_embed
constant VIPS_EXTEND_BLACK      is export = 0;
constant VIPS_EXTEND_COPY       is export = 1;
constant VIPS_EXTEND_REPEAT     is export = 2;
constant VIPS_EXTEND_MIRROR     is export = 3;
constant VIPS_EXTEND_WHITE      is export = 4;
constant VIPS_EXTEND_BACKGROUND is export = 5;

# vips_init
sub vips_init(Str --> int32) is native(&vips-lib) is export { * }

# VipsImage* is just an OpaquePointer
class VipsImage is repr('CPointer') is export { }

# --- vips_image_new_from_file(const char *, ...) ---
# Shim: vips_shim_image_new_from_file(const char *) → VipsImage*
sub _vips-load-shim(Str --> VipsImage)
    is native(&shim-lib)
    is symbol('vips_shim_image_new_from_file') { * };
sub _vips-load-direct(Str, Str --> VipsImage)
    is native(&vips-lib)
    is symbol('vips_image_new_from_file') { * };
sub vips_image_new_from_file(Str $filename, Str $null = Str --> VipsImage) is export {
    USE-SHIM() ?? _vips-load-shim($filename)
              !! _vips-load-direct($filename, $null);
}

# Get dimensions — non-variadic, bind directly.
sub vips_image_get_width(VipsImage --> int32) is native(&vips-lib) is export { * }
sub vips_image_get_height(VipsImage --> int32) is native(&vips-lib) is export { * }

# --- vips_smartcrop(VipsImage*, VipsImage**, int, int, ...) ---
# Shim: vips_shim_smartcrop(in, out, w, h, interesting) → int
sub _vips-smartcrop-shim(
    VipsImage, CArray[VipsImage], int32, int32, int32 --> int32)
    is native(&shim-lib)
    is symbol('vips_shim_smartcrop') { * };
sub _vips-smartcrop-direct(
    VipsImage, CArray[VipsImage], int32, int32,
    Str, int32, Str --> int32)
    is native(&vips-lib)
    is symbol('vips_smartcrop') { * };
sub vips_smartcrop(
    VipsImage $in, CArray[VipsImage] $out,
    int32 $w, int32 $h,
    Str $key, int32 $interesting, Str $null --> int32
) is export {
    USE-SHIM() ?? _vips-smartcrop-shim($in, $out, $w, $h, $interesting)
              !! _vips-smartcrop-direct($in, $out, $w, $h, $key, $interesting, $null);
}

# --- vips_resize(VipsImage*, VipsImage**, double, ...) ---
# Shim: vips_shim_resize(in, out, scale, kernel) → int
sub _vips-resize-shim(
    VipsImage, CArray[VipsImage], num64, int32 --> int32)
    is native(&shim-lib)
    is symbol('vips_shim_resize') { * };
sub _vips-resize-direct(
    VipsImage, CArray[VipsImage], num64, Str, int32, Str --> int32)
    is native(&vips-lib)
    is symbol('vips_resize') { * };
sub vips_resize(
    VipsImage $in, CArray[VipsImage] $out,
    num64 $scale,
    Str $key, int32 $kernel, Str $null --> int32
) is export {
    USE-SHIM() ?? _vips-resize-shim($in, $out, $scale, $kernel)
              !! _vips-resize-direct($in, $out, $scale, $key, $kernel, $null);
}

# --- vips_pngsave(VipsImage*, const char *, ...) ---
# Shim: vips_shim_pngsave(in, filename) → int
sub _vips-pngsave-shim(VipsImage, Str --> int32)
    is native(&shim-lib)
    is symbol('vips_shim_pngsave') { * };
sub _vips-pngsave-direct(VipsImage, Str, Str --> int32)
    is native(&vips-lib)
    is symbol('vips_pngsave') { * };
sub vips_pngsave(VipsImage $in, Str $filename, Str $null --> int32) is export {
    USE-SHIM() ?? _vips-pngsave-shim($in, $filename)
              !! _vips-pngsave-direct($in, $filename, $null);
}

# --- vips_flatten(VipsImage*, VipsImage**, ...) ---
# Alpha-composite over a (R, G, B) background. The variadic option
# list takes a VipsArrayDouble * for `background`, which is awkward
# to construct from Raku, so this binding is shim-only — the direct
# variadic path would need separate bindings for vips_array_double_new
# / vips_area_unref. If the shim isn't compiled (no toolchain on
# install), vips_flatten dies with a clear message rather than
# silently corrupting memory.
sub _vips-flatten-shim(
    VipsImage, CArray[VipsImage], num64, num64, num64 --> int32)
    is native(&shim-lib)
    is symbol('vips_shim_flatten') { * };
sub vips_flatten(
    VipsImage $in, CArray[VipsImage] $out,
    num64 $r = 255e0, num64 $g = 255e0, num64 $b = 255e0 --> int32
) is export {
    die "vips_flatten requires the libvips_shim. Reinstall Vips::Native "
        ~ "with a working C toolchain (xcode-select --install on macOS, "
        ~ "apt install build-essential on Debian)."
        unless USE-SHIM();
    _vips-flatten-shim($in, $out, $r, $g, $b);
}

# --- vips_embed(VipsImage*, VipsImage**, x, y, w, h, ...) ---
# Place input at (x, y) inside a w×h canvas, filling around it with
# either a fixed colour (extend = VIPS_EXTEND_BACKGROUND) or one of
# the other VipsExtend modes. Same shim-only constraint as flatten.
sub _vips-embed-shim(
    VipsImage, CArray[VipsImage],
    int32, int32, int32, int32, int32,
    num64, num64, num64 --> int32)
    is native(&shim-lib)
    is symbol('vips_shim_embed') { * };
sub vips_embed(
    VipsImage $in, CArray[VipsImage] $out,
    int32 $x, int32 $y, int32 $width, int32 $height,
    int32 $extend = VIPS_EXTEND_BACKGROUND,
    num64 $r = 255e0, num64 $g = 255e0, num64 $b = 255e0 --> int32
) is export {
    die "vips_embed requires the libvips_shim. Reinstall Vips::Native "
        ~ "with a working C toolchain."
        unless USE-SHIM();
    _vips-embed-shim($in, $out, $x, $y, $width, $height, $extend, $r, $g, $b);
}

# --- vips_image_new_from_buffer(const void *, size_t, const char *, ...) ---
# Decode an encoded image (PNG/JPEG/WebP/...) from an in-memory buffer.
# Shim: vips_shim_image_new_from_buffer(buf, len) → VipsImage*.
#
# IMPORTANT lifetime contract: libvips does NOT copy `buf`; it reads it
# lazily as pixels are computed. The CARRAY the caller passes here must
# stay alive until the returned VipsImage (and everything derived from
# it) has been materialised (vips_image_write_to_memory / *_buffer) and
# unref'd. Callers in Vips::Native root the backing CArray via LEAVE.
sub _vips-from-buffer-shim(Pointer, size_t --> VipsImage)
    is native(&shim-lib)
    is symbol('vips_shim_image_new_from_buffer') { * };
sub _vips-from-buffer-direct(Pointer, size_t, Str, Str --> VipsImage)
    is native(&vips-lib)
    is symbol('vips_image_new_from_buffer') { * };
sub vips_image_new_from_buffer(Pointer $buf, size_t $len --> VipsImage) is export {
    USE-SHIM() ?? _vips-from-buffer-shim($buf, $len)
              !! _vips-from-buffer-direct($buf, $len, "", Str);
}

# --- vips_colourspace(VipsImage*, VipsImage**, VipsInterpretation, ...) ---
# Shim-only (same variadic-ABI constraint as flatten / embed). Converts
# to a target colourspace; sRGB normalises greyscale / CMYK / 16-bit to
# 8-bit sRGB and passes any alpha band through unchanged.
sub _vips-colourspace-shim(VipsImage, CArray[VipsImage], int32 --> int32)
    is native(&shim-lib)
    is symbol('vips_shim_colourspace') { * };
sub vips_colourspace(
    VipsImage $in, CArray[VipsImage] $out, int32 $space --> int32
) is export {
    die "vips_colourspace requires the libvips_shim. Reinstall Vips::Native "
        ~ "with a working C toolchain."
        unless USE-SHIM();
    _vips-colourspace-shim($in, $out, $space);
}

# --- vips_addalpha(VipsImage*, VipsImage**, ...) ---
# Shim-only. Appends an opaque (255) alpha band. Call only when the
# source has < 4 bands — libvips raises on a double-add.
sub _vips-addalpha-shim(VipsImage, CArray[VipsImage] --> int32)
    is native(&shim-lib)
    is symbol('vips_shim_addalpha') { * };
sub vips_addalpha(VipsImage $in, CArray[VipsImage] $out --> int32) is export {
    die "vips_addalpha requires the libvips_shim. Reinstall Vips::Native "
        ~ "with a working C toolchain."
        unless USE-SHIM();
    _vips-addalpha-shim($in, $out);
}

# --- vips_pngsave_buffer(VipsImage*, void **buf, size_t *len, ...) ---
# Shim-only. Encodes to PNG in memory; on success $buf[0] is a g_malloc'd
# Pointer of $len[0] bytes — release it with vips_shim_free.
sub _vips-pngsave-buffer-shim(VipsImage, CArray[Pointer], CArray[uint64] --> int32)
    is native(&shim-lib)
    is symbol('vips_shim_pngsave_buffer') { * };
sub vips_pngsave_buffer(
    VipsImage $in, CArray[Pointer] $buf, CArray[uint64] $len --> int32
) is export {
    die "vips_pngsave_buffer requires the libvips_shim. Reinstall Vips::Native "
        ~ "with a working C toolchain."
        unless USE-SHIM();
    _vips-pngsave-buffer-shim($in, $buf, $len);
}

# --- vips_image_write_to_memory(VipsImage *, size_t *) → void * ---
# Non-variadic, so we bind it directly without going through the shim.
# Returns a g_malloc'd buffer of width*height*bands bytes (UCHAR
# format) or NULL on error. Pair with vips_shim_free to release.
sub vips_image_write_to_memory(
    VipsImage, CArray[uint64] --> Pointer[uint8])
    is native(&vips-lib) is export { * }

# Free a buffer returned by vips_image_write_to_memory. NULL-safe.
sub vips_shim_free(Pointer)
    is native(&shim-lib)
    is symbol('vips_shim_free') is export { * };

# Image format / band introspection — needed to validate that a
# write_to_memory result has the expected layout.
sub vips_image_get_bands(VipsImage --> int32)
    is native(&vips-lib) is export { * }
sub vips_image_get_format(VipsImage --> int32)
    is native(&vips-lib) is export { * }

# VipsBandFormat — the elements vips_image_get_format returns
constant VIPS_FORMAT_NOTSET is export = -1;
constant VIPS_FORMAT_UCHAR  is export = 0;
constant VIPS_FORMAT_CHAR   is export = 1;
constant VIPS_FORMAT_USHORT is export = 2;
constant VIPS_FORMAT_SHORT  is export = 3;
constant VIPS_FORMAT_UINT   is export = 4;
constant VIPS_FORMAT_INT    is export = 5;
constant VIPS_FORMAT_FLOAT  is export = 6;
constant VIPS_FORMAT_DOUBLE is export = 9;

# VipsInterpretation — colourspace tags accepted by vips_colourspace.
# sRGB is the 8-bit display colourspace; converting to it normalises
# greyscale / CMYK / 16-bit sources to 3-band (+ optional alpha) UCHAR.
constant VIPS_INTERPRETATION_sRGB is export = 22;

# Memory cleanup for images (from GLib/GObject)
sub g_object_unref(VipsImage) is native(&gobject-lib) is export { * }

