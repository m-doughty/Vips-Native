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

    # Map (OS, hardware) → platform slug used in release artefact
    # filenames + cache paths. Windows arm64 deliberately not mapped —
    # libvips/build-win64-mxe doesn't ship arm64 yet, so those users
    # fall through to the system-libvips path.
    my %PLATFORM-SLUGS =
        'darwin-arm64'    => 'macos-arm64',
        'linux-x86_64'    => 'linux-x86_64-glibc',
        'linux-aarch64'   => 'linux-aarch64-glibc',
        'win32-x86_64'    => 'windows-x86_64',
        'mswin32-x86_64'  => 'windows-x86_64',
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
            return True;
        }

        if self!try-prebuilt($dist-path, $plat, $binary-tag, $stage) {
            say "✅ Installed prebuilt Vips binaries ($plat) for "
              ~ "$binary-tag → $stage.";
            return True;
        }

        if $binary-only {
            die "VIPS_NATIVE_BINARY_ONLY=1 set but prebuilt download "
              ~ "failed for $plat ($binary-tag).";
        }

        note "⚠️  Prebuilt unavailable for $plat ($binary-tag) — "
           ~ "Native.rakumod will fall back to system libvips.";
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
}
