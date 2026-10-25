#| Build.rakumod for Vips::Native.
#|
#| Two paths, tried in order:
#|
#|   1. Prebuilt binary archive download from GitHub Releases. One
#|      archive per platform contains libvips + libgobject + libglib
#|      + the format-handling libs (jpeg/png/webp/tiff/gif/heif/avif/
#|      jxl/pdf/svg/openslide, and magick on Windows) and their
#|      transitive deps, all relocated to load from the same directory
#|      (@loader_path on macOS, $ORIGIN on Linux, sibling-DLL on
#|      Windows), plus the THIRD-PARTY.md + LICENSES/ notices kit,
#|      staged with them.
#|      Archive format is .tar.gz on Unix and .zip on Windows. SHA256
#|      verified against bundled resources/checksums.txt. Platforms:
#|      macOS arm64 (macOS 11+), Linux x86_64 + aarch64 (glibc 2.35+),
#|      Windows x86_64 + arm64.
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
#|                                 dir instead of the staged dir;
#|                                 at build, also where the Windows
#|                                 shim compile looks for the DLLs
#|                                 to link against
#|   VIPS_NATIVE_CC=<cc>           C compiler for the varargs shim
#|                                 (a path or a name on PATH);
#|                                 default: cc, gcc, clang

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
	# filenames + cache paths: the five platforms the upstream
	# conda-forge (macOS, Linux) and build-win64-mxe (Windows) prebuilts
	# cover. No darwin-x86_64: conda-forge's Intel macOS libraries need
	# macOS 11, above the floor an Intel prebuilt would have to promise,
	# so Intel Macs — and an x86_64 Raku under Rosetta — install against
	# a system libvips (see no-prebuilt-hint).
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
			with no-prebuilt-hint($*KERNEL.name, $*KERNEL.hardware) {
				note "    $_";
			}
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
			self!cleanup-old-stages($stage);
			return True;
		}

		if $binary-only {
			die "VIPS_NATIVE_BINARY_ONLY=1 set but prebuilt download "
			  ~ "failed for $plat ($binary-tag).";
		}

		note "⚠️  Prebuilt unavailable for $plat ($binary-tag) — "
		   ~ "Native.rakumod will fall back to system libvips.";
		self!try-compile-shim($dist-path, $stage);
		self!cleanup-old-stages($stage);
		True;
	}

    #|( Remove sibling staged dirs for older BINARY_TAGs. zef has no
        uninstall hook, and Build.rakumod is the only place we can
        garbage-collect obsolete staged bundles, so we do it here on
        every install: any sibling under the staged-libs root that
        looks like one of our `binaries-vips-*` dirs and isn't the
        currently-active one gets removed. Without this, an upgrade
        from r7 → r8 leaves the r7 dir on disk; Raku precomp caches
        and stale processes can then load r7's libvips alongside
        r8's, producing the duplicate-Class warnings (and on macOS,
        occasional ObjC class-registration crashes) we hit during
        the Vips::Native 0.4.0 upgrade.

        Set VIPS_NATIVE_KEEP_OLD_STAGES=1 to disable — useful if
        you're intentionally pinning multiple versions side-by-side. )
	method !cleanup-old-stages(IO::Path $current-stage --> Nil) {
		return if %*ENV<VIPS_NATIVE_KEEP_OLD_STAGES>;

		# $current-stage layout is …/Vips-Native/<binary-tag>/lib,
		# so the *tag* dir is one level up and the *root* (where
		# sibling tag dirs live) is two levels up.
		my $current-tag-dir = $current-stage.parent;
		my $root            = $current-tag-dir.parent;
		return unless $root.d;

		# Sanity-check the path looks like ours before we delete
		# anything inside it.
		return unless $root.basename eq 'Vips-Native';

		my Str $current-abs = $current-tag-dir.absolute;

		for $root.dir -> $entry {
			next if $entry.l;
			next unless $entry.d;
			next unless $entry.basename.starts-with('binaries-vips-');
			next if $entry.absolute eq $current-abs;
			say "🧹 Removing orphaned staged dir: { $entry }";
			try {
				remove-tree($entry);
				CATCH { default { note "  (failed to remove: { .message })" } }
			};
		}
	}

    #|( Delete a directory tree, in Raku rather than through C<rm -rf>,
        which a stock Windows does not have. A link is removed as the
        link it is and never followed, so a link inside a stage cannot
        take anything outside it along. )
	our sub remove-tree(IO::Path:D $path --> Nil) {
		if $path.l        { $path.unlink }
		elsif $path.d     { remove-tree($_) for $path.dir; $path.rmdir }
		elsif $path.e     { $path.unlink }
		Nil;
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
		artifact-name($plat);
	}

    #|( Unpack a prebuilt archive into the stage, which is emptied first —
        directories included (the loader modules' C<vips-modules-*>, the
        C<lib/> link beside it, C<LICENSES/>), so nothing of an earlier
        unpack survives into this one. The archive must carry libvips,
        libgobject, libglib and the C<THIRD-PARTY.md> + C<LICENSES/>
        notices kit; the kit is staged with the libraries, so every
        install carries the licence terms of what it installed. )
	method !extract-archive(IO::Path $archive, IO::Path $dest) {
		if $dest.d {
			remove-tree($_) for $dest.dir;
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

		my Str $ext = $*KERNEL.name.lc ~~ /darwin/ ?? 'dylib'
				   !! $*DISTRO.is-win ?? 'dll'
				   !! 'so';
		my @problems = stage-problems($dest, $ext);
		die "❌ Prebuilt archive $archive is not a complete bundle: "
		  ~ @problems.join('; ') ~ '.' if @problems;
	}

    #|( Where downloads and compiled shims are kept between installs.
        Windows sets no HOME, so the POSIX default (C<$HOME/.cache>) used
        to come out as C<./.cache> -- inside whatever directory zef ran
        the build from, which for a local C<zef install .> is the dist's
        own source tree. It is C<%LOCALAPPDATA%> there, as the stage is. )
	method !cache-dir(Str $binary-tag --> IO::Path) {
		my Str $base = %*ENV<VIPS_NATIVE_CACHE_DIR>
			// %*ENV<XDG_CACHE_HOME>
			// ($*DISTRO.is-win
					?? (%*ENV<LOCALAPPDATA>
							// "{%*ENV<USERPROFILE> // '.'}\\AppData\\Local")
					!! "{%*ENV<HOME> // '.'}/.cache");
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
		platform-slug($*KERNEL.name, $*KERNEL.hardware);
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
    #|
    #| Freshness is content-based: a libvips_shim.<ext>.srchash
    #| sidecar next to the staged shim records the SHA-256 of the
    #| src/vips_native_shim.c it was compiled from (prebuilt bundles
    #| should ship it; every successful local compile writes it).
    #| mtimes are meaningless across machines — the dist tarball is
    #| packaged after the binary bundle is built, so on a fresh
    #| ecosystem install the extracted source always looked "newer"
    #| than the bundled shim and forced the compile path even when
    #| the bundle shipped a perfectly good shim (observed in
    #| Notcurses-Native's identical method on a toolchain-less
    #| Alpine CI container, 2026-08-11). Bundles that predate the
    #| sidecar fall back to the mtime comparison -- except on
    #| Windows, where IO::Path.modified is not a file time at all
    #| (MoarVM builds the nanosecond stamp by multiplying a 32-bit
    #| `long`, which puts every file within seconds of 1970), so a
    #| shim with no sidecar there is refreshed from the cache or the
    #| compiler, and kept as it is only when neither can. Successful
    #| compiles also park a content-addressed copy under
    #| <cache>/shims/<src-sha256>.<ext>, because !extract-archive
    #| wipes the stage on every install — restoring from the cache
    #| beats recompiling, and a machine that compiled once never
    #| needs the toolchain again for the same shim source.
    #|
    #| Windows compiles the way build-binaries.yml's Windows job does:
    #| MinGW (or clang in GNU mode) linking straight against the
    #| runtime DLLs with `-l:<file>`, because the bundle carries no
    #| MinGW import libraries. See !compile-shim-windows.
	method !try-compile-shim($dist-path, IO::Path $stage) {
		my Str $os = $*KERNEL.name.lc;
		my Str $ext = $*DISTRO.is-win ?? 'dll'
				   !! $os ~~ /darwin/ ?? 'dylib'
				   !! 'so';
		my IO::Path $shim = $stage.add("libvips_shim.$ext");
		my IO::Path $sidecar = $stage.add("libvips_shim.$ext.srchash");

		my Str $src = "$dist-path/src/vips_native_shim.c";
		return unless $src.IO.e;

		my Str $src-hash = (try self!sha256($src.IO)) // Str;

		# Skip rebuild only if the staged shim was built from the
		# same shim source this dist ships (see doc above). Without
		# this check a prebuilt bundle shipping an older shim than
		# the source tree would silently stay in place and bindings
		# would die at NativeCall time with "Cannot locate symbol …".
		# The mtime branch only serves POSIX bundles that predate the
		# sidecar (and systems where hashing itself failed).
		if $shim.e {
			if $sidecar.e && $src-hash.defined {
				my Str $packed = (try $sidecar.slurp.trim) // '';
				return if $packed eq $src-hash;
				say "🔁 Staged shim was built from different source — refreshing.";
			}
			elsif $*DISTRO.is-win {
				say "🔁 Staged shim has no record of the source it was "
				  ~ "built from — refreshing.";
			}
			else {
				my $src-mtime  = $src.IO.modified // 0;
				my $shim-mtime = $shim.modified  // 0;
				if $shim-mtime >= $src-mtime {
					return;
				}
				say "🔁 Source newer than staged shim — refreshing.";
			}
		}

		# Ensure the stage dir exists — for system-libvips paths
		# nothing else creates it.
		$stage.mkdir;

		# Content-addressed build cache restore — no toolchain needed.
		# The shim is relocatable on every platform we compile for
		# (@loader_path install-name on macOS, no link-time deps on
		# Linux), so a byte-identical copy is as good as a rebuild.
		my IO::Path $shim-cache =
			self!cache-dir(self!binary-tag($dist-path)).add('shims');
		if $src-hash.defined {
			my IO::Path $cached-shim = $shim-cache.add("$src-hash.$ext");
			if $cached-shim.e {
				# Copying over a shim a running process has loaded fails
				# on Windows; that is a note, not a failed install.
				try {
					$cached-shim.copy($shim);
					$shim.chmod(0o755);
					$sidecar.spurt("$src-hash\n");
					CATCH {
						default {
							note "⚠️  Could not restore the varargs shim from "
							   ~ "the build cache into $shim ({.message}) — "
							   ~ "is an application that uses it still running?";
							return;
						}
					}
				}
				say "✅ Restored varargs shim from build cache → $shim.";
				return;
			}
		}

		if $*DISTRO.is-win {
			self!compile-shim-windows($src.IO, $stage, $shim, $sidecar,
									  $src-hash, $shim-cache);
			return;
		}

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
			# Stamp what we compiled (content match beats cross-machine
			# mtime guesses) and park a copy in the build cache so the
			# next install's wiped stage can restore instead of
			# recompiling.
			if $src-hash.defined {
				try $sidecar.spurt("$src-hash\n");
				try {
					$shim-cache.mkdir;
					$shim.copy($shim-cache.add("$src-hash.$ext"));
				}
			}
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

    #|( Windows: compile the shim, prove it exports every function the
        source defines, and only then put it in place.

        Links against the runtime DLLs themselves (C<-l:libvips-42.dll>),
        as build-binaries.yml does: the bundle ships MSVC C<.lib> import
        libraries at most, which GNU ld finds by search but lld in GNU
        mode does not, and C<-l:file> works for both. The DLLs are looked
        for in the stage (the prebuilt bundle), then
        C<$VIPS_NATIVE_LIB_DIR>, then C<PATH> (a system libvips, e.g.
        MSYS2's). The compiler is C<$VIPS_NATIVE_CC>, else the first of
        C<cc>, C<gcc>, C<clang> on C<PATH>; C<nm> is looked for beside
        it first.

        It is compiled to a temporary name in the stage and renamed over
        the old shim only after C<nm> shows every C<vips_shim_*> function
        the source defines among its exports: a link that silently
        produced an empty DLL used to be indistinguishable from a good
        one until a binding died with "Cannot locate symbol". Nothing
        here is fatal -- every way it can fail says why and leaves the
        stage as it was. )
	method !compile-shim-windows(IO::Path $src, IO::Path $stage, IO::Path $shim,
								 IO::Path $sidecar, Str $src-hash,
								 IO::Path $shim-cache) {
		my Str $consequence = $shim.e
			?? "    The staged shim is kept as it is; it may predate this "
			 ~ "release's shim source, and a binding it lacks dies with "
			 ~ "\"Cannot locate symbol\"."
			!! "    Without it, letterbox-to-buffer and strict decoding die "
			 ~ "with \"requires the libvips_shim\".";
		my sub give-up(Str $why --> Nil) {
			note "⚠️  The varargs shim was not compiled: $why";
			note $consequence;
		}

		my @dirs = $stage, |(self!override-lib-dir // ()), |path-dirs();
		my IO::Path $vips = find-file(@dirs, / ^ 'libvips-' \d+ '.dll' $ /);
		my IO::Path $glib = find-file(@dirs, / ^ 'libglib-2.0-' \d+ '.dll' $ /);
		return give-up('no libvips-<N>.dll and libglib-2.0-<N>.dll to link '
			~ 'against (looked in the stage, VIPS_NATIVE_LIB_DIR and PATH).')
			unless $vips.defined && $glib.defined;

		my IO::Path $cc = find-c-compiler(%*ENV<VIPS_NATIVE_CC> // Str, path-dirs());
		return give-up('no C compiler — set VIPS_NATIVE_CC, or put a MinGW '
			~ 'toolchain such as MSYS2 UCRT64\'s on PATH, and reinstall.')
			without $cc;
		my IO::Path $nm = find-executable('nm', ($cc.parent, |path-dirs()));
		return give-up("no `nm` beside $cc or on PATH, so the result "
			~ 'could not be checked.') without $nm;

		my IO::Path $tmp = $stage.add("libvips_shim.$*PID.tmp.dll");
		LEAVE { try $tmp.unlink if $tmp.e }

		my $build = run $cc.absolute, '-O2', '-shared', '-o', $tmp.absolute,
			$src.absolute,
			"-L{$vips.parent.absolute}", "-l:{$vips.basename}",
			"-L{$glib.parent.absolute}", "-l:{$glib.basename}",
			:out, :err;
		$build.out.slurp(:close);
		my Str $build-err = $build.err.slurp(:close);
		return give-up("$cc exited {$build.exitcode}: {$build-err.trim}")
			unless $build.exitcode == 0 && $tmp.e;

		my $list = run $nm.absolute, '-g', '--defined-only', $tmp.absolute,
			:out, :err;
		my Str $listing = $list.out.slurp(:close);
		$list.err.slurp(:close);
		my @missing = missing-exports($src.slurp, $listing);
		return give-up("the compiled DLL does not export {@missing.join(', ')}.")
			if @missing;

		# Renaming over a DLL a running process has loaded fails on
		# Windows. Say so, rather than leave the old one looking fresh.
		try {
			rename $tmp, $shim;
			CATCH {
				default {
					return give-up("could not replace $shim ({.message}) — "
						~ 'is an application that uses it still running?');
				}
			}
		}
		if $src-hash.defined {
			try $sidecar.spurt("$src-hash\n");
			try {
				$shim-cache.mkdir;
				$shim.copy($shim-cache.add("$src-hash.dll"));
			}
		}
		say "✅ Compiled varargs shim with $cc → $shim.";
		Nil;
	}

    #| C<$VIPS_NATIVE_LIB_DIR>, when it names a directory.
	method !override-lib-dir(--> IO::Path) {
		my Str $dir = %*ENV<VIPS_NATIVE_LIB_DIR> // '';
		$dir.chars && (so try $dir.IO.d) ?? $dir.IO !! IO::Path;
	}

	# --- Pure helpers (tested in t/10-build-shim.rakutest and
	#     t/11-build-platform.rakutest) ----------------------------------

    #|( The prebuilt platform slug for an OS name and hardware string as
        Raku reports them (C<$*KERNEL.name>, C<$*KERNEL.hardware>), case
        insensitively; the C<Str> type object when no prebuilt exists for
        that platform, which sends the install to the system-libvips
        fallback. )
	our sub platform-slug(Str $os, Str $hardware --> Str) {
		%PLATFORM-SLUGS{"{($os // '').lc}-{($hardware // '').lc}"} // Str;
	}

    #|( What an unpacked prebuilt in C<$dest> lacks, as messages; empty
        when it is complete. Complete is libvips, libgobject and libglib
        (under any versioned file name with the platform's extension
        C<$ext>), and the notices kit — C<THIRD-PARTY.md> and
        C<LICENSES/> — which is staged with the libraries so an install
        never carries them without their licence terms. )
	our sub stage-problems(IO::Path:D $dest, Str:D $ext --> List) {
		my @problems;
		my @entries = (try $dest.dir) // ();
		for <libvips libgobject-2.0 libglib-2.0> -> Str $lib {
			my @found = @entries.grep({
				my $bn = .basename;
				$bn eq "$lib.$ext"
					|| ($bn.starts-with("$lib.") && $bn.contains(".$ext"))
					|| ($bn.starts-with("$lib-") && $bn.ends-with(".$ext"));
			});
			@problems.push("no $lib.$ext") unless @found;
		}
		@problems.push('no THIRD-PARTY.md') unless so try $dest.add('THIRD-PARTY.md').f;
		@problems.push('no LICENSES/') unless so try $dest.add('LICENSES').d;
		@problems.List;
	}

    #| The release asset a platform slug downloads: C<vips-<slug>.zip> on
    #| Windows, C<vips-<slug>.tar.gz> elsewhere.
	our sub artifact-name(Str:D $plat --> Str) {
		my Str $archive-ext = $plat.starts-with('windows') ?? 'zip' !! 'tar.gz';
		"vips-$plat.$archive-ext";
	}

    #|( What to tell a user on a platform with no prebuilt, beyond "falls
        back to system libvips" — or the C<Str> type object when there is
        nothing more to say. Intel macOS (and an x86_64 Raku under Rosetta,
        which reports x86_64) is the case that needs it: an arm64 libvips
        cannot load into an x86_64 process, so the usual
        C<brew install vips> on Apple Silicon does not help. )
	our sub no-prebuilt-hint(Str $os, Str $hardware --> Str) {
		return Str unless ($os // '').lc eq 'darwin'
					   && ($hardware // '').lc eq 'x86_64';
		'x86_64 macOS (an Intel Mac, or an x86_64 Raku under Rosetta) has no '
		  ~ 'prebuilt. Install an x86_64 libvips — MacPorts, or your own build '
		  ~ '— and Vips::Native loads it from the usual library directories, '
		  ~ 'or point VIPS_NATIVE_LIB_DIR at its lib directory. An arm64 '
		  ~ 'libvips cannot load into an x86_64 process; on Apple Silicon an '
		  ~ 'arm64 Raku gets the prebuilt.';
	}

    #|( The directories on C<PATH>, in order. Windows spells the variable
        C<Path>, and C<%*ENV> is case-sensitive, so the key is found
        case-insensitively. )
	our sub path-dirs(--> List) {
		my Str $key = %*ENV.keys.first({ .fc eq 'path' }) // 'PATH';
		(%*ENV{$key} // '').split($*DISTRO.is-win ?? ';' !! ':')
			.grep(*.chars).map(*.IO).List;
	}

    #|( The first file, in directory order and then in sorted name order,
        whose basename matches C<$pattern>; the C<IO::Path> type object
        when there is none. A directory that is missing or unreadable is
        skipped, not fatal. )
	our sub find-file(@dirs, Regex $pattern --> IO::Path) {
		for @dirs -> IO::Path $dir {
			next unless so try $dir.d;
			for ((try $dir.dir.sort(*.basename)) // ()) -> $entry {
				return $entry if $entry.basename ~~ $pattern && so try $entry.f;
			}
		}
		IO::Path;
	}

    #|( An executable named C<$name> in C<@dirs>, trying C<.exe> on
        Windows; the C<IO::Path> type object when there is none. )
	our sub find-executable(Str $name, @dirs --> IO::Path) {
		my @names = $*DISTRO.is-win && !$name.ends-with('.exe')
			?? ("$name.exe", $name) !! ($name,);
		for @dirs -> IO::Path $dir {
			for @names -> $n {
				my $candidate = $dir.add($n);
				return $candidate if so try $candidate.f;
			}
		}
		IO::Path;
	}

    #|( The C compiler: C<$override> when it is set (a path, or a name
        looked up in C<@dirs>), else the first of C<cc>, C<gcc>, C<clang>
        in C<@dirs>. C<cc> first because MSYS2 points it at each
        environment's own compiler (gcc in UCRT64, clang in CLANGARM64). )
	our sub find-c-compiler(Str $override, @dirs --> IO::Path) {
		if $override.defined && $override.chars {
			my $as-path = $override.IO;
			return $as-path if so try $as-path.f;
			return find-executable($override, @dirs);
		}
		for <cc gcc clang> -> $name {
			with find-executable($name, @dirs) { return $_ }
		}
		IO::Path;
	}

    #|( The C<vips_shim_*> functions C<$source> defines: the names that
        open a line and are followed by an argument list, which is how
        every definition in src/vips_native_shim.c is laid out (the
        return type sits on the line before). Sorted, without repeats. )
	our sub shim-functions(Str $source --> List) {
		$source.lines.map({ ~$0 if / ^ (vips_shim_\w+) \s* '(' / })
			.unique.sort.List;
	}

    #|( The C<vips_shim_*> symbols an C<nm -g --defined-only> listing
        shows in a text section (type C<T>), without the leading
        underscore some COFF targets add. )
	our sub exported-shim-symbols(Str $listing --> List) {
		$listing.lines.map({ ~$0 if / \s 'T' \s+ '_'? (vips_shim_\w+) \s* $ / })
			.unique.sort.List;
	}

    #| The functions C<$source> defines that the C<nm> listing does not
    #| export. Empty when the compiled shim is complete.
	our sub missing-exports(Str $source, Str $listing --> List) {
		my %have is Set = exported-shim-symbols($listing);
		shim-functions($source).grep({ !%have{$_} }).List;
	}
}
