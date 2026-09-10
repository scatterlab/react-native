#!/usr/bin/env bash
# Smoke test for scripts/android/scatterlab-prebuilt-maven.gradle.
#
# The script reads the package name and version relative to its own file, so each case builds
# a throwaway tree that mimics node_modules/react-native and copies the script into it.
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
  # Preserve the script's own exit status: the Gradle daemons started per case keep writing
  # into their sandboxed GRADLE_USER_HOME after the build returns, so the rm below races them
  # and can fail. That is housekeeping, not a verdict - it must never turn a passing run red
  # (or, worse, a failing one green).
  local rc=$?
  if [ -n "$httpd_pid" ]; then
    kill "$httpd_pid" 2>/dev/null || true
  fi
  rm -rf "$WORK" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT
failures=0
skipped=0

# Lays out <root>/rn/{package.json,scripts/android/<script>} plus a consumer project whose
# settings.gradle applies the script and whose build.gradle prints the resolved property.
# The package name defaults to this fork's, since that is what the script keys on; case A
# passes the upstream name to exercise the no-op path.
setup_case() {
  local name=$1 version=$2 pkg_name=${3:-@scatterlab/react-native}
  local dir="$WORK/$name"
  mkdir -p "$dir/rn/scripts/android" "$dir/app" "$dir/gradlehome"
  printf '{"name":"%s","version":"%s"}\n' "$pkg_name" "$version" > "$dir/rn/package.json"
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

# For environment gaps (no python3, no free local port) rather than behavior failures.
# Always annotates, so the gap is visible in a folded Actions log instead of hiding inside
# "all cases passed". Under CI it is a hard failure: these runners are ours, so a missing
# python3 is a runner defect to learn about on the first dry run, not coverage to lose
# silently on every release. Locally it stays a skip.
skip() {
  local label=$1 reason=$2
  echo "::warning::android-prebuilt-consumer-test skipped '$label' ($reason)"
  if [ -n "${CI:-}" ]; then
    echo "FAIL - $label (skipped under CI: $reason)"
    failures=$((failures + 1))
  else
    echo "SKIP - $label ($reason)"
    skipped=$((skipped + 1))
  fi
}

# A: an upstream install must be a no-op, so this script can ship in a package that is
#    installed straight from npmjs. The discriminator is the package name, not the version
#    shape - an upstream nightly or rc must be just as untouched.
dir=$(setup_case upstream "0.87.1" "react-native")
run_case "$dir"
check "upstream package leaves the property unset" "PROBE_SET=false" "$LAST_OUTPUT"

# A2: our package at a version that names no release must stop the build rather than fall
#     through to Maven Central. This is the shape a nightly or an rc suffix would take.
dir=$(setup_case unresolvable "0.87.1-scatterlab.4-rc.1")
run_case "$dir"
check_fails "an unresolvable fork version aborts" "does not name a prebuilt Android release"

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

# C: a warm cache must be reused as-is, with no network. The cache is staged with the .pom
#    the script checks for, because an empty directory is exactly what must NOT count as
#    warm (see case C2). Gradle's --offline does not cover this - the script downloads
#    through a raw URL.openConnection() that Gradle knows nothing about - so "no network"
#    is proved by pointing the base URL at a closed loopback port: any download attempt
#    would be refused and fail the build, and the case passing means none was made.
dir=$(setup_case cached "0.87.1-scatterlab.998")
cached_maven="$dir/gradlehome/scatterlab-react-native/0.87.1-scatterlab.998/maven"
mkdir -p "$cached_maven/com/facebook/react/react-android/0.87.1"
echo cached-pom > "$cached_maven/com/facebook/react/react-android/0.87.1/react-android-0.87.1.pom"
SCATTERLAB_PREBUILT_BASE_URL="http://127.0.0.1:1" run_case "$dir"
check "warm cache is used with no download" "PROBE_VALUE=$cached_maven" "$LAST_OUTPUT"

# C2: a directory that exists but holds no artifact is a broken cache, not a warm one. The
#     script must re-download rather than hand Gradle a tree it cannot resolve from - here
#     there is no release to re-download, so "it tried" shows up as the usual abort.
dir=$(setup_case cached-empty "0.87.1-scatterlab.995")
mkdir -p "$dir/gradlehome/scatterlab-react-native/0.87.1-scatterlab.995/maven"
run_case "$dir"
check_fails "an empty cache directory is not treated as warm" "prebuilt-android-0.87.1-scatterlab.995"

# E: SCATTERLAB_PREBUILT_BASE_URL is a test seam, and the .sha256 sidecar comes from the same
#    base - so a non-loopback origin would hand over the archive and its own checksum. It must
#    stop the build, not quietly fall back to the real release (which would mask the
#    misconfiguration and hide that someone set the variable at all).
dir=$(setup_case rogue-base-url "0.87.1-scatterlab.994")
SCATTERLAB_PREBUILT_BASE_URL="http://prebuilt-test-rogue.invalid/releases/download" run_case "$dir"
check_fails "a non-loopback SCATTERLAB_PREBUILT_BASE_URL is rejected" \
  "whose host is not a loopback address"

# D: cold-cache success path - the one every first build on a developer machine or CI runner
#    takes, and the one no case above covers. Serves a fixture release over a real local HTTP
#    server via SCATTERLAB_PREBUILT_BASE_URL (consulted by the script only when set and
#    loopback - see the comment on overrideBaseUrl there; unset, the URL is the real GitHub
#    host), then asserts an artifact lands at the exact Maven path the producer's tar and the
#    consumer's extract-then-rename have to agree on.
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
