#!/usr/bin/env bash
# Fail if any ELF file in a Linux bundle needs a glibc newer than
# Build.rakumod's $MIN-GLIBC: the oldest glibc Build lets the prebuilt
# install on. A library over it would load on the build runner and die
# on an older distribution with "GLIBC_2.xx not found".
#
#   bash scripts/ci/check-glibc-floor.sh <bundle-dir> <Build.rakumod>
#
# The floor is read from Build.rakumod, so the two can't disagree. The
# packs are conda-forge builds against its glibc 2.17 sysroot; if
# conda-forge raises that, this trips, and $MIN-GLIBC (with the README's
# platform list) has to rise to match.
set -euo pipefail

fail() {
    echo "::error::$*" >&2
    echo "❌ $*" >&2
    exit 1
}

[[ $# -eq 2 ]] || fail "usage: $0 <bundle-dir> <Build.rakumod>"
bundle=$1
build=$2
[[ -d $bundle ]] || fail "no bundle directory at $bundle"
[[ -f $build ]] || fail "no Build.rakumod at $build"
command -v readelf >/dev/null || fail "readelf not found (install binutils)"

floor=$(sed -nE 's/^[[:space:]]*constant \$MIN-GLIBC = v([0-9]+\.[0-9]+);.*/\1/p' "$build")
[[ $floor =~ ^[0-9]+\.[0-9]+$ ]] || fail "no 'constant \$MIN-GLIBC = vX.Y;' line in $build"

checked=0
newest=0
over=()
while IFS= read -r -d '' file; do
    # The bundle also holds the notices kit and the shim's sidecar.
    readelf -h "$file" >/dev/null 2>&1 || continue
    checked=$((checked + 1))
    need=$(readelf -V -W "$file" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
        | sed 's/^GLIBC_//' | sort -uV | tail -n 1 || true)
    [[ -n $need ]] || continue
    newest=$(printf '%s\n%s\n' "$newest" "$need" | sort -V | tail -n 1)
    if [[ $(printf '%s\n%s\n' "$floor" "$need" | sort -V | tail -n 1) != "$floor" ]]; then
        over+=("${file#"$bundle"/} needs GLIBC_$need")
    fi
done < <(find "$bundle" -type f -print0)

(( checked > 0 )) || fail "no ELF files in $bundle"
if (( ${#over[@]} )); then
    printf '  %s\n' "${over[@]}" >&2
    fail "${#over[@]} of $checked ELF files in $bundle need a glibc newer than \
Build.rakumod's \$MIN-GLIBC ($floor). Raise \$MIN-GLIBC, and the README's \
'glibc $floor+', to $newest — or pin the build to an older sysroot."
fi
echo "✅ $checked ELF files in $bundle: the newest glibc any needs is $newest, within Build.rakumod's \$MIN-GLIBC ($floor)."
