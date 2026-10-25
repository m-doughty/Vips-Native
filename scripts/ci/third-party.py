#!/usr/bin/env python3
"""Write the notices kit into a Vips-Native prebuilt bundle, and refuse a
bundle holding a library it cannot attribute.

Every archive build-binaries.yml publishes carries, beside the libraries:

  THIRD-PARTY.md   every bundled file -> the package it came from, with
                   version, licence and where its source lives; the
                   licences to be aware of (GPL, LGPL, the GCC runtime's
                   GPL with exception, and the weak-copyleft MPL, EPL and
                   CDDL) called out; the full package set the bundle was
                   cut from.
  LICENSES/        the licence texts: each package's own, Vips::Native's
                   (for the varargs shim, our code), and the GPL-3.0 text
                   the LGPL-3.0 incorporates.

Build.rakumod stages the archive as a whole, so an install carries both.

Two sources, two subcommands:

  conda   the macOS and Linux bundles, cut from a conda-forge environment.
          Each bundled file is attributed through the environment's own
          records (conda-meta/*.json lists every file a package
          installed), to the package that installed the file the bundled
          library's path resolves to: a library reached through another
          package's symlink (libgomp.so.1, which _openmp_mutex links to
          libgomp's libgomp.so.1.0.0) is credited to the package that
          built it. Licence texts come from each package's
          info/licenses/ — or a sibling output of the same feedstock
          build, or a pinned canonical text (CANONICAL_TEXTS) for the
          compiler runtimes, which ship none — plus the upstream notice
          files a package does not carry (VENDORED_TEXTS: Lerc's NOTICE,
          FreeType's BDF and PCF driver notices). Provenance
          comes from info/about.json (upstream home, the conda-forge
          feedstock at the exact commit that built it) and info/recipe/
          (the upstream source archive and its SHA-256). A bundled
          package left with no licence text fails the build, unless the
          licence it declares is a public-domain dedication that asks
          for none (PUBLIC_DOMAIN: SQLite's "blessing").

  mxe     the Windows bundles, cut from a libvips/build-win64-mxe
          release zip. The zip carries one licence text — libvips's own —
          and a versions.json naming every component it built. Each DLL is
          attributed to a component through the table below. Each
          component's licence, version, upstream source and licence texts
          come from scripts/ci/license-texts/windows/manifest.json, which
          names every text file with its SHA-256; the texts are copied to
          LICENSES/<component>/. Components built into other components'
          DLLs ship with their host (MXE_BUILT_IN: the mingw-w64 runtime
          and llvm-runtime's compiler-rt in every DLL, proxy-libintl in
          GLib's, the Rust crates and standard library in librsvg's, ...).
          A bundled component the manifest does not list for the pack's
          architecture, a component the manifest lists that this script
          does not know, a version that disagrees with versions.json, a
          manifest cut for another release, a component with no text that
          is not public domain, or a text whose bytes do not hash to the
          manifest's value fails the build. Our shim's own runtime (the
          MSYS2 toolchain's mingw-w64 CRT; libgcc on x86_64) is named
          too.

Either way, a bundled file nothing attributes fails the build: the kit
must account for every library in the archive. And either way the pack's
copyleft must be disclosed: every bundled package or component whose
declared licence is GPL (or AGPL), GPL-or-other, GPL with the GCC runtime
exception, LGPL, MPL, EPL or CDDL must be listed for the pack's platform
in scripts/ci/disclosed.json — the list t/12-disclosure holds the README
and its Pod to — or the build fails. Each of those (and each the list
names by hand) is listed under "Where to get the source" with its source
archive and that archive's SHA-256 — the build fails without one — and
the MPL-2.0 Rust crates in librsvg with their crates.io pages. And either
way THIRD-PARTY.md carries the statements licences ask a binary
distribution's documentation for (ACKNOWLEDGEMENTS: FreeType's credit,
the IJG's, Adobe's gain-map notice), and a pack with GLib, FriBidi or
HarfBuzz carries the Unicode License v3 (UNICODE_DATA).

Python 3.9+ standard library only: it runs on the macOS runner's system
python3, on ubuntu-22.04's, and on the Windows runners via
actions/setup-python.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from collections import OrderedDict

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEXTS_DIR = os.path.join(REPO_ROOT, 'scripts', 'ci', 'license-texts')
# Canonical licence texts kept in the repository, by SPDX id, each pinned
# by SHA-256 so an edited or line-ending-converted copy cannot ship as the
# real thing:
#   GPL-3.0            https://www.gnu.org/licenses/gpl-3.0.txt — the
#                      text the LGPL-3.0 incorporates; in every pack.
#   GCC-exception-3.1  GCC's COPYING.RUNTIME (gcc.gnu.org and its GitHub
#                      mirror agree byte for byte) — for the compiler
#                      runtime packages, which declare
#                      "GPL-3.0-only WITH GCC-exception-3.1" and ship no
#                      licence file of their own; and, in the Windows
#                      x86_64 pack, for the libgcc our own shim links.
#   Unicode-3.0        https://www.unicode.org/license.txt (Last-Modified
#                      2026-01-05), the Unicode License v3 — for the tables
#                      derived from the Unicode Character Database that are
#                      compiled into GLib, FriBidi and HarfBuzz, whose
#                      upstreams ship no Unicode licence text (see
#                      UNICODE_DATA).
CANONICAL_TEXTS = OrderedDict([
    ('GPL-3.0', ('GPL-3.0.txt',
                 '3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986')),
    ('GCC-exception-3.1', ('GCC-exception-3.1.txt',
                           '9d6b43ce4d8de0c878bf16b54d8e7a10d9bd42b75178153e3af6a815bdc90f74')),
    ('Unicode-3.0', ('Unicode-3.0.txt',
                     'e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96')),
])

# The packages (conda names) and components (build-win64-mxe names) with
# Unicode Character Database tables compiled in. A pack carrying any of them
# carries LICENSES/Unicode-3.0.txt, and its THIRD-PARTY.md says why.
UNICODE_DATA = OrderedDict([
    ('GLib', ('libglib', 'glib')),
    ('FriBidi', ('fribidi',)),
    ('HarfBuzz', ('libharfbuzz', 'harfbuzz')),
])

# Statements a licence asks for in the documentation of a binary
# distribution, beyond shipping its text, by the packages and components
# they belong to. A pack carrying one of these prints the statement in its
# THIRD-PARTY.md (the README carries them too).
#   FreeType  the FreeType Licence, clause 2 (FTL.TXT); <year> is the
#             bundled release's (FREETYPE_YEARS).
#   IJG       the IJG licence's clause 2, for libjpeg-turbo and mozjpeg.
#   Adobe     libultrahdr's adobe-hdr-gain-map-license/NOTICE.
FREETYPE_YEARS = {
    # docs/CHANGES: "CHANGES BETWEEN 2.14.2 and 2.14.3 (2026-Mar-22)";
    # its headers read "Copyright (C) 1996-2026".
    '2.14.3': '2026',
}
ACKNOWLEDGEMENTS = OrderedDict([
    ('FreeType', (('libfreetype6', 'libfreetype', 'freetype'),
                  'Portions of this software are copyright © {year} The FreeType Project '
                  '(https://freetype.org). All rights reserved.')),
    ('IJG', (('libjpeg-turbo', 'mozjpeg'),
             'This software is based in part on the work of the Independent JPEG Group.')),
    ('Adobe gain map', (('libuhdr', 'uhdr'),
                        'This product includes Gain Map technology under license by Adobe.')),
])

# Upstream notice files a conda package does not carry in its
# info/licenses/, kept in the repository (scripts/ci/license-texts/) byte
# for byte as the source archive the package was built from has them — the
# archive its recipe names, whose SHA-256 is checked against the recipe's —
# and shipped in LICENSES/<package>/ under the name the archive gives them.
# A bundled package listed here at a version other than the one its texts
# were taken from, built from another source archive, or with a vendored
# file missing or not hashing to its pin, fails the build: re-vendor them
# from the new version's source archive. Unlike CANONICAL_TEXTS these are
# hashed as stored, line endings and all (.gitattributes keeps them
# byte-exact). Per entry: the conda packages it applies to, what the texts
# are and why they must ship, and (name in LICENSES/<package>/, file under
# scripts/ci/license-texts/, SHA-256, member of the source archive).
VENDORED_TEXTS = OrderedDict([
    ('lerc', {
        'packages': ('lerc',),
        'what': 'its NOTICE',
        'why': 'The Apache-2.0 (section 4(d)) asks for a work\'s NOTICE file to travel with it.',
        'version': '4.2.0',
        'source': 'https://github.com/Esri/lerc/archive/v4.2.0.tar.gz',
        'source_sha256': 'a1fb593ed1fcb5b38800caf3c4454f872745202e961d00d745e53d81447e17c9',
        'files': [
            ('NOTICE', 'lerc-4.2.0/NOTICE',
             'f222a70d24e261b9b4b238df4fe9132e669d7776f137753c6cbbc5be4701124d',
             'lerc-4.2.0/NOTICE'),
        ],
    }),
    # conda-forge's freetype ships FTL.TXT and GPLv2.TXT; the BDF and PCF
    # font drivers compiled into libfreetype are under X11-style licences
    # whose permission notices live only in each driver's README (its
    # "License" section), which "shall be included in all copies". Whole
    # files, as the Windows packs ship them (identical bytes).
    ('freetype', {
        'packages': ('libfreetype6', 'libfreetype', 'freetype'),
        'what': 'the permission notices of the BDF and PCF font drivers compiled into it '
                '(the "License" section of each driver\'s README)',
        'why': 'The X11-style licences of FreeType\'s BDF and PCF drivers ask for their '
               'permission notices to be included in all copies.',
        'version': '2.14.3',
        'source': 'https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.gz',
        'source_sha256': 'e61b31ab26358b946e767ed7eb7f4bb2e507da1cfefeb7a8861ace7fd5c899a1',
        'files': [
            ('src/bdf/README', 'freetype-2.14.3/src/bdf/README',
             '7984455e7e5a9faba3797c8bf095fbe10cc846316b7320aff8c58402e22b82fe',
             'freetype-2.14.3/src/bdf/README'),
            ('src/pcf/README', 'freetype-2.14.3/src/pcf/README',
             '18d9782898d9eac04476e2f744678137b2a889689ed3e923e052fc396a86f86b',
             'freetype-2.14.3/src/pcf/README'),
        ],
    }),
])

# Licences that ask for no notice at all — public-domain dedications. A
# bundled package declaring one of these (and only these) may ship without
# a licence text; any other package without one fails the build.
PUBLIC_DOMAIN = frozenset([
    'blessing',                  # SQLite's public-domain dedication
    'CC0-1.0',
    'Unlicense',
    'LicenseRef-Public-Domain',
    'LicenseRef-PublicDomain',
])

OWN_LICENSE = os.path.join(REPO_ROOT, 'LICENSE')

# The copyleft each platform's pack is known to carry, as the README and
# its Pod name it (see that file's _comment and t/12-disclosure).
DISCLOSED = os.path.join(REPO_ROOT, 'scripts', 'ci', 'disclosed.json')
# Every Windows component's licence, source and licence texts.
WINDOWS_TEXTS_DIR = os.path.join(TEXTS_DIR, 'windows')
WINDOWS_MANIFEST = os.path.join(WINDOWS_TEXTS_DIR, 'manifest.json')

NOTICES = 'THIRD-PARTY.md'
LICENSES = 'LICENSES'

CONDA_CHANNEL = 'https://conda.anaconda.org/conda-forge'
MXE_REPO = 'https://github.com/libvips/build-win64-mxe'

SHA256 = re.compile(r'[0-9a-f]{64}')


class Unattributable(Exception):
    pass


def die(msg):
    print('::error::' + msg.replace('\n', ' '), file=sys.stderr)
    print('❌ ' + msg, file=sys.stderr)
    sys.exit(1)


def md(text):
    """Escape a table cell."""
    return str(text).replace('|', '\\|').replace('\n', ' ')


def and_list(items):
    items = list(items)
    if len(items) <= 2:
        return ' and '.join(items)
    return ', '.join(items[:-1]) + ' and ' + items[-1]


def code(text):
    return '`' + str(text) + '`'


def bundle_entries(bundle):
    """(files, links): every regular file and every link in the bundle,
    as '/'-separated paths relative to it, skipping a notices kit left by
    an earlier run."""
    files, links = [], []
    for root, dirs, names in os.walk(bundle):
        rel_root = os.path.relpath(root, bundle)
        rel_root = '' if rel_root == '.' else rel_root.replace(os.sep, '/')
        if rel_root == '' and LICENSES in dirs:
            dirs.remove(LICENSES)
        for d in list(dirs):
            if os.path.islink(os.path.join(root, d)):
                links.append((rel_root + '/' if rel_root else '') + d)
                dirs.remove(d)
        for n in names:
            rel = (rel_root + '/' if rel_root else '') + n
            if rel == NOTICES:
                continue
            (links if os.path.islink(os.path.join(root, n)) else files).append(rel)
    return sorted(files), sorted(links)


def own_file(rel):
    """Vips::Native's own files in a bundle: the varargs shim and the
    sidecar recording the source it was compiled from."""
    base = rel.rsplit('/', 1)[-1]
    return '/' not in rel and (base.startswith('libvips_shim.'))


def reset_kit(bundle):
    lic = os.path.join(bundle, LICENSES)
    if os.path.isdir(lic):
        shutil.rmtree(lic)
    os.makedirs(lic)
    notices = os.path.join(bundle, NOTICES)
    if os.path.exists(notices):
        os.remove(notices)


def canonical_text(spdx):
    """A pinned canonical licence text, verified, as LF-terminated bytes.
    Line endings are normalised before hashing: a Windows checkout with
    core.autocrlf rewrites the file to CRLF, and that must neither fail
    the pin nor ship a different text."""
    name, digest = CANONICAL_TEXTS[spdx]
    path = os.path.join(TEXTS_DIR, name)
    with open(path, 'rb') as f:
        data = f.read().replace(b'\r\n', b'\n')
    if hashlib.sha256(data).hexdigest() != digest:
        die('%s does not hash to the pinned %s text (%s) — restore it.' % (path, spdx, digest))
    return data


def write_canonical_text(spdx, dest):
    with open(dest, 'wb') as f:
        f.write(canonical_text(spdx))


def canonical_texts_for(expr):
    """The canonical texts a licence expression needs, when every licence
    it names is one we keep (e.g. GPL-3.0-only WITH GCC-exception-3.1);
    otherwise None."""
    ids = re.findall(r'[A-Za-z0-9.+-]+', expr or '')
    ids = [i for i in ids if i not in ('AND', 'OR', 'WITH')]
    wanted = []
    for i in ids:
        base = re.sub(r'(-only|-or-later|\+)$', '', i)
        if base not in CANONICAL_TEXTS:
            return None
        if base not in wanted:
            wanted.append(base)
    return wanted or None


def copy_common_texts(bundle):
    """Vips::Native's licence (the shim) and the GPL-3.0 text."""
    write_canonical_text('GPL-3.0', os.path.join(bundle, LICENSES, 'GPL-3.0.txt'))
    own = os.path.join(bundle, LICENSES, 'Vips-Native')
    os.makedirs(own)
    shutil.copyfile(OWN_LICENSE, os.path.join(own, 'LICENSE'))


def sha256_of(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def vendored_entry(name):
    """The VENDORED_TEXTS key whose texts conda package <name> needs, or
    None."""
    return next((k for k, v in VENDORED_TEXTS.items() if name in v['packages']), None)


def vendored_texts(key, name, version, recipe_digests):
    """The VENDORED_TEXTS of entry <key> for bundled package <name> at
    <version>, verified, as (name in LICENSES/<package>/, bytes as stored)
    pairs. <recipe_digests> are the SHA-256s of the source archives the
    package's recipe names."""
    v = VENDORED_TEXTS[key]
    if version != v['version']:
        die('%s %s is bundled, but the texts kept for it in scripts/ci/license-texts/ are %s '
            '%s\'s (%s). Take them from %s %s\'s source archive (the url + sha256 in the '
            'package\'s info/recipe), and update VENDORED_TEXTS.'
            % (name, version, key, v['version'], v['what'], name, version))
    if v['source_sha256'] not in recipe_digests:
        die('%s %s was built from a source archive other than %s (sha256 %s), the one the '
            'texts kept for it were taken from: its recipe names %s.'
            % (name, version, v['source'], v['source_sha256'],
               ', '.join(recipe_digests) or 'no archive with a sha256'))
    out = []
    for dest, rel, digest, member in v['files']:
        path = os.path.join(TEXTS_DIR, *rel.split('/'))
        if not os.path.isfile(path):
            die('%s is bundled, and %s (%s of %s) is missing — restore it.'
                % (name, path, member, v['source']))
        got = sha256_of(path)
        if got != digest:
            die('%s hashes to %s, not the pinned %s (%s of %s) — restore it.'
                % (path, got, digest, member, v['source']))
        with open(path, 'rb') as f:
            out.append((dest, f.read()))
    return out


def pack_platform(pack):
    """The platform an archive is for, from its name: vips-<platform>.tar.gz
    or vips-<platform>.zip, as build-binaries.yml names them."""
    m = re.fullmatch(r'vips-([a-z0-9_]+(?:-[a-z0-9_]+)+)\.(?:tar\.gz|zip)', pack or '')
    if not m:
        die('cannot tell the platform from the archive name %r (expected '
            'vips-<platform>.tar.gz or vips-<platform>.zip).' % pack)
    return m.group(1)


# --- licence classification ---------------------------------------------

GPL_TOKEN = re.compile(r'(?<![A-Za-z])A?GPL-[0-9.]+(?:-only|-or-later|\+)?')
LGPL_TOKEN = re.compile(r'(?<![A-Za-z])LGPL-[0-9.]+(?:-only|-or-later|\+)?')
WEAK_TOKEN = re.compile(r'(?<![A-Za-z])(?:MPL|EPL|CDDL)-[0-9.]+(?![0-9.])')
SPDX_ID = re.compile(r'[A-Za-z0-9.+-]+')

# Every class classify() can return; each is called out under "Licences to
# be aware of", and a bundled package in any of them must be disclosed.
COPYLEFT_CLASSES = ('gpl', 'gpl-or', 'gcc-exception', 'lgpl', 'weak')


def classify(expr):
    """'gpl'           GPL/AGPL code with no non-copyleft alternative
       'gpl-or'        dual-licensed: GPL or a non-copyleft licence
       'gcc-exception' GPL with the GCC Runtime Library Exception
       'lgpl'          LGPL (no GPL obligation)
       'weak'          weak (file-level) copyleft: MPL, EPL or CDDL, with
                       no GPL or LGPL in the expression (cairo's
                       "LGPL-2.1-only or MPL-1.1" is 'lgpl')
       None            none of those"""
    expr = expr or ''
    if 'GCC-exception' in expr:
        return 'gcc-exception'
    if GPL_TOKEN.search(expr):
        alternatives = re.split(r'\s+OR\s+', expr.strip('() '), flags=re.I)
        if any(not GPL_TOKEN.search(a) and not LGPL_TOKEN.search(a) for a in alternatives):
            return 'gpl-or'
        return 'gpl'
    if LGPL_TOKEN.search(expr):
        return 'lgpl'
    if WEAK_TOKEN.search(expr):
        return 'weak'
    return None


def is_public_domain(expr):
    """True when every licence the expression names is a public-domain
    dedication that asks for no notice."""
    ids = [i for i in SPDX_ID.findall(expr or '') if i.upper() not in ('AND', 'OR', 'WITH')]
    return bool(ids) and all(i in PUBLIC_DOMAIN for i in ids)


def write_licence_classes(w, licences, lgpl3_names):
    """The "Licences to be aware of" section: <licences> is name ->
    declared licence for everything in the pack."""
    groups = OrderedDict((c, []) for c in COPYLEFT_CLASSES)
    for name, lic in licences.items():
        kind = classify(lic)
        if kind:
            groups[kind].append('%s (%s)' % (name, lic))
    w('## Licences to be aware of')
    w('')
    if groups['gpl']:
        w('**GPL.** This archive contains code licensed under the GNU GPL (or AGPL), '
          'with no non-copyleft alternative: ' + '; '.join(groups['gpl']) + '.')
        w('')
    if groups['gpl-or']:
        w('**Dual-licensed, GPL or other.** ' + '; '.join(groups['gpl-or']) + '.')
        w('')
    if groups['gcc-exception']:
        w('**GPL with the GCC Runtime Library Exception** (the compiler\'s runtime '
          'libraries): ' + '; '.join(groups['gcc-exception']) + '.')
        w('')
    if groups['lgpl']:
        w('**LGPL.** ' + '; '.join(groups['lgpl']) + '.')
        w('')
    if groups['weak']:
        w('**Weak (file-level) copyleft: MPL, EPL, CDDL.** ' + '; '.join(groups['weak']) + '.')
        w('')
    w('The GPL-3.0 text is at `LICENSES/GPL-3.0.txt`%s.' % (
        ': the LGPL-3.0, which %s %s under, incorporates it' % (
            and_list(lgpl3_names), 'is' if len(lgpl3_names) == 1 else 'are')
        if lgpl3_names else ''))
    w('')


def acknowledgements(versions):
    """The statements (ACKNOWLEDGEMENTS) the pack must print, as (label,
    statement, names): <versions> is name -> version of everything the
    pack carries."""
    out = []
    for label, (names, statement) in ACKNOWLEDGEMENTS.items():
        here = [n for n in names if n in versions]
        if not here:
            continue
        if '{year}' in statement:
            version = versions[here[0]]
            if version not in FREETYPE_YEARS:
                die('FreeType %s is bundled, and FREETYPE_YEARS does not say which year its '
                    'FTL credit names: add it (the release\'s date, docs/CHANGES).' % version)
            statement = statement.format(year=FREETYPE_YEARS[version])
        out.append((label, statement, here))
    return out


def unicode_hosts(names):
    """The UNICODE_DATA libraries among <names>."""
    return [label for label, pkgs in UNICODE_DATA.items() if any(p in names for p in pkgs)]


def write_acknowledgements(w, acks, unicode, extra=()):
    """The "Acknowledgements" section: the statements licences ask a binary
    distribution's documentation to carry, the Unicode data, and <extra>
    paragraphs."""
    if not acks and not unicode and not extra:
        return
    w('## Acknowledgements')
    w('')
    for label, statement, names in acks:
        w('- %s (%s)' % (statement, ', '.join(names)))
    if acks:
        w('')
    if unicode:
        w('Tables derived from the Unicode Character Database are compiled into %s, '
          'whose upstreams ship no Unicode licence text: the Unicode License v3 that '
          'covers them is at `LICENSES/Unicode-3.0.txt`.' % and_list(unicode))
        w('')
    for paragraph in extra:
        w(paragraph)
        w('')


def crates_io(name, version):
    return 'https://crates.io/crates/%s/%s' % (name, version)


def write_sources(w, rows, crates):
    """The "Where to get the source" section. <rows>: (name, version,
    licence, [(url, sha256)], recipe link or None) for every copyleft
    component; <crates>: (host, [(crate, version)]) for MPL-2.0 Rust crates
    built into a host."""
    w('## Where to get the source')
    w('')
    w('The source of every GPL, LGPL, MPL (and other copyleft) component in this '
      'archive, as the build that made it fetched it, with the SHA-256 it was '
      'checked against%s:' % (
          '; the recipe is the build script and any patches applied' if any(r[4] for r in rows)
          else ''))
    w('')
    w('| Component | Version | Licence | Source |%s' % (' Recipe |' if any(r[4] for r in rows) else ''))
    w('|---|---|---|---|%s' % ('---|' if any(r[4] for r in rows) else ''))
    for name, version, licence, sources, recipe in rows:
        w('| %s | %s | %s | %s |%s' % (
            md(name), md(version), md(licence),
            '<br>'.join('<%s><br>sha256 %s' % (u, code(d)) for u, d in sources),
            (' %s |' % (recipe or '—')) if any(r[4] for r in rows) else ''))
    w('')
    for host, found in crates:
        w('The MPL-2.0 Rust crates built into %s — the Source Code Form MPL-2.0 '
          'section 3.2(a) asks a binary distribution to point to — are on crates.io: %s.'
          % (host, ', '.join('[%s %s](%s)' % (n, v, crates_io(n, v)) for n, v in found)))
        w('')


def mpl_crates_from_yml(path):
    """The MPL-licensed crates a cargo-about THIRDPARTY.yml lists, as
    (name, version) pairs."""
    with open(path, encoding='utf-8', errors='replace') as f:
        text = f.read()
    found = []
    for block in re.split(r'\n(?=- package_name:)', text):
        name = re.search(r'^- package_name:\s*(\S+)', block, re.M)
        version = re.search(r'^  package_version:\s*(\S+)', block, re.M)
        licence = re.search(r'^  license:\s*(.+)$', block, re.M)
        if name and version and licence and WEAK_TOKEN.search(licence.group(1)) \
                and 'MPL' in licence.group(1):
            found.append((name.group(1).strip('\'"'), version.group(1).strip('\'"')))
    return sorted(set(found))


# --- disclosure -----------------------------------------------------------

def load_disclosed(path):
    """disclosed.json, checked for shape: platform -> {readme, packages:
    {package: the name the README gives it}}."""
    if not os.path.isfile(path):
        die('no disclosure list at %s.' % path)
    with open(path, encoding='utf-8') as f:
        try:
            data = json.load(f)
        except ValueError as e:
            die('%s is not valid JSON: %s' % (path, e))
    platforms = data.get('platforms') if isinstance(data, dict) else None
    if not isinstance(platforms, dict) or not platforms:
        die('%s has no "platforms" object.' % path)
    for platform, entry in platforms.items():
        packages = entry.get('packages') if isinstance(entry, dict) else None
        if (not isinstance(entry, dict) or not isinstance(entry.get('readme'), str)
                or not entry['readme'].strip() or not isinstance(packages, dict)):
            die('%s: platform %s needs a "readme" label and a "packages" object.'
                % (path, platform))
        for name, shown in packages.items():
            if not isinstance(shown, str) or not shown.strip():
                die('%s: %s / %s needs the name the README gives it.' % (path, platform, name))
    return platforms


def check_disclosed(platform, licences, path):
    """Fail unless every copyleft package in the pack is listed for its
    platform in disclosed.json. <licences> is name -> declared licence for
    everything the pack carries."""
    platforms = load_disclosed(path)
    if platform not in platforms:
        die('%s lists no platform %s — add it, with every copyleft package its pack '
            'carries, and name them in the README and its Pod.' % (path, platform))
    listed = platforms[platform]['packages']
    undisclosed = ['%s (%s, %s)' % (n, lic, classify(lic)) for n, lic in licences.items()
                   if classify(lic) in COPYLEFT_CLASSES and n not in listed]
    if undisclosed:
        die('the %s pack carries copyleft code the README does not disclose: %s. List '
            'each in %s under %s, and name it in the README\'s and the Pod\'s '
            '"Binary distributions and licensing" (t/12-disclosure checks both).'
            % (platform, ', '.join(undisclosed), path, platform))
    stale = sorted(n for n in listed if n not in licences)
    if stale:
        print('::warning::%s lists %s for %s, which the pack does not carry — the README '
              'discloses more than ships.' % (path, ', '.join(stale), platform))
    print('✅ every copyleft package in the %s pack is disclosed (%d listed).'
          % (platform, len(listed)))
    return listed


def check_sources(rows):
    """Fail unless every row of write_sources() names at least one source
    archive, and every source it names has its SHA-256. A source dropped for
    want of one would leave the row naming only the others: libgcc's once
    read as built from zlib alone."""
    missing = [r[0] for r in rows if not r[3]]
    if missing:
        die('no source archive with a SHA-256 for %s: the "where we pull them from" half of '
            'the disclosure needs one for every copyleft component.' % and_list(missing))
    unhashed = ['%s (%s)' % (r[0], u) for r in rows for u, d in r[3] if not d]
    if unhashed:
        die('no SHA-256 for a source of %s: every source a copyleft component was built '
            'from is disclosed with the digest it was checked against.' % and_list(unhashed))


# --- conda ----------------------------------------------------------------

def recipe_sources(pkg_dir):
    """The upstream source archives a conda package was built from, as
    (url, sha256) pairs, read out of its recipe: rattler-build's
    rendered_recipe.yaml or conda-build's meta.yaml. Best effort — the
    feedstock link at the building commit is the authoritative record."""
    recipe_dir = os.path.join(pkg_dir, 'info', 'recipe')
    for name in ('rendered_recipe.yaml', 'meta.yaml'):
        path = os.path.join(recipe_dir, name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding='utf-8', errors='replace') as f:
            text = f.read()
        if name == 'rendered_recipe.yaml':
            # The recipe proper; the rest is the solved build environment.
            text = text.split('\nbuild_configuration:', 1)[0]
        out = []
        # A source entry is a url with its sha256 on the next line, or the
        # sha256 first; only a sha256 counts as the digest. A url: list
        # names mirrors of one archive (ctng-compilers' GCC): the first
        # stands for it, and the sha256 follows the last.
        for m in re.finditer(
                r'^[ \t]*-?[ \t]*url:[ \t]*(?:\n[ \t]*-[ \t]*)?(https?://\S+)'
                r'(?:[ \t]*\n[ \t]*-[ \t]*https?://\S+)*[ \t]*'
                r'(?:\n[ \t]*(?:-[ \t]*)?(sha256|md5):[ \t]*(\S+))?'
                r'|^[ \t]*-?[ \t]*(sha256):[ \t]*(\S+)[ \t]*\n[ \t]*url:[ \t]*(https?://\S+)',
                text, re.M):
            if m.group(1):
                url, algo, digest = m.group(1), m.group(2), m.group(3)
            else:
                url, algo, digest = m.group(6), m.group(4), m.group(5)
            url = url.strip('\'"')
            digest = (digest or '').strip('\'"') if algo == 'sha256' else ''
            if not SHA256.fullmatch(digest):
                digest = ''
            if (url, digest) not in out:
                out.append((url, digest))
        return out
    return []


def recipe_key(about):
    """What identifies the recipe build a package came out of: the
    feedstock and the commit that built it. Two packages sharing it are
    outputs of one recipe, from one source."""
    extra = about.get('extra') or {}
    if extra.get('remote_url') and extra.get('sha'):
        return (extra['remote_url'], extra['sha'])
    return None


def feedstock_link(name, about):
    """A markdown link to the conda-forge recipe that built a package, at the
    commit that built it when its about.json records one."""
    extra = about.get('extra', {}) or {}
    feedstock = extra.get('remote_url') or 'https://github.com/conda-forge/%s-feedstock' % (
        extra.get('feedstock-name') or name)
    if extra.get('sha'):
        return '[recipe](%s/tree/%s)' % (feedstock, extra['sha'])
    return '[recipe](%s)' % feedstock


def find_pkg_dir(record, prefix, pkgs_dirs):
    """The extracted package a conda-meta record was linked from."""
    candidates = []
    if record.get('extracted_package_dir'):
        candidates.append(record['extracted_package_dir'])
    stem = '%s-%s-%s' % (record['name'], record['version'], record['build'])
    for d in list(pkgs_dirs) + [os.path.join(prefix, '..', '..', 'pkgs')]:
        candidates.append(os.path.join(d, stem))
    for c in candidates:
        if os.path.isdir(os.path.join(c, 'info')):
            return c
    return None


def conda(args):
    platform = pack_platform(args.pack)
    bundle, prefix = os.path.abspath(args.bundle), os.path.abspath(args.prefix)
    meta_dir = os.path.join(prefix, 'conda-meta')
    if not os.path.isdir(meta_dir):
        die('%s is not a conda environment (no conda-meta/).' % prefix)

    records = []
    for name in sorted(os.listdir(meta_dir)):
        if name.endswith('.json'):
            with open(os.path.join(meta_dir, name), encoding='utf-8') as f:
                records.append(json.load(f))
    owner = {}
    for r in records:
        for path in r.get('files', []):
            owner.setdefault(path, []).append(r)

    # Paths are compared as the filesystem resolves them: the prefix may
    # itself sit behind a link (macOS's /tmp -> /private/tmp).
    prefix_real = os.path.realpath(prefix)

    def owners_of(source):
        """(packages, path): the packages that installed the file the
        prefix-relative path <source> resolves to, and that file's path. A
        library reached through a link another package installed —
        _openmp_mutex's lib/libgomp.so.1, leading to libgomp's
        libgomp.so.1.0.0 — is the work of the package that installed the
        library itself. Falls back to the owners of <source> as named when
        nothing installed the file it resolves to."""
        real = os.path.realpath(os.path.join(prefix_real, *source.split('/')))
        real_rel = os.path.relpath(real, prefix_real).replace(os.sep, '/')
        if real_rel != source and real_rel != '..' and not real_rel.startswith('../'):
            found = owner.get(real_rel)
            if found:
                return found, real_rel
        return owner.get(source, []), source

    files, links = bundle_entries(bundle)
    attributed = OrderedDict()     # bundle path -> record (or None = ours)
    resolved = {}                  # bundle path -> the prefix file it is, when reached through a link
    problems = []
    for rel in files:
        if own_file(rel):
            attributed[rel] = None
            continue
        # The bundlers copy <prefix>/lib/<file> to the top level and
        # <prefix>/lib/vips-modules-<M>.<m>/<file> to vips-modules-<M>.<m>/.
        source = 'lib/' + rel
        owners, found_at = owners_of(source)
        if len(owners) == 1:
            attributed[rel] = owners[0]
            if found_at != source:
                resolved[rel] = (source, found_at)
        elif not owners:
            problems.append('%s: no package in %s installed %s' % (rel, prefix, source))
        else:
            problems.append('%s: claimed by more than one package (%s)'
                            % (rel, ', '.join(o['name'] for o in owners)))
    for rel in links:
        target = os.path.normpath(os.path.join(os.path.dirname(os.path.join(bundle, rel)),
                                               os.readlink(os.path.join(bundle, rel))))
        if not target.startswith(bundle + os.sep):
            problems.append('%s: a link leading out of the bundle' % rel)
    if problems:
        die('cannot attribute every file in %s:\n  ' % bundle + '\n  '.join(problems))

    # One row per package that contributes a file.
    packages = OrderedDict()
    for rel, r in attributed.items():
        if r is not None:
            packages.setdefault(r['name'], {'record': r, 'files': []})['files'].append(rel)

    # Before anything is written: the pack's copyleft must be the copyleft
    # the README discloses.
    listed = check_disclosed(platform, OrderedDict(
        (n, p['record'].get('license', '')) for n, p in sorted(packages.items())), args.disclosed)

    # Every package in the environment, with its extracted package: the
    # packages above, and their siblings (another output of the same
    # feedstock at the same version) for licence texts a split output
    # does not carry itself.
    pkg_dirs, abouts = {}, {}
    for r in records:
        d = find_pkg_dir(r, prefix, args.pkgs_dir)
        pkg_dirs[r['name']] = d
        about = {}
        if d and os.path.isfile(os.path.join(d, 'info', 'about.json')):
            with open(os.path.join(d, 'info', 'about.json'), encoding='utf-8') as f:
                about = json.load(f)
        abouts[r['name']] = about

    def licence_texts(name):
        lic_src = os.path.join(pkg_dirs[name] or '', 'info', 'licenses')
        texts = []
        if pkg_dirs[name] and os.path.isdir(lic_src):
            for root, _, names in os.walk(lic_src):
                for n in sorted(names):
                    texts.append(os.path.relpath(os.path.join(root, n), lic_src))
        return lic_src, texts

    unfound = [n for n in packages if pkg_dirs[n] is None]
    if unfound:
        die('the extracted packages (info/) of %s cannot be found — pass the package '
            'cache with --pkgs-dir.' % ', '.join(sorted(unfound)))

    # Where to get the source of every copyleft package (and of every one the
    # disclosure list names by hand): its recipe's source archives, with
    # their SHA-256s, and the recipe at the commit that built it — which
    # holds the patches applied.
    source_rows = []
    for name, p in sorted(packages.items()):
        r = p['record']
        if classify(r.get('license', '')) in COPYLEFT_CLASSES or name in listed:
            source_rows.append((name, r['version'], r.get('license', ''),
                                recipe_sources(pkg_dirs[name]),
                                feedstock_link(name, abouts[name])))
    check_sources(source_rows)
    acks = acknowledgements(OrderedDict((n, p['record']['version']) for n, p in packages.items()))
    # The vendored texts each package needs, verified before anything is
    # written.
    vendored = OrderedDict()
    for name, p in sorted(packages.items()):
        key = vendored_entry(name)
        if key:
            vendored[name] = (key, vendored_texts(
                key, name, p['record']['version'],
                [d for _, d in recipe_sources(pkg_dirs[name]) if d]))

    reset_kit(bundle)
    copy_common_texts(bundle)

    textless = []          # bundled, no licence text, and not public domain
    public_domain = []     # bundled, no licence text, public domain
    for name, p in sorted(packages.items()):
        r = p['record']
        p['about'] = abouts[name]
        p['sources'] = recipe_sources(pkg_dirs[name])
        p['texts'], p['texts_from'], p['vendored'] = [], None, []
        lic_src, texts = licence_texts(name)
        if not texts:
            key = recipe_key(abouts[name])
            for sib in records:
                if sib['name'] != name and key and recipe_key(abouts[sib['name']]) == key:
                    lic_src, texts = licence_texts(sib['name'])
                    if texts:
                        p['texts_from'] = sib['name']
                        break
        dest = os.path.join(bundle, LICENSES, name)
        if texts:
            for t in texts:
                os.makedirs(os.path.dirname(os.path.join(dest, t)), exist_ok=True)
                shutil.copyfile(os.path.join(lic_src, t), os.path.join(dest, t))
            p['texts'] = [LICENSES + '/' + name + '/' + t.replace(os.sep, '/') for t in texts]
        else:
            canonical = canonical_texts_for(r.get('license', ''))
            if canonical:
                os.makedirs(dest)
                for spdx in canonical:
                    fname = CANONICAL_TEXTS[spdx][0]
                    write_canonical_text(spdx, os.path.join(dest, fname))
                    p['texts'].append('%s/%s/%s' % (LICENSES, name, fname))
                p['texts_from'] = 'canonical'
            elif is_public_domain(r.get('license', '')):
                public_domain.append(name)
            else:
                textless.append('%s (declared licence: %s)' % (name, r.get('license') or 'none'))
        for vname, data in (vendored[name][1] if name in vendored else ()):
            target = os.path.join(dest, *vname.split('/'))
            if os.path.isfile(target):
                # The package has started carrying it: VENDORED_TEXTS'
                # entry for it can go.
                print('::notice::%s %s ships %s itself now; the copy in '
                      'scripts/ci/license-texts/ is not used.' % (name, r['version'], vname))
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, 'wb') as f:
                f.write(data)
            p['texts'].append('%s/%s/%s' % (LICENSES, name, vname))
            p['vendored'].append(vname)
        p['texts'] = sorted(p['texts'])
    if textless:
        die('no licence text for %s: the conda package carries none, no sibling output of '
            'its feedstock build does, and the declared licence is not one kept in '
            'scripts/ci/license-texts/ (CANONICAL_TEXTS) or a public-domain dedication '
            '(PUBLIC_DOMAIN). Shipping it would ship a library without the notice its '
            'licence asks for.' % and_list(textless))
    for name, (key, files) in vendored.items():
        for vname, _ in files:
            if not os.path.isfile(os.path.join(bundle, LICENSES, name, *vname.split('/'))):
                die('%s is bundled without %s (%s).' % (name, vname, VENDORED_TEXTS[key]['what']))

    # librsvg is built from Rust crates, some MPL-2.0; its THIRDPARTY.yml
    # (cargo-about's) names each with its version.
    crates = []
    if 'librsvg' in packages:
        yml = [t for t in packages['librsvg']['texts'] if t.endswith('/THIRDPARTY.yml')]
        if not yml:
            die('librsvg is bundled without the THIRDPARTY.yml that names the Rust crates '
                'built into it — the MPL-2.0 ones among them must be pointed to.')
        found = mpl_crates_from_yml(os.path.join(bundle, *yml[0].split('/')))
        if found:
            crates.append(('librsvg', found))
    unicode = unicode_hosts(packages)
    if unicode:
        write_canonical_text('Unicode-3.0', os.path.join(bundle, LICENSES, 'Unicode-3.0.txt'))

    subdir = records and next((r.get('subdir') for r in records if r['name'] == 'libvips'), '') or ''
    lines = []
    w = lines.append
    w('# Third-party software in %s' % args.pack)
    w('')
    w('This archive is a prebuilt binary pack for Vips::Native (%s). Its libraries '
      'were built by [conda-forge](https://conda-forge.org/) and are redistributed '
      'here unmodified apart from their load paths, which are rewritten so the '
      'libraries find each other inside the archive. The one file of '
      'Vips::Native\'s own is the varargs shim (%s, Artistic-2.0, '
      '`LICENSES/Vips-Native/LICENSE`).' % (code(args.tag), ', '.join(
          code(f) for f in attributed if attributed[f] is None and not f.endswith('.srchash'))))
    w('')
    w('- Channel: %s, platform %s' % (CONDA_CHANNEL, code(subdir)))
    w('- Requested: %s' % ', '.join(code(s) for s in args.spec))
    w('- Every library file in this archive is listed under **Files** with the '
      'conda package it came from; each package\'s licence texts are in '
      '`LICENSES/<package>/`, copied from the package\'s `info/licenses/`.')
    w('- The exact package set the archive was cut from is under **Environment**.')
    w('')

    write_licence_classes(
        w, OrderedDict((n, p['record'].get('license', '')) for n, p in sorted(packages.items())),
        [n for n, p in sorted(packages.items()) if 'LGPL-3' in p['record'].get('license', '')])
    w('Licences are as each package declares them (its `license` field, SPDX).')
    w('')
    supplied = [n for n, p in sorted(packages.items()) if p['vendored']]
    if supplied:
        w('**Texts the conda packages lack.** ' + ' '.join(
            '%s %s %s\'s conda package does not carry %s: %s, taken byte for byte from the '
            'source archive the package was built from.' % (
                VENDORED_TEXTS[vendored[n][0]]['why'], n, packages[n]['record']['version'],
                VENDORED_TEXTS[vendored[n][0]]['what'],
                and_list(code('%s/%s/%s' % (LICENSES, n, f)) for f in packages[n]['vendored']))
            for n in supplied))
        w('')
    if public_domain:
        w('**No licence text needed.** %s: dedicated to the public domain, so %s no '
          'licence text, and none is invented here.' % (
              and_list('%s (declared licence: %s)' % (n, packages[n]['record'].get('license'))
                       for n in public_domain),
              'its package carries' if len(public_domain) == 1 else 'their packages carry'))
        w('')
    write_acknowledgements(w, acks, unicode)
    write_sources(w, source_rows, crates)

    w('## Packages')
    w('')
    w('| Package | Version | Build | Licence | Files | Licence texts | Source |')
    w('|---|---|---|---|---|---|---|')
    for name, p in sorted(packages.items()):
        r, about = p['record'], p.get('about', {})
        refs = []
        if about.get('home'):
            refs.append('[upstream](%s)' % about['home'])
        for url, digest in p.get('sources', []):
            refs.append('[source](%s)%s' % (url, ' sha256 ' + code(digest) if digest else ''))
        refs.append(feedstock_link(name, about))
        refs.append('[package](%s)' % r.get('url', ''))
        added = ['%s/%s/%s' % (LICENSES, name, f) for f in p['vendored']]
        own = [t for t in p['texts'] if t not in added]
        if p['texts']:
            texts = '<br>'.join(code(t) for t in own)
            if own and p['texts_from'] == 'canonical':
                texts += ' (the canonical texts of the declared licence; the package ships none)'
            elif own and p['texts_from']:
                texts += ' (from %s, built by the same feedstock commit)' % p['texts_from']
            if added:
                v = VENDORED_TEXTS[vendored[name][0]]
                texts += '%s%s (not in the package: from [the source archive](%s) sha256 %s)' % (
                    '<br>' if own else '', '<br>'.join(code(t) for t in added), v['source'],
                    code(v['source_sha256']))
        else:
            texts = 'none: public domain'
        w('| %s | %s | %s | %s | %s | %s | %s |' % (
            md(name), md(r['version']), md(r['build']), md(r.get('license', '')),
            '<br>'.join(code(f) for f in p['files']), texts, ' · '.join(refs)))
    w('')

    w('## Files')
    w('')
    w('| File | From |')
    w('|---|---|')
    for rel in sorted(list(attributed) + links):
        if rel in attributed:
            r = attributed[rel]
            if r is None:
                src = 'Vips::Native (Artistic-2.0)'
            else:
                src = '%s %s' % (r['name'], r['version'])
                if rel in resolved:
                    src += ' (%s, reached through the link %s)' % (
                        code(resolved[rel][1]), code(resolved[rel][0]))
        else:
            src = 'link to ' + code(os.readlink(os.path.join(bundle, rel)))
        w('| %s | %s |' % (code(rel), md(src)))
    w('')

    w('## Environment')
    w('')
    w('Every package in the conda environment this archive was cut from, '
      'including those that contribute no file to it:')
    w('')
    w('```')
    for r in sorted(records, key=lambda r: r['name']):
        w('%s=%s=%s  %s' % (r['name'], r['version'], r['build'], r.get('url', '')))
    w('```')
    write_notices(bundle, lines)
    print('✅ %s: %d files attributed to %d packages + Vips::Native; %d licence texts.'
          % (NOTICES, len(attributed), len(packages),
             sum(len(p['texts']) for p in packages.values()) + 2))


# --- build-win64-mxe ------------------------------------------------------

# The component key the licence-text manifest files the LLVM C++ runtime
# under: build-win64-mxe's versions.json does not list it, so there is no
# name of upstream's to use.
MXE_LLVM_RUNTIME = 'llvm-runtime'

# DLL file name -> the component that built it: its versions.json key, or a
# key of MXE_UNLISTED. build-win64-mxe names DLLs after their libraries, not
# their components, so this table is the attribution; a DLL it does not
# match fails the build.
MXE_COMPONENTS = [
    (r'libvips(-cpp)?-\d+\.dll', 'vips'),
    (r'vips-[a-z]+\.dll', 'vips'),                 # vips-modules-<M>.<m>/
    (r'libaom\.dll', 'aom'),
    (r'libarchive-\d+\.dll', 'archive'),
    (r'libbrotli(common|dec|enc)\.dll', 'brotli'),
    (r'libcairo-\d+\.dll', 'cairo'),
    (r'libcfitsio\.dll', 'cfitsio'),
    (r'libcgif-\d+\.dll', 'cgif'),
    (r'libdicom-\d+\.dll', 'dicom'),
    (r'libexif-\d+\.dll', 'exif'),
    (r'libexpat-\d+\.dll', 'expat'),
    (r'libffi-\d+\.dll', 'ffi'),
    (r'libfftw3-\d+\.dll', 'fftw'),
    (r'libfontconfig-\d+\.dll', 'fontconfig'),
    (r'libfreetype-\d+\.dll', 'freetype'),
    (r'libfribidi-\d+\.dll', 'fribidi'),
    (r'lib(glib|gio|gobject|gmodule)-2\.0-\d+\.dll', 'glib'),
    (r'libharfbuzz-\d+\.dll', 'harfbuzz'),
    (r'libheif\.dll', 'heif'),
    (r'libhwy\.dll', 'highway'),
    (r'libMagickCore-[0-9A-Za-z.]+-\d+\.dll', 'imagemagick'),
    (r'libimagequant\.dll', 'imagequant'),
    (r'libjxl(_cms|_threads)?\.dll', 'jxl'),
    (r'liblcms2-\d+\.dll', 'lcms'),
    (r'libmatio-\d+\.dll', 'matio'),
    (r'libjpeg-\d+\.dll', 'mozjpeg'),
    (r'lib(niftiio|znz)\.dll', 'nifti'),
    (r'lib(Iex|IlmThread|OpenEXR)-[0-9_]+\.dll', 'openexr'),
    (r'libopenjp2\.dll', 'openjpeg'),
    (r'libopenslide-\d+\.dll', 'openslide'),
    (r'libpango(cairo|ft2)?-1\.0-\d+\.dll', 'pango'),
    (r'libpixman-1-\d+\.dll', 'pixman'),
    (r'libpng16-\d+\.dll', 'png'),
    (r'libpoppler(-glib)?-\d+\.dll', 'poppler'),
    (r'libraw_r-\d+\.dll', 'raw'),
    (r'librsvg-2-\d+\.dll', 'rsvg'),
    (r'libsqlite3-\d+\.dll', 'sqlite'),
    (r'libtiff-\d+\.dll', 'tiff'),
    (r'libuhdr\.dll', 'uhdr'),
    (r'lib(webp|webpdemux|webpmux|sharpyuv)-\d+\.dll', 'webp'),
    (r'libxml2-\d+\.dll', 'xml2'),
    (r'libz1\.dll', 'zlib-ng'),
    (r'libzstd\.dll', 'zstd'),
    (r'lib(c\+\+|unwind)\.dll', MXE_LLVM_RUNTIME),
]
# Components with no versions.json entry, and what they are.
MXE_UNLISTED = OrderedDict([
    (MXE_LLVM_RUNTIME, 'the LLVM C++ runtime (libc++, libunwind) from the release\'s '
                       'llvm-mingw toolchain — not listed in versions.json'),
])

# Components with no DLL of their own, built into another component's
# DLLs, and the component they are built into: each ships — its row, its
# licence texts — when its host is in the pack; None = in every pack. The
# manifest's notes for each say the same ("Statically linked into: <host>"),
# and the build fails if they disagree, or if the manifest lists a
# component neither this table nor MXE_COMPONENTS knows.
MXE_BUILT_IN = OrderedDict([
    ('mingw-w64', None),            # the CRT startup code and libmingwex: every DLL
    ('imath', 'openexr'),
    ('proxy-libintl', 'glib'),
    ('uthash', 'dicom'),
    ('rsvg-crates', 'rsvg'),
    ('rust-std', 'rsvg'),
])
# In every pack whatever its DLLs: LLVM's compiler-rt builtins, whose
# licence is among llvm-runtime's texts, are linked into every DLL, as the
# mingw-w64 CRT is.
MXE_ALWAYS = (MXE_LLVM_RUNTIME, 'mingw-w64')
MXE_ARCHES = ('x86_64', 'arm64')
# The MSYS2 toolchain build-binaries.yml compiles our shim with, per
# architecture, and the compiler runtime it links statically into it.
MXE_SHIM_TOOLCHAIN = {
    'x86_64': ('UCRT64', 'libgcc'),
    'arm64': ('CLANGARM64', 'LLVM\'s compiler-rt builtins'),
}


def valid_text_name(name):
    """A licence text's name in the manifest: a relative path, '/'-separated,
    every segment a plain name."""
    return (isinstance(name, str) and bool(name) and not name.startswith('/') and '\\' not in name
            and all(part not in ('', '.', '..') for part in name.split('/')))


def load_manifest(path, release, versions):
    """The Windows licence-text manifest, checked for shape, for the release
    it was collected for, and against MXE_COMPONENTS and MXE_BUILT_IN:
    (recipe, components)."""
    if not os.path.isfile(path):
        die('no licence-text manifest at %s — the Windows packs carry every component\'s '
            'licence texts, listed there.' % path)
    with open(path, encoding='utf-8') as f:
        try:
            m = json.load(f)
        except ValueError as e:
            die('%s is not valid JSON: %s' % (path, e))
    if not isinstance(m, dict):
        die('%s is not a JSON object.' % path)
    recipe = m.get('recipe')
    if not isinstance(recipe, dict):
        die('%s has no "recipe" object.' % path)
    repo = str(recipe.get('repo') or '').rstrip('/')
    if repo.endswith('.git'):
        repo = repo[:-4]
    if repo != MXE_REPO:
        die('%s was collected for the recipe %r, not %s.' % (path, recipe.get('repo'), MXE_REPO))
    if recipe.get('ref') != release:
        die('%s was collected for build-win64-mxe %r, but this pack is cut from %s — '
            'collect the licence texts again for %s.' % (path, recipe.get('ref'), release, release))
    components = m.get('components')
    if not isinstance(components, dict) or not components:
        die('%s has no "components" object.' % path)
    known = set(k for _, k in MXE_COMPONENTS) | set(MXE_BUILT_IN)
    problems = []
    for key, c in components.items():
        where = '%s: %s' % (os.path.basename(path), key)
        if key not in known:
            problems.append('%s is a component third-party.py does not know: add its DLLs to '
                            'MXE_COMPONENTS, or its host to MXE_BUILT_IN' % where)
        if not isinstance(c, dict):
            problems.append('%s is not an object' % where)
            continue
        for field in ('version', 'spdx'):
            if not isinstance(c.get(field), str) or not c[field].strip():
                problems.append('%s has no %s' % (where, field))
        src = c.get('source')
        if (not isinstance(src, dict) or not re.match(r'https?://\S+$', str(src.get('url') or ''))
                or not SHA256.fullmatch(str(src.get('sha256') or ''))):
            problems.append('%s needs a source with an http(s) url and a sha256' % where)
        platforms = c.get('platforms')
        if (not isinstance(platforms, list) or not platforms
                or any(p not in MXE_ARCHES for p in platforms)):
            problems.append('%s: platforms must be a non-empty list of %s'
                            % (where, ', '.join(MXE_ARCHES)))
        notes = str(c.get('notes') or '').strip()
        if key in MXE_BUILT_IN:
            host = MXE_BUILT_IN[key] or 'every DLL'
            if not notes.startswith('Statically linked into: ' + host):
                problems.append('%s: its notes must say it is "Statically linked into: %s", '
                                'as MXE_BUILT_IN does' % (where, host))
        files = c.get('files')
        if not isinstance(files, list):
            problems.append('%s has no files list' % where)
            continue
        if not files:
            if not is_public_domain(str(c.get('spdx') or '')):
                problems.append('%s ships no licence text, and its licence (%s) is not a '
                                'public-domain dedication that needs none' % (where, c.get('spdx')))
            elif not notes:
                problems.append('%s ships no licence text and gives no notes saying why' % where)
        names = set()
        for i, fe in enumerate(files):
            fwhere = '%s, file %d' % (where, i + 1)
            if not isinstance(fe, dict):
                problems.append('%s is not an object' % fwhere)
                continue
            name, rel = fe.get('name'), fe.get('path')
            if not valid_text_name(name):
                problems.append('%s: name must be a relative path of plain names, got %r'
                                % (fwhere, name))
            elif name in names:
                problems.append('%s: two files named %s' % (fwhere, name))
            else:
                names.add(name)
            if not valid_text_name(rel):
                problems.append('%s: path must be relative to the manifest\'s directory, '
                                'got %r' % (fwhere, rel))
            elif valid_text_name(name) and rel != '%s/%s' % (key, name):
                problems.append('%s: path %s is not %s/%s' % (fwhere, rel, key, name))
            if not SHA256.fullmatch(str(fe.get('sha256') or '')):
                problems.append('%s: no sha256' % fwhere)
        if key in versions and isinstance(c.get('version'), str) and c['version'] != versions[key]:
            problems.append('%s is version %s, but the release\'s versions.json says %s'
                            % (where, c['version'], versions[key]))
    if problems:
        die('%s is malformed or stale:\n  ' % path + '\n  '.join(problems))
    return recipe, components


def mpl_crates_from_texts(files, notes):
    """The MPL-licensed crates of a component, as (name, version) pairs: the
    crates/<name>-<version>/<file> among its licence texts whose text is the
    MPL's, and those its notes name ("MPL crates: <name> <version>, ...,
    each at ...") — a crate that ships no licence file of its own (selectors)
    is known only from there. <files> is (path on disk, name in the manifest)
    pairs."""
    found = set()
    for src, name in files:
        m = re.match(r'crates/(.+)-(\d[^/]*)/', name)
        if not m:
            continue
        with open(src, 'rb') as f:
            if b'Mozilla Public License' in f.read():
                found.add((m.group(1), m.group(2)))
    listed = re.search(r'MPL crates: (.+?), each at', notes or '')
    if listed:
        for item in listed.group(1).split(','):
            parts = item.split()
            if len(parts) == 2:
                found.add((parts[0], parts[1]))
    return sorted(found)


def mxe(args):
    platform = pack_platform(args.pack)
    arch = platform[len('windows-'):] if platform.startswith('windows-') else None
    if arch not in MXE_ARCHES:
        die('%s is not a Windows pack (vips-windows-<%s>.zip).' % (args.pack, '|'.join(MXE_ARCHES)))
    bundle, root = os.path.abspath(args.bundle), os.path.abspath(args.zip_root)
    versions_path = os.path.join(root, 'versions.json')
    licence_path = os.path.join(root, 'LICENSE')
    for p in (versions_path, licence_path):
        if not os.path.isfile(p):
            die('%s is missing from the build-win64-mxe archive — upstream layout '
                'changed?' % p)
    with open(versions_path, encoding='utf-8') as f:
        versions = json.load(f)
    manifest_path = os.path.abspath(args.license_manifest)
    texts_root = os.path.dirname(manifest_path)
    recipe, manifest = load_manifest(manifest_path, args.release, versions)

    files, links = bundle_entries(bundle)
    attributed = OrderedDict()   # bundle path -> component key ('' = ours)
    problems = []
    for rel in files:
        if own_file(rel):
            attributed[rel] = ''
            continue
        base = rel.rsplit('/', 1)[-1]
        hits = [key for pattern, key in MXE_COMPONENTS if re.fullmatch(pattern, base)]
        if len(hits) != 1:
            problems.append('%s: %s' % (rel, 'matches no component' if not hits
                                        else 'matches more than one component'))
            continue
        key = hits[0]
        if key not in MXE_UNLISTED and key not in versions:
            problems.append('%s: component %s is not in versions.json' % (rel, key))
            continue
        attributed[rel] = key
    if links:
        problems.append('links in a Windows bundle: ' + ', '.join(links))
    if problems:
        die('cannot attribute every file in %s:\n  ' % bundle + '\n  '.join(problems))

    components = OrderedDict()   # component key -> its files in the pack
    for rel, key in attributed.items():
        if key != '':
            components.setdefault(key, []).append(rel)
    # Built into the DLLs above, with no DLL of their own.
    built_in = [k for k, host in MXE_BUILT_IN.items() if host is None or host in components]
    built_in += [k for k in MXE_ALWAYS if k not in components and k not in built_in]
    built_in.sort()
    for key in sorted(components):
        c = manifest.get(key)
        if c is None:
            problems.append('%s (%s) is in the pack, but %s does not list it'
                            % (key, ', '.join(components[key]), manifest_path))
    for key in built_in:
        if key not in manifest:
            host = MXE_BUILT_IN.get(key)
            problems.append('%s is built into %s, but %s does not list it'
                            % (key, 'every DLL' if host is None else '%s\'s DLLs' % host,
                               manifest_path))
    for key in sorted(components) + built_in:
        c = manifest.get(key)
        if c is not None and arch not in c['platforms']:
            problems.append('%s is in the %s pack, but %s lists it only for %s'
                            % (key, arch, manifest_path, ', '.join(c['platforms'])))
    if problems:
        die('the licence-text manifest does not cover this pack:\n  ' + '\n  '.join(problems))
    in_pack = sorted(components) + built_in

    listed = check_disclosed(platform, OrderedDict((k, manifest[k]['spdx']) for k in in_pack),
                             args.disclosed)
    recipe_url = '%s/tree/%s' % (MXE_REPO, args.release)
    source_rows = [(k, manifest[k]['version'], manifest[k]['spdx'],
                    [(manifest[k]['source']['url'], manifest[k]['source']['sha256'])],
                    '[recipe](%s)' % recipe_url)
                   for k in in_pack
                   if classify(manifest[k]['spdx']) in COPYLEFT_CLASSES or k in listed]
    check_sources(source_rows)

    # Every text verified before anything is written.
    mismatched, texts = [], OrderedDict()
    for key in in_pack:
        texts[key] = []
        for fe in manifest[key]['files']:
            src = os.path.realpath(os.path.join(texts_root, *fe['path'].split('/')))
            if not src.startswith(os.path.realpath(texts_root) + os.sep):
                mismatched.append('%s: %s leads out of %s' % (key, fe['path'], texts_root))
                continue
            if not os.path.isfile(src):
                mismatched.append('%s: %s is missing' % (key, fe['path']))
                continue
            digest = sha256_of(src)
            if digest != fe['sha256']:
                mismatched.append('%s: %s hashes to %s, the manifest says %s'
                                  % (key, fe['path'], digest, fe['sha256']))
                continue
            texts[key].append((src, fe['name']))
    if mismatched:
        die('licence texts that do not match %s:\n  ' % manifest_path + '\n  '.join(mismatched))
    # The release zip's own copy of libvips's licence is the manifest's.
    if 'vips' in texts:
        own = [src for src, name in texts['vips'] if name == 'LICENSE']
        with open(licence_path, 'rb') as f:
            zip_licence = f.read()
        if not own or open(own[0], 'rb').read() != zip_licence:
            die('the release zip\'s LICENSE (%s) is not the manifest\'s vips/LICENSE — the '
                'manifest was collected from another libvips; collect it again.' % licence_path)

    reset_kit(bundle)
    copy_common_texts(bundle)
    for key, entries in texts.items():
        for src, name in entries:
            dest = os.path.join(bundle, LICENSES, key, *name.split('/'))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copyfile(src, dest)
    toolchain, runtime = MXE_SHIM_TOOLCHAIN[arch]
    if arch == 'x86_64':
        write_canonical_text('GCC-exception-3.1',
                             os.path.join(bundle, LICENSES, 'Vips-Native', 'GCC-exception-3.1.txt'))
    unicode = unicode_hosts(in_pack)
    if unicode:
        write_canonical_text('Unicode-3.0', os.path.join(bundle, LICENSES, 'Unicode-3.0.txt'))
    crates = []
    if 'rsvg-crates' in texts:
        found = mpl_crates_from_texts(texts['rsvg-crates'], manifest['rsvg-crates'].get('notes'))
        if not found and WEAK_TOKEN.search(manifest['rsvg-crates']['spdx']):
            die('rsvg-crates declares %s, but neither its texts nor its notes name an MPL '
                'crate — say which, so the pack can point to their source.'
                % manifest['rsvg-crates']['spdx'])
        if found:
            crates.append(('librsvg (the rsvg-crates component)', found))
    acks = acknowledgements(OrderedDict((k, manifest[k]['version']) for k in in_pack))
    public_domain = [k for k in in_pack if not manifest[k]['files']]

    def text_paths(key):
        return ['%s/%s/%s' % (LICENSES, key, name) for _, name in texts[key]]

    mingw_notice = text_paths('mingw-w64')
    compiler_rt = [t for t in text_paths(MXE_LLVM_RUNTIME) if '/compiler-rt/' in t]
    release = '%s/releases/tag/%s' % (MXE_REPO, args.release)

    def version_of(key):
        return manifest[key]['version']

    def texts_cell(key):
        cell = [code(t) for t in text_paths(key)]
        if cell:
            return '<br>'.join(cell)
        return 'none: public domain, no licence text upstream (see **Notes**)'

    def source_cell(key):
        s = manifest[key]['source']
        return '[source](%s) sha256 %s' % (s['url'], code(s['sha256']))

    lines = []
    w = lines.append
    w('# Third-party software in %s' % args.pack)
    w('')
    w('This archive is a prebuilt binary pack for Vips::Native (%s). Its DLLs are '
      'taken unmodified from %s of [libvips/build-win64-mxe](%s), release '
      '[%s](%s); the recipe that built every component is that repository at that '
      'tag: <%s>. The files of Vips::Native\'s own are the varargs shim (%s, '
      'Artistic-2.0, `LICENSES/Vips-Native/LICENSE`).' % (
          code(args.tag), code(args.zip_name), MXE_REPO, args.release, release, recipe_url,
          ', '.join(code(f) for f, k in attributed.items() if k == '' and not f.endswith('.srchash'))))
    w('')
    w('The shim is compiled by Vips::Native\'s release workflow with MSYS2\'s %s toolchain, '
      'and statically links that toolchain\'s mingw-w64 runtime, under the same notice as '
      'the mingw-w64 component below (%s), and %s, %s.' % (
          toolchain, ', '.join(code(t) for t in mingw_notice) or code('%s/mingw-w64/' % LICENSES),
          runtime,
          'under the GCC Runtime Library Exception (`LICENSES/Vips-Native/GCC-exception-3.1.txt`, '
          'with `LICENSES/GPL-3.0.txt`)' if arch == 'x86_64' else
          'under the llvm-runtime component\'s terms (%s)' % (
              ', '.join(code(t) for t in compiler_rt) or code('%s/%s/' % (LICENSES, MXE_LLVM_RUNTIME)))))
    w('')
    w('- Every DLL in this archive is listed under **Files** with the component that '
      'built it.')
    w('- Each component\'s licence (SPDX), version and upstream source archive are '
      'listed under **Components**, and its licence texts — as its upstream source '
      'distributes them — are in `LICENSES/<component>/`. Every text was checked '
      'against a pinned SHA-256 when this pack was built.')
    w('- Components built into the DLLs, with no DLL of their own, are under '
      '**Components with no file of their own**.')
    w('- The release\'s own `versions.json` is under **Components in the release**.')
    w('')
    write_licence_classes(
        w, OrderedDict((k, manifest[k]['spdx']) for k in in_pack),
        [k for k in in_pack if 'LGPL-3' in manifest[k]['spdx']])
    if public_domain:
        w('**No licence text needed.** %s: public domain, with no licence text upstream, '
          'and none is invented here (see **Notes**).' % and_list(
              '%s (declared licence: %s)' % (k, manifest[k]['spdx']) for k in public_domain))
        w('')
    write_acknowledgements(w, acks, unicode)
    write_sources(w, source_rows, crates)
    w('## Components')
    w('')
    w('| Component | Version | Licence | Files | Licence texts | Source |')
    w('|---|---|---|---|---|---|')
    for key in sorted(components):
        w('| %s | %s | %s | %s | %s | %s |' % (
            md(key), md(version_of(key)), md(manifest[key]['spdx']),
            '<br>'.join(code(r) for r in components[key]), texts_cell(key), source_cell(key)))
    w('')
    if built_in:
        w('## Components with no file of their own')
        w('')
        w('Built into the DLLs above — statically linked, each into the component its '
          'notes name (**Notes**) — so with no DLL of their own. Their licence texts ship '
          'all the same.')
        w('')
        w('| Component | Version | Licence | Licence texts | Source |')
        w('|---|---|---|---|---|')
        for key in built_in:
            w('| %s | %s | %s | %s | %s |' % (
                md(key), md(version_of(key)), md(manifest[key]['spdx']),
                texts_cell(key), source_cell(key)))
        w('')
    notes = [(k, MXE_UNLISTED.get(k), str(manifest[k].get('notes') or '').strip()) for k in in_pack]
    notes = [(k, u, n) for k, u, n in notes if u or n]
    if notes:
        w('## Notes')
        w('')
        for key, unlisted, note in notes:
            w('- **%s**: %s' % (md(key), md(' '.join(x for x in (
                (unlisted[0].upper() + unlisted[1:] + '.') if unlisted else '', note) if x))))
        w('')
    w('## Files')
    w('')
    w('| File | From |')
    w('|---|---|')
    for rel, key in sorted(attributed.items()):
        src = 'Vips::Native (Artistic-2.0)' if key == '' else '%s %s' % (key, version_of(key))
        w('| %s | %s |' % (code(rel), md(src)))
    w('')
    w('## Components in the release')
    w('')
    w('The release\'s `versions.json`, whole (some components are linked '
      'statically, or not bundled here):')
    w('')
    w('```')
    for key in sorted(versions):
        w('%s=%s' % (key, versions[key]))
    w('```')
    write_notices(bundle, lines)
    print('✅ %s: %d files attributed to %d components + Vips::Native (%d more built in); '
          '%d licence texts.' % (NOTICES, len(attributed), len(components), len(built_in),
                                  sum(len(t) for t in texts.values())))


def write_notices(bundle, lines):
    with open(os.path.join(bundle, NOTICES), 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')


def main():
    # A Windows runner gives python a cp1252 stdout and stderr, which have
    # no ✅ or ❌: printing one raises, and a refusal's reason is lost behind
    # the UnicodeEncodeError. Every runner's log reads UTF-8.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding='utf-8')

    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='source', required=True)

    c = sub.add_parser('conda', help='a bundle cut from a conda-forge environment')
    c.add_argument('--prefix', required=True, help='the conda environment')
    c.add_argument('--bundle', required=True)
    c.add_argument('--pack', required=True,
                   help='the archive name, vips-<platform>.tar.gz: the heading, and the '
                        'platform the disclosure list is checked for')
    c.add_argument('--tag', required=True, help='the BINARY_TAG')
    c.add_argument('--spec', action='append', required=True,
                   help='a package spec the environment was created from (repeatable)')
    c.add_argument('--pkgs-dir', action='append', default=[],
                   help='a package cache to look for extracted packages in (repeatable)')
    c.add_argument('--disclosed', default=DISCLOSED,
                   help='the disclosure list (default: scripts/ci/disclosed.json)')
    c.set_defaults(run=conda)

    m = sub.add_parser('mxe', help='a bundle cut from a libvips/build-win64-mxe zip')
    m.add_argument('--zip-root', required=True,
                   help='the extracted vips-dev-<M>.<m> directory')
    m.add_argument('--zip-name', required=True, help='the release asset it came from')
    m.add_argument('--release', required=True, help='the release tag, e.g. v8.18.7')
    m.add_argument('--bundle', required=True)
    m.add_argument('--pack', required=True,
                   help='the archive name, vips-windows-<arch>.zip: the heading, the '
                        'architecture the manifest is read for, and the platform the '
                        'disclosure list is checked for')
    m.add_argument('--tag', required=True)
    m.add_argument('--license-manifest', default=WINDOWS_MANIFEST,
                   help='the licence-text manifest; its files\' paths are relative to its '
                        'directory (default: scripts/ci/license-texts/windows/manifest.json)')
    m.add_argument('--disclosed', default=DISCLOSED,
                   help='the disclosure list (default: scripts/ci/disclosed.json)')
    m.set_defaults(run=mxe)

    args = ap.parse_args()
    if not os.path.isdir(args.bundle):
        die('no bundle directory at %s' % args.bundle)
    args.run(args)


if __name__ == '__main__':
    main()
