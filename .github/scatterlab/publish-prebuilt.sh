#!/usr/bin/env bash
# Cut a `prebuilt-ios-<version>` release from a completed build run.
#
# Why this is not a CI step: the scatterlab org has an IP allow list, and a
# GitHub-hosted runner is not on it, so every authenticated api.github.com WRITE from
# CI fails with HTTP 403 ("the `scatterlab` organization has an IP allow list enabled").
# Workflow artifact upload is unaffected, so CI builds and uploads, and the release is
# cut from a machine whose IP is allowed.
#
# Usage: publish-prebuilt.sh <fork version> [run-id]
#   run-id defaults to the most recent successful scatterlab-prebuild-ios.yml run.
set -euo pipefail

VERSION=${1:?usage: publish-prebuilt.sh <fork version> [run-id]}
RUN=${2:-}
REPO=scatterlab/react-native
TAG="prebuilt-ios-$VERSION"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-scatterlab\.[0-9]+$ ]]; then
  echo "version must look like 0.86.2-scatterlab.4" >&2
  exit 1
fi

if [ -z "$RUN" ]; then
  RUN=$(gh run list --repo "$REPO" --workflow scatterlab-prebuild-ios.yml \
    --status success --limit 1 --json databaseId -q '.[0].databaseId')
  [ -n "$RUN" ] || { echo "no successful build run found" >&2; exit 1; }
fi
echo "Using run $RUN"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gh run download "$RUN" --repo "$REPO" --pattern 'prebuilt-ios-*' --dir "$WORK"

# Artifacts land in one subdirectory per artifact.
FILES=$(find "$WORK" -type f -name '*.tar.gz' -o -type f -name '*.tar.gz.sha1' | sort)
[ -n "$FILES" ] || { echo "run $RUN carries no prebuilt artifacts" >&2; exit 1; }
echo "$FILES" | while IFS= read -r f; do echo "  $(basename "$f")  $(wc -c < "$f") bytes"; done

# Every asset must belong to the version being released, or consumers would resolve a
# URL that does not exist.
echo "$FILES" | while IFS= read -r f; do
  case "$(basename "$f")" in
    "react-native-artifacts-$VERSION-"*) ;;
    *) echo "asset $(basename "$f") is not for $VERSION" >&2; exit 1 ;;
  esac
done

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG exists; adding assets to it."
else
  gh release create "$TAG" --repo "$REPO" \
    --target "$(git rev-parse HEAD)" \
    --title "iOS prebuilt core for $VERSION" \
    --notes "React.xcframework built from this fork for @scatterlab/react-native@$VERSION. Consumed by scripts/cocoapods/rncore.rb." \
    --prerelease
fi

# No --clobber: a replaced asset is undetectable to a consumer with a warm
# ~/Library/Caches/ReactNative entry, so publish a new -scatterlab.N instead.
# shellcheck disable=SC2086
gh release upload "$TAG" --repo "$REPO" $FILES

echo "== verifying =="
for flavor in debug release; do
  name="react-native-artifacts-$VERSION-reactnative-core-$flavor.tar.gz"
  url="https://github.com/$REPO/releases/download/$TAG/$name"
  # The literal existence gate from rncore.rb#artifact_exists.
  code=$(curl -o /dev/null --silent -Iw '%{http_code}' -L "$url")
  [ "$code" = "200" ] || { echo "$url returned $code; rncore.rb would fall back to upstream" >&2; exit 1; }
  sha1=$(curl -sL "$url.sha1")
  [[ "$sha1" =~ ^[a-fA-F0-9]{40}$ ]] || { echo "$url.sha1 is not 40 bare hex chars; integrity checks would be skipped" >&2; exit 1; }
  echo "  $flavor OK  sha1=$sha1"
done
echo "release $TAG is consumable"
