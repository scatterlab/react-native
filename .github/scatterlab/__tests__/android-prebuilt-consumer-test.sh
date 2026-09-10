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
httpd_pid=""
cleanup() {
  if [ -n "$httpd_pid" ]; then
    kill "$httpd_pid" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
failures=0
skipped=0

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
  LAST_OUTPUT=$( cd "$dir/app" && GRADLE_USER_HOME="$dir/gradlehome" SCATTERLAB_PREBUILT_BASE_URL="${SCATTERLAB_PREBUILT_BASE_URL:-}" "$GRADLE" --offline -q probe "$@" 2>&1 )
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

# For environment gaps (no python3, no free local port) rather than behavior failures - never
# counts toward $failures or the exit code, and is spelled distinctly from "ok " so it can't be
# misread as a pass while scanning output.
skip() {
  local label=$1 reason=$2
  echo "SKIP - $label ($reason)"
  skipped=$((skipped + 1))
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

# D: cold-cache success path - the one every first build on a developer machine or CI runner
#    takes, and the one no case above covers. Serves a fixture release over a real local HTTP
#    server via SCATTERLAB_PREBUILT_BASE_URL (consulted by the script only when set - see the
#    comment on assetUrl there; unset, the URL is the real GitHub host), then asserts an
#    artifact lands at the exact Maven path the producer's tar and the consumer's
#    extract-then-rename have to agree on.
#
# This whole test runs in the workflow's `prepare` job, gating every release, so an
# environment gap here (no python3, no free local port) must SKIP this one case rather than
# fail the script - it is not evidence the consumer script is broken, and a flaky gate on the
# release path is worse than no gate. Once the server is actually up, every assertion below is
# a real behavior check and stays a hard failure.
if ! command -v python3 >/dev/null 2>&1; then
  skip "cold-cache success path" "python3 not found"
else
  cold_version="0.87.1-scatterlab.997"
  cold_tag="prebuilt-android-$cold_version"
  cold_asset="react-native-android-maven-$cold_version.tar.gz"

  # Built the same way the producer's "Pack the Maven repository" step does: the archive root
  # IS the repository root (tar -C <root> -czf ... .), so a drift there is exactly what this
  # case is meant to catch. Hand-writing the tar differently would test nothing.
  fixture_root="$WORK/fixture-src"
  mkdir -p "$fixture_root/com/facebook/react/react-android/0.87.1"
  echo fixture-pom > "$fixture_root/com/facebook/react/react-android/0.87.1/react-android-0.87.1.pom"

  fixtures_dir="$WORK/fixtures/$cold_tag"
  mkdir -p "$fixtures_dir"
  tar -C "$fixture_root" -czf "$fixtures_dir/$cold_asset" .
  ( cd "$fixtures_dir" && sha256sum "$cold_asset" | awk '{print $1}' > "$cold_asset.sha256" )

  # -u: unbuffered stdout, or the startup line (which the loop below polls for) sits in a
  # pipe buffer indefinitely once stdout isn't a tty.
  python3 -u -m http.server 0 --directory "$WORK/fixtures" --bind 127.0.0.1 > "$WORK/httpd.log" 2>&1 &
  httpd_pid=$!
  disown "$httpd_pid" 2>/dev/null || true  # suppress bash's "Terminated" job-control notice on kill
  port=""
  for _ in $(seq 1 50); do
    port=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$WORK/httpd.log" | head -1)
    [ -n "$port" ] && break
    sleep 0.1
  done

  if [ -z "$port" ]; then
    skip "cold-cache success path" "fixture server did not start"
    cat "$WORK/httpd.log" >&2
  else
    dir=$(setup_case cold-cache "$cold_version")
    SCATTERLAB_PREBUILT_BASE_URL="http://127.0.0.1:$port" run_case "$dir"
    check "cold cache downloads and extracts" \
      "PROBE_VALUE=$dir/gradlehome/scatterlab-react-native/$cold_version/maven" \
      "$LAST_OUTPUT"
    landed="$dir/gradlehome/scatterlab-react-native/$cold_version/maven/com/facebook/react/react-android/0.87.1/react-android-0.87.1.pom"
    if [ -f "$landed" ]; then
      echo "ok   - cold cache lands the fixture artifact at its Maven path"
    else
      echo "FAIL - cold cache lands the fixture artifact at its Maven path"
      echo "       expected: $landed"
      failures=$((failures + 1))
    fi
  fi

  kill "$httpd_pid" 2>/dev/null || true
  httpd_pid=""
fi

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
if [ "$skipped" -gt 0 ]; then
  echo "all cases passed ($skipped skipped)"
else
  echo "all cases passed"
fi
