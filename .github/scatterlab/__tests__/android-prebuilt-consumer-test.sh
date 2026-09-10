#!/usr/bin/env bash
# Smoke test for scripts/android/scatterlab-prebuilt-maven.gradle.
#
# The script locates the package version relative to its own file, so each case builds a
# throwaway tree that mimics node_modules/react-native and copies the script into it.
# GRADLE_USER_HOME is sandboxed per case so a warm cache from one case cannot leak into
# another - the whole point of the script is what it does when the cache is cold.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SCRIPT="$REPO/packages/react-native/scripts/android/scatterlab-prebuilt-maven.gradle"
GRADLE="$REPO/gradlew"
WORK=$(mktemp -d)
WORK=$(cd "$WORK" && pwd -P)  # resolve symlinks (e.g. macOS /var -> /private/var): Gradle
                              # canonicalizes GRADLE_USER_HOME, so an unresolved $WORK would
                              # make case C compare against a path Gradle never reports.
trap 'rm -rf "$WORK"' EXIT
failures=0

# Lays out <root>/rn/{package.json,scripts/android/<script>} plus a consumer project whose
# settings.gradle applies the script and whose build.gradle prints the resolved property.
setup_case() {
  local name=$1 version=$2
  local dir="$WORK/$name"
  mkdir -p "$dir/rn/scripts/android" "$dir/app" "$dir/gradlehome"
  printf '{"name":"react-native","version":"%s"}\n' "$version" > "$dir/rn/package.json"
  cp "$SCRIPT" "$dir/rn/scripts/android/"
  cat > "$dir/app/settings.gradle" <<EOF
apply from: '../rn/scripts/android/scatterlab-prebuilt-maven.gradle'
rootProject.name = 'probe'
EOF
  cat > "$dir/app/build.gradle" <<'EOF'
tasks.register('probe') {
  doLast {
    def key = 'react.internal.mavenLocalRepo'
    println "PROBE_SET=" + project.hasProperty(key)
    if (project.hasProperty(key)) println "PROBE_VALUE=" + project.property(key)
  }
}
EOF
  echo "$dir"
}

run_case() {
  local dir=$1
  ( cd "$dir/app" && GRADLE_USER_HOME="$dir/gradlehome" "$GRADLE" --offline -q probe 2>&1 )
}

check() {
  local label=$1 expected=$2 actual=$3
  if [[ "$actual" == *"$expected"* ]]; then
    echo "ok   - $label"
  else
    echo "FAIL - $label"
    echo "       expected to contain: $expected"
    echo "       got: $actual"
    failures=$((failures + 1))
  fi
}

# A: an upstream version must be a no-op, so this script can ship in a package that is
#    installed straight from npmjs without a fork suffix.
dir=$(setup_case upstream "0.87.1")
check "upstream version leaves the property unset" "PROBE_SET=false" "$(run_case "$dir" || true)"

# B: a fork version with no release must stop the build. Falling through to Maven Central
#    would ship the unpatched upstream AAR with no error.
dir=$(setup_case missing "0.87.1-scatterlab.999")
check "missing release aborts" "prebuilt-android-0.87.1-scatterlab.999" "$(run_case "$dir" || true)"

# C: a warm cache must be used as-is, with no network. --offline makes any download attempt
#    fail loudly instead of quietly succeeding on a machine that happens to be online.
dir=$(setup_case cached "0.87.1-scatterlab.998")
mkdir -p "$dir/gradlehome/scatterlab-react-native/0.87.1-scatterlab.998/maven"
check "warm cache is used" \
  "PROBE_VALUE=$dir/gradlehome/scatterlab-react-native/0.87.1-scatterlab.998/maven" \
  "$(run_case "$dir" || true)"

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
echo "all cases passed"
