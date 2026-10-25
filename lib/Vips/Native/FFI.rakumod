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

# The spelling of the PATH entry THIS process was handed. Windows
# environment names are case-insensitive and the OS spells it `Path`,
# but Raku's %*ENV is a plain case-sensitive Hash: reading `<PATH>`
# there finds nothing and writing it adds a second key. msys2 shells
# and Unix hand us `PATH`. Ask the hash rather than assume.
my sub _env-path-key(--> Str) {
	%*ENV.keys.first({ .fc eq 'path' }) // 'PATH'
}

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
sub _find-in(IO::Path $dir, Str $name --> Str) is export(:INTERNAL) {
	with _find-strict($dir, $name, $ext) { return $_ }
	return Str unless $dir.defined && $dir.d;

	for ((try $dir.dir.sort(*.basename)) // ()) -> $entry {
		next unless $entry.e;
		my $bn = $entry.basename;
		# The freshness sidecar Build.rakumod parks beside the shim
		# (libvips_shim.dll.srchash) starts with the name and contains
		# the extension. It is a text file: never hand it to dlopen.
		next if $bn.ends-with('.srchash');
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
					?? (_env-path-key(),)
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
	with _find-in(_override-lib-dir(), $name) { return $_ }
	with _find-in(_staged-lib-dir(), $name) { return $_ }
	_find-system-lib($name, @formulae);
}

#| The C<$VIPS_NATIVE_LIB_DIR> override, as a directory, or the
#| C<IO::Path> type object when it is unset, empty, or names something
#| that is not a directory. One answer for every consumer -- the
#| library resolver, the shim resolver and the runtime-env setup --
#| so a mistyped override is ignored by all three alike instead of
#| skipping the env setup for libraries the resolver then loads from
#| the stage anyway.
my sub _override-lib-dir(--> IO::Path) is export(:INTERNAL) {
	my Str $dir = %*ENV<VIPS_NATIVE_LIB_DIR> // '';
	return IO::Path unless $dir.chars;
	my IO::Path $io = $dir.IO;
	(so try $io.d) ?? $io !! IO::Path;
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
#|   * libvips's optional format loaders (heifload, jxlload,
#|     openslideload, pdfload; Windows: magickload) live in separately
#|     dlopen'd modules, in a vips-modules-<M>.<m>/ directory that
#|     libvips finds from $VIPSHOME — every bundle ships that split
#|     layout (conda-forge's macOS and Linux builds alike, and
#|     build-win64-mxe on Windows). Left alone, libvips would look
#|     under the prefix it was BUILT in instead, and find nothing (or
#|     worse, a builder's copy). We point VIPSHOME at the bundle so the
#|     staged modules are the ones that load.
sub _configure-runtime-env() {
	# A $VIPS_NATIVE_LIB_DIR override that holds libvips is the user's
	# own vips install, and its environment (VIPSHOME, GIO modules) is
	# the user's to set. What is not optional is the one thing without
	# which its libvips cannot load at all on Windows: the DLLs beside
	# it must be findable (see the first bullet above). An override
	# that is unset, is not a directory, or does not hold libvips is no
	# override for libvips — the resolver loads the staged one, so the
	# staged one's setup below applies.
	with _override-lib-dir() -> $override {
		if _find-strict($override, 'libvips', $ext).defined {
			_use-dll-dir($override) if $*DISTRO.is-win;
			return;
		}
	}

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

	_use-dll-dir($lib-dir) if $*DISTRO.is-win;

	# Make libvips look at OUR bundle for its modules instead of
	# the builder's compile-time prefix.
	#
	# libvips has no VIPS_MODULEDIR env var. At init time it takes its
	# prefix from, in order:
	#   1. $VIPSHOME
	#   2. the configure-time prefix, if <its libdir>/vips-modules-<M>.<m>
	#      exists there (a builder's machine, a user's conda env at the
	#      same path)
	#   3. `argv[0]` looked up on PATH (never `vips` for us: it's `raku`)
	#   4. the configure-time prefix regardless
	# and then loads every module in <libdir>/vips-modules-<M>.<m>/, where
	# libdir is that prefix followed by the last path component of the
	# configure-time libdir. Without VIPSHOME, then, a bundle loads its
	# modules from the build machine's prefix if one happens to exist
	# there (dragging that prefix's libgio / libglib into the process
	# beside ours: on macOS, duplicate Objective-C classes and a crash)
	# and otherwise loads none at all.
	#
	# Where VIPSHOME has to point is where the two readings of "the last
	# path component" diverge. conda-forge's macOS libvips gets "/lib";
	# its Linux libvips gets nothing (GCC folds the strrchr() into a
	# pointer into the string literal at compile time, and conda's
	# install-time prefix relocation then shortens the string under it).
	# On macOS and Linux VIPSHOME is therefore the staged lib directory
	# itself: the Linux build finds <lib>/vips-modules-<M>.<m>/ directly,
	# and the macOS build finds <lib>/lib/vips-modules-<M>.<m>, a link
	# both bundles carry to that same directory
	# (scripts/ci/bundle-*.sh). On Windows the build-win64-mxe libvips
	# was never relocated and reads "/lib", so VIPSHOME is the stage's
	# parent and the modules sit in <stage>/lib/vips-modules-<M>.<m>/.
	# build-binaries.yml's loader probe runs each POSIX bundle under
	# exactly this setting and fails the release if any module is not
	# found.
	#
	# A user-set VIPSHOME is respected, so people pointing at a custom
	# vips install keep control.
	unless %*ENV<VIPSHOME> {
		_setenv-c('VIPSHOME', $*DISTRO.is-win ?? $lib-dir.parent.Str !! $lib-dir.Str);
	}

	# Disable GIO extension-module loading entirely.
	#
	# Our bundled libgio was compiled with GIO_MODULE_DIR baked to
	# the builder's prefix (the conda env it was cut from, on macOS
	# and Linux alike). At g_type_init time, GIO scans that dir and
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

#| Windows only: make the DLLs in C<$lib-dir> findable when libvips,
#| loaded from there by absolute path, asks the loader for its own
#| dependencies. See the first bullet on C<_configure-runtime-env>.
sub _use-dll-dir(IO::Path:D $lib-dir --> Nil) {
	my $lib-str = $lib-dir.Str;

	# Belt: prepend to PATH so any loader search that consults
	# it (including third-party tools / subprocess spawns) sees
	# the lib dir.
	#
	# Windows environment names are case-insensitive, and the
	# entry a process is handed is spelled `Path`. Raku's %*ENV is
	# a plain case-sensitive Hash, so writing `<PATH>` would leave
	# the real entry alone and add a SECOND key holding only our
	# dir — and a child process spawned later inherits both, with
	# Windows free to pick the short one as its search path (a
	# `sqlcipher.dll not found` in a consumer app's child-process
	# tests was exactly that). Update whichever spelling exists.
	my Str $path-key = _env-path-key();
	my $current = %*ENV{$path-key} // '';
	unless $current.starts-with("$lib-str;") || $current eq $lib-str {
		%*ENV{$path-key} = "$lib-str;$current";
	}

	# Braces: Raku's `%*ENV` writes go through the CRT
	# (`_putenv`), which on some Windows + CRT combinations
	# doesn't propagate to `GetEnvironmentVariableW` — the
	# function the Win32 loader consults when resolving
	# dependent DLLs during LoadLibrary(absolute-path). Call
	# kernel32's SetDllDirectoryW directly so the loader
	# definitely sees our dir regardless of CRT state.
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
	#
	# NativeCall encoding name is `utf16` (no dash). The W (wide)
	# variant takes UTF-16LE on Windows — which is what Raku's
	# `utf16` marshals to on little-endian hosts (every Windows
	# target we support is LE).
	my sub SetDllDirectoryW(Str is encoded('utf16'))
		returns int32 is native('kernel32') { * };
	SetDllDirectoryW($lib-str);
	Nil;
}
_configure-runtime-env();

# --- Resolver memoisation ------------------------------------------
#
# Every library-path resolver below is a memoised sub rather than a
# `constant` binding: `constant X = _resolve-lib(...)` evaluates at
# compile time and bakes the resolved path into the precompiled
# bytecode, and Rakudo doesn't track `resources/BINARY_TAG` as a
# precomp dependency. A BINARY_TAG bump (which moves staged libs to
# a new versioned directory and may GC the previous one) would leave
# the precomp pointing at the old path — producing "Cannot locate
# native library" errors on freshly installed packages until the
# user nuked `~/.raku/precomp/`. Deferring resolution to run time
# means each process picks up the current tag, regardless of when
# the precomp was built. Pair with `is native(&vips-lib)` on each
# binding (not `is native($vips-lib)`) so NativeCall invokes the
# resolver lazily. Non-negotiable consequence of the Callable form:
# whatever these return is passed to dlopen unmangled — see the
# header block.
#
# The memo itself is lock-guarded, and it has to be. These were
# plain `state $r = <slow probe>` one-liners until 0.7.0, and a bare
# `state` initialiser is NOT thread-safe: the flag that marks the
# slot initialised is set independently of the value landing in it,
# so a second thread arriving mid-initialisation reads the slot and
# gets `Any`. The initialisers here are nested filesystem walks
# taking milliseconds on a cold page cache, which makes that window
# wide enough to hit reliably — a burst of worker threads whose
# first-ever vips call all land together (an app decoding a screen
# full of images at startup) reproduced it on 16 of 25 cold
# launches. The two failure modes are both nasty: `USE-SHIM` blows
# up with "expected Bool but got Any" (the `--> Bool` return
# constraint catching it), and a resolver without that constraint
# hands NativeCall a `Str` *type object* as a library name, i.e.
# dlopen(garbage). In a consumer that wraps decodes in `try`, both
# surface as an image that silently fails to appear.
#
# So: resolve under `$lib-resolve-lock`, and prime every resolver
# from the unit mainline (see _prime-lib-resolvers at the foot of
# this file) so the first touch happens on the loading thread,
# before consumer code — let alone consumer worker threads — exists.
# After priming the lock is uncontended and the resolvers are a
# mutex acquire plus a hash lookup, which is noise next to the
# native calls they gate.
#
# The lock is built here in the mainline AND defensively `//=`'d at
# the use site: this unit's own mainline is the earliest thing that
# runs when it is loaded, but an INIT phaser in a *dependent* unit
# is not, and neither is a `require` from an already-threaded
# process. Cheap belt to a cheap braces.
my Lock $lib-resolve-lock = Lock.new;
my %lib-memo;

#| Run C<&compute> at most once per C<$key> per process and hand back
#| the memoised result, thread-safely.
#|
#| Keyed on C<:exists> rather than definedness because an undefined
#| result is meaningful here — C<shim-lib> legitimately memoises the
#| C<Str> type object on platforms with no shim, and a definedness
#| test would re-run the probe on every call there.
my sub _memoise(Str:D $key, &compute) {
	($lib-resolve-lock //= Lock.new).protect: {
		%lib-memo{$key} = compute() unless %lib-memo{$key}:exists;
		%lib-memo{$key};
	}
}

# The `formulae` hints are the Homebrew formulae that ship each
# library — vips's own keg for libvips, glib's for libgobject-2.0.
# They let the system probe find an *unlinked* keg under
# <brew-prefix>/opt/<formula>/lib.
# (List literals, not <vips> — a single-word <> yields a Str, which
# won't bind to :@formulae.)
#
# The `--> Str` on each is load-bearing, not decoration: it is the
# tripwire that turns a future memo regression into a loud type
# check failure instead of a silent dlopen of a type object.
sub vips-lib(--> Str) is export {
	_memoise 'libvips', { _resolve-lib('libvips', formulae => ['vips']) }
}
sub gobject-lib(--> Str) is export {
	_memoise 'libgobject-2.0',
			 { _resolve-lib('libgobject-2.0', formulae => ['glib']) }
}

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
#|
#| Looked for where the libraries are: the C<$VIPS_NATIVE_LIB_DIR>
#| override first, as for libvips itself, then the staged bundle. A
#| custom vips install, or a shim compiled by hand for one, is found
#| the same way its libvips is.
sub _resolve-shim-lib(--> Str) is export(:INTERNAL) {
	with _find-in(_override-lib-dir(), 'libvips_shim') { return $_ }
	with _staged-lib-dir() -> $dir {
		return Str unless $dir.d;
		with _find-in($dir, 'libvips_shim') { return $_ }
	}
	Str;
}
# Same memoised-sub pattern as vips-lib / gobject-lib above — see
# those for the precomp-staleness and thread-safety rationale.
sub shim-lib(--> Str) is export {
	_memoise 'libvips_shim', { _resolve-shim-lib() }
}

# `.f` on a stale path (e.g. cached r7 path, r7 dir since deleted)
# returns a Failure rather than False. `so try ...` collapses both
# False and the absent-file Failure into a clean Bool.
#
# Memoised so we only stat the shim once per process even though
# every variadic binding consults it. shim-lib() is now a sub call
# rather than the old `$shim-lib` constant.
#
# Note the nested _memoise: this one's &compute calls shim-lib(),
# which takes the same lock. Raku's Lock is reentrant, so the
# nesting is safe — and it has to be nested rather than hoisted,
# because the whole point is that neither memo may be observed
# half-written.
sub USE-SHIM(--> Bool) {
	_memoise 'use-shim',
			 { shim-lib().defined && (so try shim-lib().IO.f) }
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

# --- vips_version(int) ---
# Not variadic: 0 asks for the major version, 1 the minor, 2 the micro.
sub _vips-version(int32 --> int32)
	is native(&vips-lib)
	is symbol('vips_version') { * };

#| The oldest libvips Vips::Native supports: the first with the
#| C<fail_on> load option that strict decoding passes, and the one
#| Ubuntu 22.04 ships. The prebuilt bundles carry a newer one.
constant VIPS_MIN_VERSION is export = v8.12;

#| The version of the libvips loaded, as major.minor.micro.
sub vips-version(--> Version:D) is export {
	_memoise 'version', {
		Version.new: (_vips-version(0), _vips-version(1), _vips-version(2)).join('.')
	}
}

#| Why a libvips of version $have, loaded from $path, can't be used —
#| or Nil if it can.
sub vips-version-problem(Version:D $have, Str $path --> Str) is export(:INTERNAL) {
	return Nil unless $have cmp VIPS_MIN_VERSION == Less;
	"Vips::Native needs libvips {VIPS_MIN_VERSION} or later, but the libvips "
		~ "it loaded{$path ?? " ($path)" !! ''} is $have. Reinstall Vips::Native "
		~ 'without VIPS_NATIVE_PREFER_SYSTEM, and run without VIPS_NATIVE_LIB_DIR, '
		~ 'to use the libvips it bundles; or upgrade the system libvips.';
}

#| Die, saying why and what to do, if the libvips loaded is older than
#| VIPS_MIN_VERSION.
sub ensure-vips-version(--> Nil) is export {
	with vips-version-problem(vips-version(), vips-lib()) { die $_ }
}

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
# Strict shim: vips_shim_image_new_from_buffer_strict(buf, len)
# passes "[fail_on=warning]" as the fixed libvips option string.
#
# IMPORTANT lifetime contract: libvips does NOT copy `buf`; it reads it
# lazily as pixels are computed. The CARRAY the caller passes here must
# stay alive until the returned VipsImage (and everything derived from
# it) has been materialised (vips_image_write_to_memory / *_buffer) and
# unref'd. Callers in Vips::Native root the backing CArray via LEAVE.
sub _vips-from-buffer-shim(Pointer, size_t --> VipsImage)
	is native(&shim-lib)
	is symbol('vips_shim_image_new_from_buffer') { * };
sub _vips-from-buffer-strict-shim(Pointer, size_t --> VipsImage)
	is native(&shim-lib)
	is symbol('vips_shim_image_new_from_buffer_strict') { * };
sub _vips-from-buffer-direct(Pointer, size_t, Str, Str --> VipsImage)
	is native(&vips-lib)
	is symbol('vips_image_new_from_buffer') { * };
sub vips_image_new_from_buffer(Pointer $buf, size_t $len, Bool:D :$strict = False --> VipsImage) is export {
	if $strict {
		die "strict vips_image_new_from_buffer requires libvips_shim with vips_shim_image_new_from_buffer_strict; reinstall Vips::Native with the current shim"
			unless USE-SHIM();
		return _vips-from-buffer-strict-shim($buf, $len);
		CATCH {
			default {
				die "strict vips_image_new_from_buffer could not call vips_shim_image_new_from_buffer_strict; reinstall Vips::Native with the current shim: {.message}";
			}
		}
	}
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

# === Bulk byte copies ===
#
# Every pixel buffer that crosses between libvips's heap and a Raku
# Buf has to move in one memcpy, never in a Raku-level loop. A
# 4000×3000 RGBA decode is 48 MB; walking that a byte at a time
# through `nativecast(CArray[uint8], $ptr)` costs tens of seconds and
# utterly dominates the decode it is attached to.
#
# NativeCall marshals a Blob/Buf argument by handing the native
# function a pointer straight at the array's storage — MoarVM keeps
# that storage in its own malloc'd allocation, outside the moving
# heap, and the calling thread cannot reach a GC safepoint until the
# native call returns — so libc's memcpy is usable in both directions
# with no new C code. That matters: `src/vips_native_shim.c` ships
# *prebuilt* inside the binary bundle, so a new shim symbol would be
# missing on every already-published BINARY_TAG.
#
# Resolving memcpy portably is the only fiddly part, and its one hard
# rule is that the library name must never be empty — even though an
# empty name is how NativeCall spells "the current process".
#
# An empty name looks right, and every call made through it works:
# MoarVM builds the call site against dlopen(NULL), the process's own
# global scope, which always holds the libc Rakudo is linked against.
# What breaks is NativeCall's "is this call site built yet?" test,
# which it asks every time it records a dispatch to the sub. Asking
# reads the sub's native call body through MoarVM's NativeCall
# representation, and that read COPIES the body and re-opens the
# library for the copy — by handing dlopen the name verbatim. The
# builder maps "" to NULL; the copy does not, and macOS's dlopen("")
# fails. So the copy carries no library handle, the site reads as
# never built, and NativeCall builds it again, in place, on every
# recording, for the life of the process.
#
# That is not merely slow. The builder publishes a fresh, not yet
# filled argument-type array into the live body before filling it,
# and a second thread recording a call to the same sub at that moment
# copies the half-written array and calls through it. Worker threads
# doing their first memcpy together hit this on up to one cold launch
# in twenty: a segfault inside libffi's ffi_prep_cif (a NULL argument
# type), "Failure to set up FFI call interface", or a memcpy
# marshalled from garbage types. Warming the subs at load time would
# not have helped: a site that never reads as built is rebuilt by
# every later recording — another call site, another Blob type, a
# fresh specialisation — however warm it was before.
#
# So every platform names its C runtime as a complete filename that
# dlopen accepts from the copy as readily as from the build:
#
#   * macOS — /usr/lib/libSystem.B.dylib, the umbrella library libc
#     lives in. It sits in the dyld shared cache rather than on disk,
#     and dlopen finds it there.
#
#   * Linux — libc.so.6, glibc's SONAME, the same name _setenv-c binds
#     setenv through. Not the string form 'c': NativeCall mangles that
#     to "libc.so", which on Debian/Ubuntu is a linker script rather
#     than a shared object.
#
#   * Windows — ucrtbase.dll. There is no dlopen(NULL) equivalent:
#     dyncall's dlLoadLibrary(NULL) returns GetModuleHandle(NULL), i.e.
#     the *executable's* module, and dlFindSymbol is a GetProcAddress
#     against that handle, so "memcpy" is simply not in the export
#     table. Name the UCRT explicitly.
#
#     It must be the COMPLETE filename. dyncall appends a '.' to
#     whatever it is handed before calling LoadLibraryW (to stop
#     Windows auto-appending ".dll"), so 'ucrtbase' becomes
#     "ucrtbase." and resolves nothing, while 'ucrtbase.dll' becomes
#     "ucrtbase.dll." → ucrtbase.dll. Same fully-formed-filename rule
#     the vips-lib resolver lives by, for the same reason: this is
#     the Callable form of the trait, so the return value reaches
#     dlopen()/LoadLibraryW() verbatim and unmangled.
#
# Memoised through the same lock as the other resolvers. The
# initialiser is trivial here, but `state` gives no atomicity even
# for a trivial one, and NativeCall would take the half-written slot
# — a `Str` type object — straight to dlopen.
sub cstdlib-lib(--> Str) is export {
	_memoise 'cstdlib', {
		$*DISTRO.is-win    ?? 'ucrtbase.dll'
		!! $os ~~ /darwin/ ?? '/usr/lib/libSystem.B.dylib'
		!!                    'libc.so.6'
	}
}

# void *memcpy(void *dest, const void *src, size_t n), bound twice so
# each direction gets the Blob on the correct side of the signature.
sub _memcpy-to-buf(Blob, Pointer, size_t --> Pointer)
	is native(&cstdlib-lib) is symbol('memcpy') { * }
sub _memcpy-from-buf(Pointer, Blob, size_t --> Pointer)
	is native(&cstdlib-lib) is symbol('memcpy') { * }

#| Copy C<$n> bytes out of native memory into a fresh, GC-owned
#| C<Buf[uint8]>.
#|
#| The returned Buf has no tie whatsoever to C<$src>: callers are free
#| to (and must) release the native allocation as soon as this
#| returns. The copy is complete before the call returns, so the
#| C<vips_shim_free> always belongs *after* it.
#|
#|     my $out = buf-from-native($ptr, $w * $h * 4);
#|     vips_shim_free($ptr);
#|
#| C<$n> of 0 yields an empty Buf without touching C<$src>, so a NULL
#| or dangling pointer paired with a zero length is harmless.
sub buf-from-native(Pointer:D $src, Int:D $n --> Buf[uint8]) is export {
	die "buf-from-native: length must be non-negative, got $n" if $n < 0;
	my $out = buf8.allocate($n);
	_memcpy-to-buf($out, $src, $n) if $n > 0;
	$out;
}

#| Copy a C<Blob> into a freshly allocated C<CArray[uint8]> of the
#| same byte length and return it.
#|
#| This is the input half of the pair, for libvips entry points that
#| reference their input buffer lazily (C<vips_image_new_from_buffer>
#| does NOT copy). The caller owns the returned CArray and must keep
#| it reachable until libvips has finished reading — typically with a
#| C<LEAVE { $ca.so }> registered before the image's own unref, so it
#| runs last.
#|
#|     my $ca = native-copy-of($encoded);
#|     LEAVE { $ca.so }
#|     my $img = vips_image_new_from_buffer(nativecast(Pointer, $ca),
#|                                          $encoded.bytes);
#|
#| Length is taken from C<.bytes>, not C<.elems>, so the copy is
#| byte-exact for any element width. Pair it with C<.bytes> at the
#| callsite too.
#|
#| An empty Blob yields an empty (zero-element) CArray backed by a
#| small valid allocation, so C<nativecast(Pointer, $ca)> is never
#| NULL and is safe to hand to libvips alongside a zero length.
sub native-copy-of(Blob:D $src --> CArray[uint8]) is export {
	my $n = $src.bytes;
	# Never CArray.allocate(0). Rakudo implements allocate($n) as a
	# bind to index $n - 1, so a zero request binds index -1 and
	# writes one byte *before* the fresh storage: a silent heap
	# underflow on every platform, which the Windows heap checker
	# detects at some later, unrelated free and turns into a process
	# abort with STATUS_HEAP_CORRUPTION (0xC0000374). CArray.new
	# gives a valid zero-element array without any bind.
	my $ca = $n > 0 ?? CArray[uint8].allocate($n) !! CArray[uint8].new;
	_memcpy-from-buf(nativecast(Pointer, $ca), $src, $n) if $n > 0;
	$ca;
}

#| Resolve every library path once, here, on whichever thread is
#| loading this unit — so no consumer thread ever meets a cold memo.
#|
#| The lock above makes concurrent first-touch *correct*; priming
#| makes it *never happen*, which also keeps the resolvers' cost
#| (several directory walks) off whatever worker thread would
#| otherwise have paid it mid-decode. Nothing is dlopen'd here: this
#| only computes paths.
#|
#| Deliberately a mainline call rather than an INIT phaser, unlike
#| C<ensure-vips-init> in Vips::Native. A unit's INIT phasers run
#| *before* that same unit's mainline, and this unit's mainline
#| includes C<_configure-runtime-env()>, which is documented to run
#| before anything resolves or loads a library. Priming from an INIT
#| block here would invert that order. The mainline tail gives the
#| same guarantee — it runs on the loading thread, before any code
#| that could `use` this module gets to run at all — with the
#| ordering intact. (Vips::Native's INIT is unaffected: a dependency's
#| mainline completes before the dependent unit's INIT fires, so
#| ensure-vips-init still sees primed resolvers.)
sub _prime-lib-resolvers() {
	vips-lib();
	gobject-lib();
	shim-lib();
	USE-SHIM();
	cstdlib-lib();
}
_prime-lib-resolvers();
