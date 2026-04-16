#| Build.rakumod for Vips::Native.
#|
#| Two paths, tried in order:
#|
#|   1. Prebuilt binary archive download from GitHub Releases. One
#|      archive per platform contains libvips + libgobject + libglib
#|      + the format-handling libs (jpeg/png/webp/tiff/gif/heif/avif)
#|      and their transitive deps, all relocated to load from the
#|      same directory (@loader_path on macOS, $ORIGIN on Linux,
#|      sibling-DLL on Windows). Archive format is .tar.gz on Unix
#|      and .zip on Windows. SHA256 verified against bundled
#|      resources/checksums.txt.
#|
#|   2. Fallback: do nothing, let Native.rakumod resolve `vips` and
#|      `gobject-2.0` via the OS dynamic loader at first FFI call.
#|      This is the original 0.1.x behaviour — works on any system
#|      with libvips installed via the package manager (apt / dnf /
#|      pacman / brew / vcpkg / MSYS2). No source-build attempt
#|      because vips's own dep tree is large enough that a CMake/
#|      meson build would dwarf the whole rest of the install — the
#|      pragmatic fallback is "you install libvips yourself".
#|
#| Linux prebuilts are built on ubuntu-22.04 (glibc 2.35 — see the
#| $MIN-GLIBC constant). On systems with older glibc (Ubuntu 20.04 /
#| Debian 11 / RHEL 8 / etc.) the prebuilt libvips loads but dies at
#| first symbol use with "GLIBC_2.xx not found". Build detects this
#| via `ldd --version` and short-circuits to the system-libvips
#| fallback (Native.rakumod resolves via the OS loader) before the
#| download even happens.
#|
#| Why we don't use META6 resources for the libs: zef hashes every
#| staged resource filename, breaking the inter-lib references baked
#| into libvips (libvips.42.dylib expects libgobject-2.0.0.dylib
#| next to it on disk by that exact name). See Notcurses-Native's
#| Build.rakumod for the full rationale — same problem, same fix.
#|
#| Env-var knobs:
#|
#|   VIPS_NATIVE_PREFER_SYSTEM=1   skip prebuilt download, use
#|                                 system-installed libvips at
#|                                 runtime via the OS loader
#|   VIPS_NATIVE_BINARY_ONLY=1     refuse to fall back to system
#|                                 libvips; fail if prebuilt
#|                                 unavailable
#|   VIPS_NATIVE_BINARY_URL=<url>  override GH release base URL
#|   VIPS_NATIVE_CACHE_DIR=<path>  override download cache dir
#|   VIPS_NATIVE_DATA_DIR=<path>   override staged-libs base dir
#|                                 (defaults to XDG_DATA_HOME)
#|   VIPS_NATIVE_LIB_DIR=<path>    (runtime) load libs from this
#|                                 dir instead of the staged dir

class Build {

    # --- Constants ------------------------------------------------------

    constant $DEFAULT-BASE-URL =
        'https://github.com/m-doughty/Vips-Native/releases/download';

    # Minimum glibc the prebuilt Linux archives are compatible with.
    # The CI workflow builds on ubuntu-22.04 (glibc 2.35); libvips +
    # its format deps reference GLIBC_2.3x versioned symbols so
    # loading on older systems fails with "GLIBC_2.xx not found".
    # Bump in lockstep with the CI runner OS.
    constant $MIN-GLIBC = v2.35;

    # Map (OS, hardware) → platform slug used in release artefact
    # filenames + cache paths. All five platforms covered by upstream
    # build-win64-mxe / Homebrew / conda-forge prebuilts.
    my %PLATFORM-SLUGS =
        'darwin-arm64'    => 'macos-arm64',
        'linux-x86_64'    => 'linux-x86_64-glibc',
        'linux-aarch64'   => 'linux-aarch64-glibc',
        'win32-x86_64'    => 'windows-x86_64',
        'win32-aarch64'   => 'windows-arm64',
        'mswin32-x86_64'  => 'windows-x86_64',
        'mswin32-aarch64' => 'windows-arm64',
    ;

    # --- Entry point ----------------------------------------------------

    method build($dist-path) {
        my Bool $prefer-system = ?%*ENV<VIPS_NATIVE_PREFER_SYSTEM>;
        my Bool $binary-only   = ?%*ENV<VIPS_NATIVE_BINARY_ONLY>;

        my Str $binary-tag = self!binary-tag($dist-path);
        my Str $plat = self!detect-platform;

        # BINARY_TAG into resources so Native.rakumod can locate the
        # staged-libs dir at runtime. Tiny text file — survives zef's
        # resource-hashing rename intact.
        self!stage-binary-tag($dist-path);

        my IO::Path $stage = self!staged-lib-dir($binary-tag);

        if $prefer-system {
            say "VIPS_NATIVE_PREFER_SYSTEM=1 — skipping prebuilt, will use "
              ~ "system libvips via OS dynamic loader.";
            self!try-compile-shim($dist-path, $stage);
            return True;
        }

        without $plat {
            note "⚠️  No prebuilt available for "
                ~ "({$*KERNEL.name}-{$*KERNEL.hardware}); "
                ~ "Native.rakumod will fall back to system libvips.";
            if $binary-only {
                die "VIPS_NATIVE_BINARY_ONLY=1 set but no prebuilt platform "
                  ~ "for { $*KERNEL.name }-{ $*KERNEL.hardware }.";
            }
            self!try-compile-shim($dist-path, $stage);
            return True;
        }

        # Guard: prebuilt Linux archives are built on ubuntu-22.04
        # (glibc $MIN-GLIBC). On older glibc the downloaded libvips
        # loads but dies at first symbol use with "GLIBC_2.xx not
        # found". Detect here and skip the download — Native.rakumod
        # falls through to system libvips at first FFI call, which is
        # this module's existing degraded-mode behaviour.
        if $plat.ends-with('-glibc') {
            my Version $have = self!detect-glibc-version;
            if $have.defined && $have cmp $MIN-GLIBC == Less {
                if $binary-only {
                    die "VIPS_NATIVE_BINARY_ONLY=1 set but system glibc "
                      ~ "$have is older than prebuilt target $MIN-GLIBC "
                      ~ "($plat / $binary-tag). Install a newer libvips "
                      ~ "or unset VIPS_NATIVE_BINARY_ONLY to allow "
                      ~ "system-libvips fallback.";
                }
                note "⚠️  System glibc $have is older than prebuilt "
                   ~ "target $MIN-GLIBC — skipping prebuilt download. "
                   ~ "Native.rakumod will fall back to system libvips "
                   ~ "via the OS dynamic loader.";
                self!try-compile-shim($dist-path, $stage);
                return True;
            }
        }

        if self!try-prebuilt($dist-path, $plat, $binary-tag, $stage) {
            say "✅ Installed prebuilt Vips binaries ($plat) for "
              ~ "$binary-tag → $stage.";
            # Prebuilt bundle should include the shim already, but
            # compile if it doesn't (pre-r6 binary tag, or macOS-
            # only shim on a newly-released platform).
            self!try-compile-shim($dist-path, $stage);
            return True;
        }

        if $binary-only {
            die "VIPS_NATIVE_BINARY_ONLY=1 set but prebuilt download "
              ~ "failed for $plat ($binary-tag).";
        }

        note "⚠️  Prebuilt unavailable for $plat ($binary-tag) — "
           ~ "Native.rakumod will fall back to system libvips.";
        self!try-compile-shim($dist-path, $stage);
        True;
    }

    method !staged-lib-dir(Str $binary-tag --> IO::Path) {
        my Str $base = %*ENV<VIPS_NATIVE_DATA_DIR>
            // %*ENV<XDG_DATA_HOME>
            // ($*DISTRO.is-win
                    ?? (%*ENV<LOCALAPPDATA>
                            // "{%*ENV<USERPROFILE> // '.'}\\AppData\\Local")
                    !! "{%*ENV<HOME> // '.'}/.local/share");
        "$base/Vips-Native/$binary-tag/lib".IO;
    }

    method !stage-binary-tag($dist-path) {
        my IO::Path $src = "$dist-path/BINARY_TAG".IO;
        my IO::Path $dst = "$dist-path/resources/BINARY_TAG".IO;
        $dst.parent.mkdir;
        copy $src, $dst;
    }

    # --- Prebuilt binary path -------------------------------------------

    method !try-prebuilt($dist-path, Str $plat, Str $binary-tag, IO::Path $stage --> Bool) {
        my Str $artifact = self!artifact-name($plat);
        my IO::Path $cache-dir = self!cache-dir($binary-tag);
        my IO::Path $cached = $cache-dir.add($artifact);
        my Str $base-url = %*ENV<VIPS_NATIVE_BINARY_URL> // $DEFAULT-BASE-URL;
        my Str $url = "$base-url/$binary-tag/$artifact";

        unless $cached.e {
            $cache-dir.mkdir;
            say "⬇️  Fetching $artifact from $url";
            my $rc = run 'curl', '-fL', '--progress-bar',
                         '-o', $cached.Str, $url;
            unless $rc.exitcode == 0 {
                $cached.unlink if $cached.e;
                return False;
            }
        }

        my Str $expected = self!expected-sha($dist-path, $artifact);
        without $expected {
            note "No checksum recorded for $artifact in resources/checksums.txt "
                ~ "— refusing prebuilt (bundled checksums are a hard security boundary).";
            return False;
        }

        my Str $actual = self!sha256($cached);
        unless $actual.defined && $actual.lc eq $expected.lc {
            note "Checksum mismatch for $artifact "
                ~ "(expected $expected, got {$actual // 'unknown'}).";
            $cached.unlink;
            return False;
        }

        self!extract-archive($cached, $stage);
        True;
    }

    method !artifact-name(Str $plat --> Str) {
        my Str $archive-ext = $plat.starts-with('windows') ?? 'zip' !! 'tar.gz';
        "vips-$plat.$archive-ext";
    }

    method !extract-archive(IO::Path $archive, IO::Path $dest) {
        if $dest.d {
            for $dest.dir { .unlink if .f || .l }
        }
        $dest.mkdir;

        if $archive.Str.ends-with('.zip') {
            # PowerShell Expand-Archive — see Notcurses-Native for why
            # we avoid `tar` on Windows (GNU tar parses `D:\...` as a
            # remote host).
            my $rc = run 'powershell', '-NoProfile', '-Command',
                "Expand-Archive -LiteralPath '$archive' -DestinationPath '$dest' -Force";
            die "❌ Failed to extract $archive." unless $rc.exitcode == 0;
        }
        else {
            my $rc = run 'tar', '-xzf', $archive.Str, '-C', $dest.Str;
            die "❌ Failed to extract $archive." unless $rc.exitcode == 0;
        }

        # Sanity: libvips + libgobject + libglib must be present
        # (under any versioned variant).
        my Str $ext = $*KERNEL.name.lc ~~ /darwin/ ?? 'dylib'
                   !! $*DISTRO.is-win ?? 'dll'
                   !! 'so';
        for <libvips libgobject-2.0 libglib-2.0> -> Str $lib {
            my @found = $dest.dir.grep({
                my $bn = .basename;
                $bn eq "$lib.$ext"
                    || ($bn.starts-with("$lib.") && $bn.contains(".$ext"))
                    || ($bn.starts-with("$lib-") && $bn.ends-with(".$ext"));
            });
            die "❌ Prebuilt archive missing expected lib: $lib.$ext"
                unless @found;
        }
    }

    method !cache-dir(Str $binary-tag --> IO::Path) {
        my Str $base = %*ENV<VIPS_NATIVE_CACHE_DIR>
            // %*ENV<XDG_CACHE_HOME>
            // "{%*ENV<HOME> // '.'}/.cache";
        "$base/Vips-Native-binaries/$binary-tag".IO;
    }

    method !binary-tag($dist-path --> Str) {
        my IO::Path $file = "$dist-path/BINARY_TAG".IO;
        unless $file.e {
            die "❌ Missing BINARY_TAG file at { $file }. This file must "
              ~ "contain the pinned binary release tag "
              ~ "(e.g. 'binaries-vips-8.15.5-r1').";
        }
        my Str $tag = $file.slurp.trim;
        die "❌ BINARY_TAG file is empty." unless $tag.chars;
        $tag;
    }

    method !expected-sha($dist-path, Str $artifact --> Str) {
        my IO::Path $file = "$dist-path/resources/checksums.txt".IO;
        return Str unless $file.e;
        for $file.slurp.lines -> Str $line {
            my Str $trimmed = $line.trim;
            next if $trimmed eq '' || $trimmed.starts-with('#');
            my @parts = $trimmed.words;
            next unless @parts.elems >= 2;
            return @parts[0] if @parts[1] eq $artifact;
        }
        Str;
    }

    method !sha256(IO::Path $file --> Str) {
        if $*DISTRO.is-win {
            my $proc = run 'certutil', '-hashfile', $file.Str, 'SHA256',
                           :out, :err;
            my $out = $proc.out.slurp(:close);
            $proc.err.slurp(:close);
            for $out.lines -> Str $line {
                my Str $t = $line.subst(/\s+/, '', :g).lc;
                return $t if $t.chars == 64 && $t ~~ /^ <[0..9a..f]>+ $/;
            }
            return Str;
        }
        my $proc = run 'shasum', '-a', '256', $file.Str, :out, :err;
        my $out = $proc.out.slurp(:close);
        $proc.err.slurp(:close);
        $out.words.head;
    }

    method !detect-platform(--> Str) {
        my Str $key = "{$*KERNEL.name.lc}-{$*KERNEL.hardware.lc}";
        %PLATFORM-SLUGS{$key};
    }

    #| Parse `ldd --version` for the system's glibc version. Returns a
    #| Version on glibc systems, undefined Version on musl (ldd --version
    #| exits non-zero) or when ldd is absent / unparseable. Only
    #| meaningful on Linux — don't call on other OSes.
    method !detect-glibc-version(--> Version) {
        my $proc = try { run 'ldd', '--version', :out, :err };
        return Version without $proc;
        my $out = $proc.out.slurp(:close);
        $proc.err.slurp(:close);
        return Version unless $proc.exitcode == 0;
        my $first = $out.lines.head // '';
        if $first ~~ / (\d+ '.' \d+ [ '.' \d+ ]?) \s* $ / {
            return Version.new(~$0);
        }
        Version;
    }

    #| Compile the varargs ABI shim if it doesn't already exist in
    #| $stage (prebuilt bundles from r6+ ship it, but older bundles
    #| and system-libvips fallback paths don't). The shim wraps
    #| libvips's variadic C entry points in honest non-variadic
    #| functions that Raku's NativeCall can marshal correctly on
    #| Apple arm64 (and Linux aarch64 — same AAPCS64 divergence
    #| where named args go in registers but unnamed / variadic args
    #| go on the stack). See src/vips_native_shim.c for the full
    #| rationale.
    #|
    #| Non-fatal: if no C compiler is available, the shim won't be
    #| compiled and FFI.rakumod falls back to direct variadic
    #| bindings — which work on x86_64 (no ABI divergence there).
    #| On arm64 without a shim, image loads may fail with garbage
    #| "no property named `…`" errors; the warning below says so.
    method !try-compile-shim($dist-path, IO::Path $stage) {
        return if $*DISTRO.is-win;  # needs import libs; defer to prebuilt

        my Str $os = $*KERNEL.name.lc;
        my Str $ext = $os ~~ /darwin/ ?? 'dylib' !! 'so';
        my IO::Path $shim = $stage.add("libvips_shim.$ext");
        return if $shim.e;  # already shipped in the prebuilt bundle

        my Str $src = "$dist-path/src/vips_native_shim.c";
        return unless $src.IO.e;

        # Ensure the stage dir exists — for system-libvips paths
        # nothing else creates it.
        $stage.mkdir;

        my @cmd = do given $os {
            when /darwin/ {
                'cc', '-O2', '-dynamiclib', '-fPIC',
                '-install_name', '@loader_path/libvips_shim.dylib',
                # -undefined dynamic_lookup: symbols like
                # vips_image_new_from_file resolve lazily at runtime
                # from libvips (already loaded by NativeCall when the
                # shim is first called). No link-time dep on libvips
                # needed, which is important for the system-libvips
                # fallback path where we don't have a staged
                # libvips.42.dylib to link against.
                '-undefined', 'dynamic_lookup',
                '-o', $shim.Str, $src;
            }
            default {
                'cc', '-O2', '-shared', '-fPIC',
                '-o', $shim.Str, $src;
            }
        };

        my $rc = run |@cmd, :out, :err;
        my $out = $rc.out.slurp(:close);
        my $err = $rc.err.slurp(:close);
        if $rc.exitcode == 0 {
            say "✅ Compiled varargs shim → $shim.";
        }
        else {
            note "⚠️  Could not compile varargs shim ($shim): $err";
            note "    Non-fatal on x86_64 (ABI overlap makes variadic "
               ~ "calls work). On arm64 (macOS / Linux aarch64), image "
               ~ "loads may fail with garbage 'no property named' errors "
               ~ "— install a C toolchain (xcode-select --install / "
               ~ "apt install build-essential) and reinstall Vips::Native.";
        }
    }
}
