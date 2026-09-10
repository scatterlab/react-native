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

# Runs gradle for $dir, forwarding any extra args (e.g. -D system properties). Leaves the
# output in $LAST_OUTPUT and the exit code in $LAST_EXIT rather than propagating a non-zero
# exit through `set -e`, since the failure cases under test are expected to fail.
run_case() {
  local dir=$1
  shift
  set +e
  LAST_OUTPUT=$( cd "$dir/app" && GRADLE_USER_HOME="$dir/gradlehome" "$GRADLE" --offline -q probe "$@" 2>&1 )
  LAST_EXIT=$?
  set -e
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

# Like check, but also requires the build to have exited non-zero - for cases whose whole
# point is that the build must not silently succeed.
check_fails() {
  local label=$1 expected=$2
  if [[ "$LAST_EXIT" -eq 0 ]]; then
    echo "FAIL - $label"
    echo "       expected a non-zero exit, got 0"
    failures=$((failures + 1))
    return
  fi
  check "$label" "$expected" "$LAST_OUTPUT"
}

# A: an upstream version must be a no-op, so this script can ship in a package that is
#    installed straight from npmjs without a fork suffix.
dir=$(setup_case upstream "0.87.1")
run_case "$dir"
check "upstream version leaves the property unset" "PROBE_SET=false" "$LAST_OUTPUT"

# B: a fork version with no release must stop the build. Falling through to Maven Central
#    would ship the unpatched upstream AAR with no error. The abort message is asserted on
#    "Expected: <assetUrl>" text, which the script's fail() always includes regardless of
#    whether the download got as far as an HTTP status (a real 404) or never resolved a host
#    at all (no network) - both must fail the build the same way, so this is run twice: once
#    hitting the real (nonexistent) GitHub release, once with DNS forced unreachable via a
#    proxy host that can never resolve (RFC 2606 reserves the .invalid TLD for exactly this).
missing_dir=$(setup_case missing "0.87.1-scatterlab.999")
run_case "$missing_dir"
check_fails "missing release aborts (real network)" "prebuilt-android-0.87.1-scatterlab.999"

missing_dir_nodns=$(setup_case missing-nodns "0.87.1-scatterlab.999")
run_case "$missing_dir_nodns" \
  -Dhttps.proxyHost=react-native-prebuilt-test.invalid -Dhttps.proxyPort=1
check_fails "missing release aborts (no network / DNS broken)" "prebuilt-android-0.87.1-scatterlab.999"

# C: a warm cache must be used as-is, with no network. --offline makes any download attempt
#    fail loudly instead of quietly succeeding on a machine that happens to be online.
dir=$(setup_case cached "0.87.1-scatterlab.998")
mkdir -p "$dir/gradlehome/scatterlab-react-native/0.87.1-scatterlab.998/maven"
run_case "$dir"
check "warm cache is used" \
  "PROBE_VALUE=$dir/gradlehome/scatterlab-react-native/0.87.1-scatterlab.998/maven" \
  "$LAST_OUTPUT"

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
echo "all cases passed"
