#!/usr/bin/env bash
# Compare a packed fork tarball against the upstream react-native tarball of the
# same base version. Every file must be byte-identical except the ones listed in
# allowed-tarball-diff.txt.
#
# LC_ALL=C is not cosmetic: under a non-C locale `comm` mis-collates these file
# lists and reports files as added that are present in both.
set -euo pipefail
export LC_ALL=C

FORK_TGZ=${1:?usage: verify-tarball.sh <fork.tgz> <base-version>}
BASE_VERSION=${2:?usage: verify-tarball.sh <fork.tgz> <base-version>}
ALLOWLIST=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/allowed-tarball-diff.txt

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Fetching upstream react-native@${BASE_VERSION}"
( cd "$WORK" && npm pack "react-native@${BASE_VERSION}" --registry=https://registry.npmjs.org >/dev/null )

mkdir -p "$WORK/fork" "$WORK/base"
tar xzf "$FORK_TGZ" -C "$WORK/fork"
tar xzf "$WORK/react-native-${BASE_VERSION}.tgz" -C "$WORK/base"

( cd "$WORK/fork/package" && find . -type f | sed 's|^\./||' | sort ) > "$WORK/fork.txt"
( cd "$WORK/base/package" && find . -type f | sed 's|^\./||' | sort ) > "$WORK/base.txt"
grep -vE '^\s*(#|$)' "$ALLOWLIST" | sort > "$WORK/allowed.txt"

echo "fork: $(wc -l < "$WORK/fork.txt") files, upstream: $(wc -l < "$WORK/base.txt") files"

failed=0

# Added / missing files are only tolerated if allowlisted.
if comm -23 "$WORK/fork.txt" "$WORK/base.txt" | comm -23 - "$WORK/allowed.txt" | grep . ; then
  echo "FAIL: files present in the fork tarball but not upstream (and not allowlisted)"
  failed=1
fi
if comm -13 "$WORK/fork.txt" "$WORK/base.txt" | comm -23 - "$WORK/allowed.txt" | grep . ; then
  echo "FAIL: files missing from the fork tarball (and not allowlisted)"
  failed=1
fi

changed=$(comm -12 "$WORK/fork.txt" "$WORK/base.txt" | while IFS= read -r rel; do
  cmp -s "$WORK/fork/package/$rel" "$WORK/base/package/$rel" || echo "$rel"
done | sort)

unexpected=$(comm -23 <(printf '%s\n' "$changed" | grep . || true) "$WORK/allowed.txt" || true)
if [ -n "$unexpected" ]; then
  echo "FAIL: unexpected byte differences:"
  printf '  %s\n' $unexpected
  failed=1
fi

echo "changed vs upstream:"
printf '  %s\n' ${changed:-"(none)"}

[ "$failed" -eq 0 ] || exit 1
echo "OK: tarball differs from upstream only in allowlisted files"
