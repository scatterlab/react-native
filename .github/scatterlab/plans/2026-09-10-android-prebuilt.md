# Android prebuilt 배포 파이프라인 Implementation Plan

**진행 상태:** Task 1–3은 이 브랜치에 완료·커밋됨(`git log --oneline ff27ad0f0d8..bbda7fb082b`). Task 4(fork PR 올리기)·Task 5(zeta-frontend 배선, 다른 레포)·Task 6(출고)는 미착수.

> **For agentic workers:** Task 1–3은 완료됐으니 그 구간을 다시 실행하지 말 것. Task 4부터 이어서 진행할 때만 REQUIRED SUB-SKILL로 superpowers:subagent-driven-development(recommended) 또는 superpowers:executing-plans를 쓴다. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** fork가 수정한 Android 네이티브 코드가 실제로 소비자 앱에 실리는 경로를 만들고, 첫 화물로 `TextDecorationStyle` IndexOutOfBounds 크래시 수정을 태운다.

**Architecture:** fork CI가 `publishAllToMavenTempLocal`로 패치된 maven 트리를 만들어 GitHub Release에 올린다. fork npm 패키지에 든 Gradle settings 스크립트가 소비자 빌드의 설정 단계에서 그 tarball을 받아 캐시하고, `react.internal.mavenLocalRepo`를 그 경로로 세팅한다. 그러면 RNGP가 Maven Central에서 `com.facebook.react` 그룹을 제외하고 우리 AAR을 쓴다.

**Tech Stack:** Kotlin (ReactAndroid), Groovy (Gradle settings 스크립트), GitHub Actions, bash

**Spec:** [`.github/scatterlab/android-prebuilt.md`](../android-prebuilt.md)

## Global Constraints

이 값들을 어기면 조용히 깨진다. 모든 태스크에 암묵적으로 적용된다.

- 작업 브랜치는 `daewoon/android-prebuilt`, base는 `scatterlab/0.87.1`. `main`에 push 금지.
- `packages/react-native/ReactAndroid/gradle.properties`의 `VERSION_NAME`은 `0.87.1`로 **고정**. 절대 변경하지 않는다.
- `react.internal.publishingGroup`은 `com.facebook.react`로 고정.
- `packages/react-native/package.json`의 `@react-native/*` sibling 7개 핀은 exact `0.87.1`로 고정.
- `scripts/releases/set-version.js`와 `scripts/releases/set-rn-artifacts-version.js`는 **실행 금지**.
- `v`로 시작하는 태그 생성 금지. 릴리스 태그는 `prebuilt-android-<version>`.
- fork 버전 형식은 `0.87.1-scatterlab.N` — 대시 정확히 1개.
- 커밋 메시지 본문은 한국어. 타입 접두어(`feat`/`fix`/`ci`/`docs`/`chore`)와 코드 식별자·파일 경로·명령어는 원문 유지.
- push는 항상 브랜치 명시: `git push origin daewoon/android-prebuilt`. `--tags`/`--follow-tags` 금지 (로컬에 상류 `v0.*` 태그 660여 개).
- `packages/react-native/` 안의 파일을 새로 건드리거나 추가하면 `.github/scatterlab/allowed-tarball-diff.txt`에 그 **tarball 상대 경로**를 추가해야 한다. `packages/react-native/` 접두어는 붙이지 않는다. `ReactAndroid/src/test/**`는 `files` 필드가 제외하므로 tarball에 없다 — 추가하지 않는다.
- Gradle 실행에는 JDK 17 이상이 필요하다. `JAVA_HOME`이 그보다 낮으면 명시한다:
  `JAVA_HOME=$(/usr/libexec/java_home -v 21) ./gradlew ...`

**작업 디렉터리:** `~/GitHub/react-native/.claude/worktrees/daewoon+android-prebuilt` (Task 5만 zeta-frontend). 이 워크트리 절대경로로 파일을 연다 — 메인 체크아웃(`~/GitHub/react-native`)을 편집하면 다른 세션의 작업을 오염시킨다.

---

## File Structure

| 파일 | 책임 | 태스크 |
| --- | --- | --- |
| `packages/react-native/ReactAndroid/src/main/java/com/facebook/react/views/text/TextDecorationStyle.kt` | 잘린 layout 밖 offset을 clamp | 1 |
| `packages/react-native/ReactAndroid/src/test/java/com/facebook/react/views/text/TextDecorationStyleTest.kt` | 위 동작의 회귀 테스트 | 1 |
| `packages/react-native/scripts/android/scatterlab-prebuilt-maven.gradle` | 소비자 설정 단계: 버전 판정 · 다운로드 · 검증 · 캐시 · 프로퍼티 주입 · abort | 2 |
| `packages/react-native/package.json` | `files`에 `scripts/android` 추가 | 2 |
| `.github/scatterlab/__tests__/android-prebuilt-consumer-test.sh` | 위 스크립트의 3개 분기 스모크 테스트 | 2 |
| `.github/workflows/scatterlab-prebuild-android.yml` | AAR 빌드 · 릴리스 · 검증 | 3 |
| `.github/scatterlab/allowed-tarball-diff.txt` | 새로 다른 tarball 경로 등록 | 1, 2 |
| `CLAUDE.md` | 배포 절차에 Android 단계 추가 | 3 |
| `packages/app/android/settings.gradle.kts` (zeta-frontend) | 스크립트 apply 한 줄 | 5 |

---

### Task 1: `TextDecorationStyle` clamp 수정 (첫 화물)

상류 PR [#58366](https://github.com/react/react-native/pull/58366)의 체리픽이다. 이슈 [#58356](https://github.com/react/react-native/issues/58356). `drawSpannedDecoration()`이 잘리지 않은 전체 `Spanned`에서 온 `start`/`end`를 `Layout.getPrimaryHorizontal()`에 그대로 넘겨, `numberOfLines`로 잘린 layout에서 `IndexOutOfBoundsException`이 난다.

**Files:**
- Modify: `packages/react-native/ReactAndroid/src/main/java/com/facebook/react/views/text/TextDecorationStyle.kt`
- Test: `packages/react-native/ReactAndroid/src/test/java/com/facebook/react/views/text/TextDecorationStyleTest.kt`
- Modify: `.github/scatterlab/allowed-tarball-diff.txt`

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces: `private fun visibleTextEnd(layout: Layout): Int` — Task 3의 `verify_symbol` 게이트가 이 이름을 심볼로 찾는다.

- [x] **Step 1: 실패하는 테스트를 쓴다**

`TextDecorationStyleTest.kt`의 import 블록을 아래로 교체한다:

```kotlin
package com.facebook.react.views.text

import android.graphics.Canvas
import android.graphics.Color
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import org.assertj.core.api.Assertions.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.kotlin.any
import org.mockito.kotlin.eq
import org.mockito.kotlin.mock
import org.mockito.kotlin.verify
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class TextDecorationStyleTest {
```

기존 `class TextDecorationStyleTest {` 줄은 위 블록이 대신하므로 지운다. 클래스 닫는 `}` 직전에 아래를 넣는다:

```kotlin
  @Test
  fun drawSpannedDecorationClampsSpanPastTailEllipsis() {
    val layout = buildTailEllipsizedLayout()
    val visibleEnd = layout.getLineStart(0) + layout.getEllipsisStart(0)
    val baseline = layout.getLineBaseline(0).toFloat()
    val x1 = layout.getPrimaryHorizontal(0)
    val x2 = layout.getPrimaryHorizontal(visibleEnd)
    val canvas = mock<Canvas>()

    // The span covers the whole string, well past what survived the ellipsis; pre-fix this
    // called layout.getPrimaryHorizontal(TAIL_TEXT.length) and crashed with
    // IndexOutOfBoundsException, since the ellipsized layout only resolves up to visibleEnd.
    drawSpannedDecoration(
        0,
        TAIL_TEXT.length,
        canvas,
        layout,
        Color.BLACK,
        TextDecorationStyle.SOLID,
    ) { _, lineBaseline, thickness ->
      lineBaseline + thickness + 1f
    }

    verify(canvas).drawLine(eq(x1), eq(baseline + 1f), eq(x2), eq(baseline + 1f), any())
  }

  @Test
  fun drawSpannedDecorationSkipsSpanEntirelyPastTailEllipsis() {
    val layout = buildTailEllipsizedLayout()
    val visibleEnd = layout.getLineStart(0) + layout.getEllipsisStart(0)
    val baseline = layout.getLineBaseline(0).toFloat()
    val x = layout.getPrimaryHorizontal(visibleEnd)
    val canvas = mock<Canvas>()

    // The whole span (e.g. a nested Text) starts after the ellipsis, fully hidden: it must
    // collapse to a zero-length line at the visible boundary, not draw anything past it.
    drawSpannedDecoration(
        visibleEnd,
        TAIL_TEXT.length,
        canvas,
        layout,
        Color.BLACK,
        TextDecorationStyle.SOLID,
    ) { _, lineBaseline, thickness ->
      lineBaseline + thickness + 1f
    }

    verify(canvas).drawLine(eq(x), eq(baseline + 1f), eq(x), eq(baseline + 1f), any())
  }

  /**
   * A single line, tail-ellipsized right after "Hello" because the paragraph break in
   * [TAIL_TEXT] hides everything after it once `maxLines` is reached.
   */
  private fun buildTailEllipsizedLayout(): StaticLayout {
    val paint = TextPaint().apply { textSize = 32f }
    val layout =
        StaticLayout.Builder.obtain(TAIL_TEXT, 0, TAIL_TEXT.length, paint, 400)
            .setMaxLines(1)
            .setEllipsize(TextUtils.TruncateAt.END)
            .build()
    assertThat(layout.lineCount).isEqualTo(1)
    assertThat(layout.getEllipsisCount(0)).isGreaterThan(0)
    return layout
  }

  private companion object {
    const val TAIL_TEXT = "Hello\ndecorated world"
  }
```

- [x] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
cd ~/GitHub/react-native/.claude/worktrees/daewoon+android-prebuilt
./gradlew :packages:react-native:ReactAndroid:testDebugUnitTest \
  --tests "com.facebook.react.views.text.TextDecorationStyleTest"
```

기대: 새 테스트 2개가 `IndexOutOfBoundsException: offset(...) should be less than line limit(...)`로 실패. 기존 `fromString*` 테스트 6개는 통과.

이 에러가 정확히 재현되지 않으면 멈춘다 — 재현 없는 수정은 검증되지 않는다.

- [x] **Step 3: 최소 구현을 넣는다**

`TextDecorationStyle.kt`에서 `drawDecorationLine` 함수가 끝나는 `}` 다음, `drawSpannedDecoration`의 KDoc 앞에 아래를 삽입한다:

```kotlin
/**
 * The last offset [layout] can resolve a horizontal position for. Truncation (via `numberOfLines`)
 * can leave the last line shorter than [Layout.getLineEnd] reports, since [layout] keeps the full
 * untruncated text and only clips how much of it is laid out. When the last line ends in a tail
 * ellipsis, anything from the ellipsis onward is unresolvable too; a leading/middle ellipsis
 * doesn't shorten what's resolvable on that line, so it's left to [Layout.getLineEnd].
 */
private fun visibleTextEnd(layout: Layout): Int {
  val lastLine = layout.lineCount - 1
  val lineStart = layout.getLineStart(lastLine)
  val lineEnd = layout.getLineEnd(lastLine)
  val ellipsisStart = layout.getEllipsisStart(lastLine)
  val ellipsisCount = layout.getEllipsisCount(lastLine)
  return if (ellipsisCount > 0 && ellipsisStart + ellipsisCount == lineEnd - lineStart) {
    lineStart + ellipsisStart
  } else {
    lineEnd
  }
}
```

그리고 `drawSpannedDecoration` 안의 아래 블록을

```kotlin
  val startLine = layout.getLineForOffset(start)
  val endLine = layout.getLineForOffset(end)
  for (line in startLine..endLine) {
    val baseline = layout.getLineBaseline(line).toFloat()
    val rawX1 =
        if (line == startLine) layout.getPrimaryHorizontal(start) else layout.getLineLeft(line)
    val rawX2 = if (line == endLine) layout.getPrimaryHorizontal(end) else layout.getLineRight(line)
```

이렇게 바꾼다:

```kotlin
  val visibleEnd = visibleTextEnd(layout)
  val clampedStart = min(start, visibleEnd)
  val clampedEnd = min(end, visibleEnd)

  val startLine = layout.getLineForOffset(clampedStart)
  val endLine = layout.getLineForOffset(clampedEnd)
  for (line in startLine..endLine) {
    val baseline = layout.getLineBaseline(line).toFloat()
    val rawX1 =
        if (line == startLine) layout.getPrimaryHorizontal(clampedStart)
        else layout.getLineLeft(line)
    val rawX2 =
        if (line == endLine) layout.getPrimaryHorizontal(clampedEnd) else layout.getLineRight(line)
```

`min`은 이미 `kotlin.math.min`으로 import 되어 있다. 새 import 없다.

- [x] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
./gradlew :packages:react-native:ReactAndroid:testDebugUnitTest \
  --tests "com.facebook.react.views.text.TextDecorationStyleTest"
```

기대: 8개 전부 PASS.

- [x] **Step 5: tarball diff 게이트에 경로를 등록한다**

`.github/scatterlab/allowed-tarball-diff.txt` 끝에 추가한다:

```
# Android text decoration crash: drawSpannedDecoration() passed offsets from the full
# Spanned into a numberOfLines-truncated Layout, so getPrimaryHorizontal() threw
# IndexOutOfBoundsException while drawing an underline/strikethrough that the truncation
# had hidden. Upstream https://github.com/react/react-native/pull/58366 (open).
# Reaches the app only through this fork's Android prebuilt release - see android-prebuilt.md.
ReactAndroid/src/main/java/com/facebook/react/views/text/TextDecorationStyle.kt
```

테스트 파일은 `package.json`의 `files`가 `!ReactAndroid/src/test`로 제외하므로 tarball에 없다. 추가하지 않는다.

- [x] **Step 6: 게이트가 통과하는지 확인한다**

```bash
cd packages/react-native && npm pack --silent && cd -
.github/scatterlab/verify-tarball.sh packages/react-native/*.tgz 0.87.1
```

기대: 통과. `TextDecorationStyle.kt`가 allowlist 밖이라고 실패하면 Step 5의 경로 문자열이 tarball 상대 경로와 다른 것이다 — `tar tzf`로 실제 경로를 확인하고 맞춘다.

- [x] **Step 7: 커밋**

```bash
rm -f packages/react-native/*.tgz
git add packages/react-native/ReactAndroid/src/main/java/com/facebook/react/views/text/TextDecorationStyle.kt \
        packages/react-native/ReactAndroid/src/test/java/com/facebook/react/views/text/TextDecorationStyleTest.kt \
        .github/scatterlab/allowed-tarball-diff.txt
git commit -m "$(cat <<'MSG'
fix(android): 잘린 layout 밖으로 나간 text decoration offset을 clamp

`numberOfLines`로 잘린 `Layout`에 전체 `Spanned` 기준 offset을 넘겨
`Layout.getPrimaryHorizontal()`이 `IndexOutOfBoundsException`을 던졌다.
중첩 `Text`의 `textDecorationLine`이 잘려 안 보이는 위치에 있으면 그리기
단계에서 앱이 죽는다.

상류 PR https://github.com/react/react-native/pull/58366 체리픽.
이슈 https://github.com/react/react-native/issues/58356

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 2: 소비자 Gradle settings 스크립트

**Files:**
- Create: `packages/react-native/scripts/android/scatterlab-prebuilt-maven.gradle`
- Modify: `packages/react-native/package.json` (`files` 배열)
- Modify: `.github/scatterlab/allowed-tarball-diff.txt`
- Test: `.github/scatterlab/__tests__/android-prebuilt-consumer-test.sh`

**Interfaces:**
- Consumes: 없음
- Produces:
  - 릴리스 에셋 이름 `react-native-android-maven-<version>.tar.gz` 와 `react-native-android-maven-<version>.tar.gz.sha256` — Task 3이 정확히 이 이름으로 올린다.
  - 릴리스 태그 `prebuilt-android-<version>` — Task 3이 이 태그를 만든다.
  - tar 아카이브의 루트는 maven 저장소 루트 자체다 (`com/facebook/react/...`가 최상위). Task 3이 `tar -C /tmp/maven-local -czf ... .`로 만든다.
  - 캐시 경로 `<gradleUserHome>/scatterlab-react-native/<version>/maven`.
  - 소비자가 apply 할 경로: `<node_modules>/react-native/scripts/android/scatterlab-prebuilt-maven.gradle` — Task 5가 이 경로를 쓴다.

- [x] **Step 1: 실패하는 스모크 테스트를 쓴다**

`.github/scatterlab/__tests__/android-prebuilt-consumer-test.sh` 를 만든다:

```bash
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
```

- [x] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
cd ~/GitHub/react-native/.claude/worktrees/daewoon+android-prebuilt
chmod +x .github/scatterlab/__tests__/android-prebuilt-consumer-test.sh
.github/scatterlab/__tests__/android-prebuilt-consumer-test.sh
```

기대: 스크립트 파일이 없어 `cp`에서 실패한다. 3개 케이스 전부 도달 못 함.

- [x] **Step 3: 스크립트를 구현한다**

`packages/react-native/scripts/android/scatterlab-prebuilt-maven.gradle` 를 만든다:

```groovy
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// Points the consumer's build at this fork's Android artifacts.
//
// RNGP force-resolves com.facebook.react:react-android:<VERSION_NAME> from Maven Central,
// and VERSION_NAME has to stay on the upstream base, so the fork's ReactAndroid sources are
// never compiled by a consumer. This fetches the AAR this fork built and hands its path to
// RNGP via react.internal.mavenLocalRepo, which also makes RNGP exclude the whole
// com.facebook.react group from Maven Central. See .github/scatterlab/android-prebuilt.md.
//
// Apply from the consumer's settings.gradle(.kts):
//   apply(from = "<...>/node_modules/react-native/scripts/android/scatterlab-prebuilt-maven.gradle")

import java.security.MessageDigest

def packageJson = new File(buildscript.sourceFile.parentFile, '../../package.json').canonicalFile
def version = new groovy.json.JsonSlurper().parse(packageJson).version

// Upstream react-native: nothing of ours to fetch. Stay out of the way entirely.
if (!(version ==~ /^\d+\.\d+\.\d+-scatterlab\.\d+$/)) {
  return
}

def tag = "prebuilt-android-${version}"
def asset = "react-native-android-maven-${version}.tar.gz"
def assetUrl = "https://github.com/scatterlab/react-native/releases/download/${tag}/${asset}"

// Scoped by fork version on purpose. VERSION_NAME is pinned to the base, so every fork
// version publishes the SAME coordinate - sharing one repo root would let Gradle keep
// serving the previous version's AAR with no error at all.
def repoDir = new File(gradle.gradleUserHomeDir, "scatterlab-react-native/${version}/maven")

def fail = { String why ->
  throw new GradleException(
      "[scatterlab] ${why}\n" +
      "  This version of @scatterlab/react-native carries Android native changes that only\n" +
      "  exist in this fork's prebuilt artifacts. Run the '[scatterlab] Build Android prebuilt'\n" +
      "  workflow for ${version}, then build again.\n" +
      "  Expected: ${assetUrl}")
}

def download = { String url, File target ->
  def connection = new URL(url).openConnection()
  connection.instanceFollowRedirects = true
  connection.connectTimeout = 30_000
  connection.readTimeout = 300_000
  if (connection.responseCode != 200) {
    fail("${url} returned HTTP ${connection.responseCode}.")
  }
  target.withOutputStream { out -> connection.inputStream.withStream { input -> out << input } }
}

def sha256 = { File file ->
  def digest = MessageDigest.getInstance('SHA-256')
  file.eachByte(1024 * 1024) { buffer, length -> digest.update(buffer, 0, length) }
  digest.digest().encodeHex().toString()
}

if (!repoDir.isDirectory()) {
  // Staged next to the final location, not in /tmp: the move below has to be a rename on
  // the same filesystem, or a half-copied tree can be left behind as a cache hit.
  repoDir.parentFile.mkdirs()
  def staging = java.nio.file.Files
      .createTempDirectory(repoDir.parentFile.toPath(), 'staging')
      .toFile()
  try {
    def tarball = new File(staging, asset)
    download(assetUrl, tarball)

    def expectedFile = new File(staging, "${asset}.sha256")
    download("${assetUrl}.sha256", expectedFile)
    def expected = expectedFile.text.trim().split(/\s+/)[0]
    def actual = sha256(tarball)
    if (expected != actual) {
      fail("${asset} sha256 mismatch: expected ${expected}, got ${actual}.")
    }

    def extracted = new File(staging, 'maven')
    extracted.mkdirs()
    def proc = ['tar', '-xzf', tarball.absolutePath, '-C', extracted.absolutePath].execute()
    def stderr = new StringBuffer()
    proc.waitForProcessOutput(new StringBuffer(), stderr)
    if (proc.exitValue() != 0) {
      fail("extracting ${asset} failed: ${stderr}")
    }

    // Move only once the tree is complete: a half-extracted directory must never be left
    // behind as a cache hit for the next build.
    if (!extracted.renameTo(repoDir) && !repoDir.isDirectory()) {
      fail("could not move the extracted repository into ${repoDir}.")
    }
  } finally {
    staging.deleteDir()
  }
}

gradle.beforeProject { project ->
  project.extensions.extraProperties.set('react.internal.mavenLocalRepo', repoDir.absolutePath)
}
```

- [x] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
.github/scatterlab/__tests__/android-prebuilt-consumer-test.sh
```

기대: `ok - upstream version leaves the property unset`, `ok - missing release aborts`, `ok - warm cache is used`, `all cases passed`.

케이스 B가 HTTP 404 대신 다른 에러로 죽으면 메시지에 `prebuilt-android-...`가 들어가는지만 본다 — 이 테스트가 확인하는 것은 "조용히 통과하지 않는다"이다.

- [x] **Step 5: 스크립트를 npm 패키지에 포함시킨다**

`packages/react-native/package.json`의 `files` 배열에서 `scripts/`로 시작하는 항목들 사이, `scripts/codegen` 다음 줄에 추가한다:

```json
    "scripts/android",
```

`files`는 `scripts` 전체가 아니라 개별 경로를 나열한다 — 추가하지 않으면 스크립트가 tarball에 들어가지 않고, 소비자의 `apply from:`이 파일 없음으로 실패한다.

- [x] **Step 6: tarball 게이트에 경로를 등록하고 포함을 확인한다**

`.github/scatterlab/allowed-tarball-diff.txt` 끝에 추가한다:

```
# Points the consumer's Gradle build at this fork's Android artifacts. Added file, so the
# gate sees it as a difference from upstream. See android-prebuilt.md.
scripts/android/scatterlab-prebuilt-maven.gradle
```

```bash
cd packages/react-native && npm pack --silent && cd -
tar tzf packages/react-native/*.tgz | grep 'scripts/android/'
.github/scatterlab/verify-tarball.sh packages/react-native/*.tgz 0.87.1
```

기대: `package/scripts/android/scatterlab-prebuilt-maven.gradle` 한 줄이 나오고, 게이트 통과.

- [x] **Step 7: 커밋**

```bash
rm -f packages/react-native/*.tgz
git add packages/react-native/scripts/android/scatterlab-prebuilt-maven.gradle \
        packages/react-native/package.json \
        .github/scatterlab/__tests__/android-prebuilt-consumer-test.sh \
        .github/scatterlab/allowed-tarball-diff.txt
git commit -m "$(cat <<'MSG'
feat(scatterlab): 소비자 빌드가 fork의 Android 아티팩트를 쓰게 하는 settings 스크립트

RNGP 가 `com.facebook.react:react-android:<VERSION_NAME>` 을 Maven Central 에서
force resolve 하므로 fork 의 `ReactAndroid/**` 는 소비자 빌드에서 컴파일되지
않는다. 이 스크립트가 릴리스 tarball 을 받아 캐시하고 그 경로를
`react.internal.mavenLocalRepo` 로 넘긴다 — RNGP 가 그 저장소를 추가하고
Maven Central 에서 `com.facebook.react` 그룹을 제외한다.

캐시는 fork 버전으로 스코프한다. `VERSION_NAME` 이 base 로 고정돼 모든 fork
버전의 좌표가 같으므로, 한 루트를 공유하면 옛 AAR 이 에러 없이 재사용된다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 3: 빌드 · 릴리스 워크플로

**Files:**
- Create: `.github/workflows/scatterlab-prebuild-android.yml`
- Modify: `CLAUDE.md` (배포 절차)

**Interfaces:**
- Consumes: Task 1의 `visibleTextEnd` 심볼 (`verify_symbol` 입력의 첫 사용값), Task 2가 정한 태그·에셋 이름·tar 루트 규약
- Produces: 릴리스 `prebuilt-android-<version>` 에 `react-native-android-maven-<version>.tar.gz` + `.sha256`

- [x] **Step 1: 워크플로를 쓴다**

`.github/workflows/scatterlab-prebuild-android.yml`:

```yaml
name: '[scatterlab] Build Android prebuilt'

# Builds com.facebook.react:* from THIS fork's sources and attaches the resulting Maven
# repository to a `prebuilt-android-<version>` release.
#
# Why this exists: RNGP force-resolves com.facebook.react:react-android:<VERSION_NAME> from
# Maven Central and VERSION_NAME must stay on the upstream base, so a consumer never compiles
# the fork's ReactAndroid sources. Consumed by
# packages/react-native/scripts/android/scatterlab-prebuilt-maven.gradle.
#
# Runners: the org has an IP allow list and GitHub-hosted runners are not on it, so every
# authenticated api.github.com write from a hosted runner fails with HTTP 403.

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Fork version the artifacts are for, e.g. 0.87.1-scatterlab.3'
        required: true
        type: string
      verify_symbol:
        description: 'Identifier this version introduces, asserted to exist in the built AAR (e.g. visibleTextEnd). Leave empty for releases that add no new symbol.'
        required: false
        default: ''
        type: string
      dry_run:
        description: 'Build and verify only, do not create a release'
        required: true
        default: true
        type: boolean

permissions:
  contents: read

jobs:
  prepare:
    runs-on: arc-messenger-dev
    permissions:
      contents: write
    outputs:
      base: ${{ steps.v.outputs.base }}
      tag: ${{ steps.v.outputs.tag }}
      asset: ${{ steps.v.outputs.asset }}
    steps:
      - uses: actions/checkout@v4

      - name: Resolve and validate versions
        id: v
        env:
          VERSION: ${{ inputs.version }}
        run: |
          set -euo pipefail
          if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-scatterlab\.[0-9]+$ ]]; then
            echo "::error::version must look like 0.87.1-scatterlab.3"
            exit 1
          fi
          BASE="${VERSION%-scatterlab.*}"
          echo "base=$BASE" >> "$GITHUB_OUTPUT"
          echo "tag=prebuilt-android-$VERSION" >> "$GITHUB_OUTPUT"
          echo "asset=react-native-android-maven-$VERSION.tar.gz" >> "$GITHUB_OUTPUT"

          # The AAR coordinate carries the base, not the fork version, so this is the only
          # place the two are checked against each other.
          GRADLE_VERSION=$(sed -n 's/^VERSION_NAME=//p' packages/react-native/ReactAndroid/gradle.properties)
          if [ "$GRADLE_VERSION" != "$BASE" ]; then
            echo "::error::ReactAndroid/gradle.properties VERSION_NAME is '$GRADLE_VERSION', expected the upstream base '$BASE'."
            exit 1
          fi

          COMMITTED=$(node -p "require('./packages/react-native/package.json').version")
          if [ "$COMMITTED" != "$VERSION" ]; then
            echo "::warning::packages/react-native/package.json is at $COMMITTED but these artifacts are for $VERSION. They must match the version consumers install, or the URL the consumer script builds will not resolve."
          fi

  build:
    needs: prepare
    runs-on: arc-messenger-dev
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Setup git safe folders
        run: git config --global --add safe.directory '*'

      - uses: ./.github/actions/setup-node
      - uses: ./.github/actions/yarn-install

      # Without a warm ccache every run is a full C++ rebuild of ReactCommon.
      - name: Restore the Android ccache
        uses: actions/cache/restore@v4
        with:
          path: ~/.cache/ccache
          key: scatterlab-ccache-android-${{ hashFiles('packages/react-native/ReactAndroid/**/*.cpp', 'packages/react-native/ReactAndroid/**/*.h', 'packages/react-native/ReactCommon/**/*.cpp', 'packages/react-native/ReactAndroid/**/CMakeLists.txt', 'packages/react-native/ReactCommon/**/CMakeLists.txt') }}
          restore-keys: scatterlab-ccache-android-

      # The upstream .github/actions/build-android composite is deliberately NOT reused: it
      # runs scripts/releases/set-rn-artifacts-version.js, which rewrites VERSION_NAME and
      # breaks the coordinate the consumer resolves.
      - name: Build and publish the Android artifacts to /tmp/maven-local
        run: |
          set -euo pipefail
          rm -rf /tmp/maven-local
          # useHermesStable keeps Hermes off this build: com.facebook.hermes is a different
          # publishing group, so it still resolves from Maven Central on the consumer side.
          # isSnapshot stays off - it would append -SNAPSHOT to the coordinate.
          env ORG_GRADLE_PROJECT_react.internal.useHermesStable=true \
            ./gradlew publishAllToMavenTempLocal -PenableWarningsAsErrors=true

      - name: Assert the Maven tree is complete
        env:
          BASE: ${{ needs.prepare.outputs.base }}
        run: |
          set -euo pipefail
          DIR="/tmp/maven-local/com/facebook/react/react-android/$BASE"
          for f in "react-android-$BASE-debug.aar" "react-android-$BASE-release.aar" \
                   "react-android-$BASE.module" "react-android-$BASE.pom"; do
            [ -f "$DIR/$f" ] || { echo "::error::$DIR/$f is missing"; exit 1; }
          done

      - name: Assert the patch is in the built AAR
        if: ${{ inputs.verify_symbol != '' }}
        env:
          BASE: ${{ needs.prepare.outputs.base }}
          SYMBOL: ${{ inputs.verify_symbol }}
        run: |
          set -euo pipefail
          # Every fork version publishes the same coordinate, so "the artifact exists" proves
          # nothing about which sources went into it. This is the only check that does.
          WORK=$(mktemp -d)
          unzip -q "/tmp/maven-local/com/facebook/react/react-android/$BASE/react-android-$BASE-release.aar" \
            classes.jar -d "$WORK"
          mkdir -p "$WORK/classes" && unzip -q "$WORK/classes.jar" -d "$WORK/classes"
          COUNT=$(find "$WORK/classes" -name '*.class' -exec javap -p {} + 2>/dev/null | grep -c "$SYMBOL" || true)
          echo "'$SYMBOL' occurrences in the release AAR: $COUNT"
          [ "$COUNT" -gt 0 ] || { echo "::error::'$SYMBOL' is not in the built AAR - the sources that went in are not the ones you think"; exit 1; }
          rm -rf "$WORK"

      - name: Pack the Maven repository
        id: pack
        env:
          ASSET: ${{ needs.prepare.outputs.asset }}
        run: |
          set -euo pipefail
          OUT="$RUNNER_TEMP/assets"
          mkdir -p "$OUT"
          # The archive root IS the repository root, so the consumer extracts straight into
          # its cache directory with no strip-components guesswork.
          tar -C /tmp/maven-local -czf "$OUT/$ASSET" .
          ( cd "$OUT" && sha256sum "$ASSET" | awk '{print $1}' > "$ASSET.sha256" )
          ls -lh "$OUT"
          echo "dir=$OUT" >> "$GITHUB_OUTPUT"

      - name: Upload the assets as artifacts
        uses: actions/upload-artifact@v4
        with:
          name: prebuilt-android-${{ inputs.version }}
          path: ${{ steps.pack.outputs.dir }}
          if-no-files-found: error

      - name: Create the release and upload the assets
        if: ${{ !inputs.dry_run }}
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: ${{ needs.prepare.outputs.tag }}
          VERSION: ${{ inputs.version }}
          DIR: ${{ steps.pack.outputs.dir }}
        run: |
          set -euo pipefail
          if ! gh release view "$TAG" >/dev/null 2>&1; then
            gh release create "$TAG" \
              --target "$GITHUB_SHA" \
              --title "Android prebuilt for $VERSION" \
              --notes "com.facebook.react Maven artifacts built from this fork for @scatterlab/react-native@$VERSION. Consumed by scripts/android/scatterlab-prebuilt-maven.gradle." \
              --prerelease
          fi
          # No --clobber: a consumer with a warm cache cannot detect a replaced asset and
          # would keep the old AAR forever. Publish a new -scatterlab.N instead.
          gh release upload "$TAG" "$DIR"/*

      - name: Save the Android ccache
        if: always()
        uses: actions/cache/save@v4
        with:
          path: ~/.cache/ccache
          key: scatterlab-ccache-android-${{ hashFiles('packages/react-native/ReactAndroid/**/*.cpp', 'packages/react-native/ReactAndroid/**/*.h', 'packages/react-native/ReactCommon/**/*.cpp', 'packages/react-native/ReactAndroid/**/CMakeLists.txt', 'packages/react-native/ReactCommon/**/CMakeLists.txt') }}

      # A shared runner: the build products are several GB.
      - name: Clean the build products
        if: always()
        run: rm -rf /tmp/maven-local

  verify:
    needs: [prepare, build]
    if: ${{ !inputs.dry_run }}
    runs-on: arc-messenger-dev
    steps:
      - name: Assert the release is consumable
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: ${{ needs.prepare.outputs.tag }}
          ASSET: ${{ needs.prepare.outputs.asset }}
          BASE: ${{ needs.prepare.outputs.base }}
          REPO: ${{ github.repository }}
        run: |
          set -euo pipefail
          # GitHub rewrites asset names containing unexpected characters, so compare exactly
          # rather than trusting the upload.
          gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[].name' | sort > /tmp/actual
          printf '%s\n%s\n' "$ASSET" "$ASSET.sha256" | sort > /tmp/expected
          diff /tmp/expected /tmp/actual

          URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
          curl -sL -o /tmp/asset.tar.gz "$URL"
          EXPECTED=$(curl -sL "$URL.sha256" | tr -d '[:space:]')
          ACTUAL=$(sha256sum /tmp/asset.tar.gz | awk '{print $1}')
          [ "$EXPECTED" = "$ACTUAL" ] || { echo "::error::sha256 mismatch: $EXPECTED vs $ACTUAL"; exit 1; }

          for f in "react-android-$BASE-debug.aar" "react-android-$BASE-release.aar" \
                   "react-android-$BASE.module" "react-android-$BASE.pom"; do
            tar tzf /tmp/asset.tar.gz "./com/facebook/react/react-android/$BASE/$f" >/dev/null \
              || { echo "::error::$f is missing from the archive"; exit 1; }
          done
          echo "release $TAG is consumable"
```

- [x] **Step 2: 워크플로 문법을 검사한다**

```bash
cd ~/GitHub/react-native/.claude/worktrees/daewoon+android-prebuilt
python3 -c "import sys,yaml;yaml.safe_load(open('.github/workflows/scatterlab-prebuild-android.yml'));print('yaml ok')"
command -v actionlint >/dev/null && actionlint .github/workflows/scatterlab-prebuild-android.yml || echo "actionlint 없음 — brew install actionlint 후 재실행 권장"
```

기대: `yaml ok`, actionlint 있으면 무경고.

`runner` 컨텍스트를 잡 레벨 `env:`에 쓰면 워크플로 파싱이 HTTP 422로 실패하고 증상이 "워크플로가 없다"처럼 보인다. 이 파일은 `RUNNER_TEMP`를 스텝 안에서만 쓴다 — 옮기지 않는다.

- [x] **Step 3: `CLAUDE.md`의 배포 절차에 Android를 넣는다**

`## iOS prebuilt` 섹션 바로 앞에 새 섹션을 넣는다:

```markdown
## Android prebuilt

Android는 `com.facebook.react:react-android:<VERSION_NAME>`을 Maven Central에서 force resolve 하므로 **fork의 `ReactAndroid/**` 수정은 npm으로 안 간다**. 패치된 AAR을 따로 낸다.

```bash
gh workflow run scatterlab-prebuild-android.yml --repo scatterlab/react-native --ref scatterlab/0.87.1 \
  -f version=0.87.1-scatterlab.N -f verify_symbol=<이번에 추가한 식별자> -f dry_run=false
```

**순서 제약**: prebuilt 릴리스가 npm보다 먼저 있어야 한다. 없으면 소비자 Gradle configure가 abort한다. 설계·함정은 [`.github/scatterlab/android-prebuilt.md`](.github/scatterlab/android-prebuilt.md).

`verify_symbol`이 load-bearing이다. 모든 fork 버전의 AAR 좌표가 동일해서, 이 검사 없이는 "아티팩트가 있다"가 "패치가 들어 있다"를 전혀 보증하지 않는다.
```

같은 편집에서 `## 배포` 섹션과 `## iOS prebuilt` 섹션의 `0.86.2` 문자열을 현재 라인인 `0.87.1`로 고친다 (작업 브랜치 · 예시 버전). 이 파일이 실행자에게 잘못된 브랜치를 지시하고 있다.

- [x] **Step 4: 커밋**

```bash
git add .github/workflows/scatterlab-prebuild-android.yml CLAUDE.md
git commit -m "$(cat <<'MSG'
ci(scatterlab): Android prebuilt 빌드·릴리스 워크플로

`publishAllToMavenTempLocal` 산출물을 통째로 tar 해서
`prebuilt-android-<version>` 릴리스에 올린다. 상류
`.github/actions/build-android` 는 `set-rn-artifacts-version.js` 로
`VERSION_NAME` 을 재작성하므로 재사용하지 않고 필요한 스텝만 직접 쓴다.

`verify_symbol` 입력으로 빌드된 AAR 안에 이번 수정의 심볼이 있는지 센다.
모든 fork 버전의 AAR 좌표가 같아서, 이 검사 없이는 아티팩트 존재가 패치
포함을 전혀 보증하지 않는다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 4: fork PR 올리기

**Files:** 없음 (git 조작만)

**Interfaces:**
- Consumes: Task 1~3의 커밋
- Produces: 머지된 `scatterlab/0.87.1` — Task 6이 이 브랜치에서 워크플로를 돌린다

- [ ] **Step 1: 전체 테스트를 다시 돌린다**

```bash
cd ~/GitHub/react-native/.claude/worktrees/daewoon+android-prebuilt
./gradlew :packages:react-native:ReactAndroid:testDebugUnitTest \
  --tests "com.facebook.react.views.text.TextDecorationStyleTest"
.github/scatterlab/__tests__/android-prebuilt-consumer-test.sh
cd packages/react-native && npm pack --silent && cd - && \
  .github/scatterlab/verify-tarball.sh packages/react-native/*.tgz 0.87.1 && rm -f packages/react-native/*.tgz
```

기대: 셋 다 통과. 하나라도 실패하면 PR을 열지 않는다.

- [ ] **Step 2: push 하고 PR을 연다**

```bash
git push origin daewoon/android-prebuilt
gh pr create --repo scatterlab/react-native \
  --base scatterlab/0.87.1 --head daewoon/android-prebuilt \
  --title "feat(scatterlab): Android prebuilt 배포 파이프라인 + text decoration 크래시 수정" \
  --body-file -
```

본문은 `.github/pull_request_template.md`가 있으면 먼저 읽고 그 섹션 제목·인용문·체크리스트를 원본 그대로 유지한 채 내용만 채운다. 없으면 자유 형식으로 쓰되 아래를 담는다:

- 왜 필요한가: RNGP의 force resolve 때문에 fork의 Android 수정이 소비자에게 안 간다 (`DependencyUtils.kt:132`)
- 무엇이 들어왔나: 워크플로 · 소비자 스크립트 · 첫 화물(#58366 체리픽)
- 함정: 좌표가 fork 버전 간 동일하므로 캐시를 버전으로 스코프하고 `verify_symbol`로 실물 확인
- 출고 순서: prebuilt 릴리스 → npm publish → 소비자 핀
- `git diff scatterlab/0.87.1...HEAD` 기준으로 쓴다

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

---

### Task 5: zeta-frontend 배선

**Files:**
- Modify: `packages/app/android/settings.gradle.kts`

**Interfaces:**
- Consumes: Task 2가 정한 apply 경로
- Produces: 없음

`~/GitHub/zeta-frontend` 의 **새 워크트리**에서 한다:

```bash
cd ~/GitHub/zeta-frontend
git worktree add .claude/worktrees/daewoon+rn-android-prebuilt -b daewoon/rn-android-prebuilt origin/main
```

이후 모든 편집은 `~/GitHub/zeta-frontend/.claude/worktrees/daewoon+rn-android-prebuilt/` 절대경로로 한다.

- [ ] **Step 1: apply 한 줄을 넣는다**

`packages/app/android/settings.gradle.kts` 의 `plugins { id("com.facebook.react.settings") }` 블록 **다음**, `extensions.configure<ReactSettingsExtension>` 앞에 넣는다:

```kotlin
// fork 가 빌드한 Android 아티팩트를 받아 `react.internal.mavenLocalRepo` 로 넘긴다.
// 없으면 RNGP 가 Maven Central 의 업스트림 AAR 을 쓰고 fork 의 Android 수정이 조용히 빠진다.
apply(from = "../../../node_modules/react-native/scripts/android/scatterlab-prebuilt-maven.gradle")
```

**`pluginManagement` 앞에 두지 않는다.** Gradle 은 `pluginManagement` 가 settings 스크립트의 첫 블록일 것을 요구해서, 앞에 어떤 문장이든 오면 평가 자체가 실패한다.

순서는 문제되지 않는다. 스크립트가 거는 `gradle.beforeProject` 는 settings 평가가 **끝난 뒤** 프로젝트 설정 단계에서 실행되고, RNGP 의 `configureRepositories` 는 그보다 더 뒤인 플러그인 apply 시점에 돈다.

- [ ] **Step 2: 프로퍼티가 실제로 RNGP에 도달했는지 확인한다**

이 단계는 fork PR이 머지되고 `-scatterlab.N`이 publish 되어 핀이 갱신된 뒤에만 통과한다 (Task 6). 그 전에는 abort가 정상이다.

```bash
cd ~/GitHub/zeta-frontend/.claude/worktrees/daewoon+rn-android-prebuilt/packages/app/android
./gradlew :app:dependencies --configuration prodReleaseRuntimeClasspath 2>&1 | grep -i 'react-android'
./gradlew :app:dependencies --configuration prodReleaseRuntimeClasspath --info 2>&1 \
  | grep -i 'scatterlab-react-native' | head
```

기대: 해석된 `com.facebook.react:react-android` 의 출처 경로에 `scatterlab-react-native/<version>/maven` 이 나온다. Maven Central URL 이 나오면 프로퍼티가 도달하지 않은 것이다 — `apply` 위치가 `pluginManagement` 뒤로 갔거나 `beforeProject` 타이밍 문제다.

- [ ] **Step 3: 커밋하고 PR을 연다**

```bash
git add packages/app/android/settings.gradle.kts
git commit -m "$(cat <<'MSG'
build(app): Android 빌드가 fork 의 prebuilt AAR 을 쓰게 한다

RNGP 가 `com.facebook.react:react-android:<VERSION_NAME>` 을 Maven Central
에서 force resolve 하므로, 이 줄이 없으면 `@scatterlab/react-native` 의
Android 네이티브 수정이 빌드에 하나도 안 들어간다.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
git push origin daewoon/rn-android-prebuilt
```

PR은 `~/GitHub/zeta-frontend/.github/pull_request_template.md` 를 먼저 Read 해서 섹션 제목(이모지 포함)·인용문·체크리스트를 원본 그대로 유지한 채 내용만 채운다.

---

### Task 6: 출고

코드가 아니라 절차다. Task 4의 PR이 머지된 뒤에 한다.

브랜치 base가 `0.87.1-scatterlab.3`이므로 이 변경이 나갈 다음 fork 버전은 **`0.87.1-scatterlab.4`**다. 아래 명령의 버전은 전부 그 값이다.

- [ ] **Step 1: dry-run 으로 빌드가 도는지 본다**

```bash
gh workflow run scatterlab-prebuild-android.yml --repo scatterlab/react-native \
  --ref scatterlab/0.87.1 \
  -f version=0.87.1-scatterlab.4 -f verify_symbol=visibleTextEnd -f dry_run=true
gh run watch --repo scatterlab/react-native
```

기대: `Assert the patch is in the built AAR` 스텝이 `'visibleTextEnd' occurrences in the release AAR: <1 이상>` 을 찍고 통과. 0이면 빌드에 들어간 소스가 우리가 생각하는 그것이 아니다 — 멈추고 원인을 찾는다.

- [ ] **Step 2: 버전을 올린다**

`packages/react-native/package.json` 의 `version` 만 `0.87.1-scatterlab.4` 으로 바꾼다. `ReactAndroid/gradle.properties` 의 `VERSION_NAME`, sibling 핀, `ReactNativeVersion.*` 은 건드리지 않는다. 커밋 후 `scatterlab/0.87.1` 에 머지한다.

- [ ] **Step 3: prebuilt 릴리스 두 개를 만든다 (npm 보다 먼저)**

```bash
gh workflow run scatterlab-prebuild-ios.yml --repo scatterlab/react-native \
  --ref scatterlab/0.87.1 -f version=0.87.1-scatterlab.4
gh workflow run scatterlab-prebuild-android.yml --repo scatterlab/react-native \
  --ref scatterlab/0.87.1 \
  -f version=0.87.1-scatterlab.4 -f verify_symbol=visibleTextEnd -f dry_run=false
```

두 `verify` 잡이 모두 통과할 때까지 기다린다. 한쪽만 끝난 부분 릴리스로 다음 단계에 가지 않는다.

- [ ] **Step 4: npm publish**

```bash
gh workflow run scatterlab-publish.yml --repo scatterlab/react-native --ref scatterlab/0.87.1 \
  -f version=0.87.1-scatterlab.4 -f dist_tag=latest -f dry_run=false
```

publish 직후 **약 1분간 install 이 `ETARGET` 으로 실패한다** (packument 와 dist-tags 캐시가 별개). install 이 되는 것을 확인한 뒤 다음으로 간다.

- [ ] **Step 5: zeta-frontend 핀을 전부 갱신한다**

Task 5의 워크트리에서:

```bash
cd ~/GitHub/zeta-frontend/.claude/worktrees/daewoon+rn-android-prebuilt
grep -rn '0.87.1-scatterlab.2' packages/*/package.json
```

`packages/{app,core,service,ui}/package.json` 의 alias 를 모두 `0.87.1-scatterlab.4` 으로 바꾼다. `packages/core` 는 **peerDependencies 에 alias 없는 정확 버전**으로도 들고 있어 alias 패턴 grep 에서 빠진다 — 함께 고친다. 그다음:

```bash
yarn install
grep -c '0.87.1-scatterlab.2' yarn.lock
```

기대: `0`. 0이 아니면 핀을 빠뜨린 것이고, lockfile 에 두 버전이 남아 패키지가 두 벌 해석된다.

- [ ] **Step 6: 실기기로 증상이 사라진 것을 확인한다**

Android release APK 를 빌드해 실기기에 설치하고, **소개글이 4줄 이상이고 4줄째 뒤에 URL 이 있는 크리에이터 프로필**을 연다.

워크트리에는 서명 키스토어가 없다. `packages/app/android/app/build.gradle.kts` 의 `signingConfigs` 블록을 먼저 읽어 어떤 Gradle 프로퍼티를 참조하는지 확인하고, 그 이름들을 `-P<이름>=<값>` 으로 넘겨 메인 체크아웃의 키스토어를 가리킨다:

```bash
grep -n -A12 'signingConfigs' packages/app/android/app/build.gradle.kts
```

빌드는 오래 걸리므로 `nohup` 으로 띄우고 로그를 따라간다. Sentry 업로드 스텝이 FAILED 로 끝나도 APK 자체는 나온다 — 그 실패로 멈추지 않는다.

기대: 크래시 없음. 접힌 상태에서 보이는 링크에는 밑줄이 그대로 있고, 잘려 안 보이는 링크의 밑줄은 안 그려진다.

- [ ] **Step 7: Sentry 에서 유입이 멈추는지 본다**

이슈 `ZETA-APP-ZG55` (`https://sentry.luda.ai/organizations/pingpong/issues/340537/`) 의 `dist` 태그 분포를 본다. 새 네이티브 빌드의 `dist` 값에서 신규 이벤트가 0 이어야 한다. 옛 `dist=346` 에서는 계속 들어온다 — 그 빌드는 고쳐지지 않는다.

---

## 남은 것 (이 계획 밖)

- 상류 PR [#58366](https://github.com/react/react-native/pull/58366) 은 우리 것이 아니다. 머지되면 다음 base bump 때 체리픽을 지우고 `allowed-tarball-diff.txt` 에서 `TextDecorationStyle.kt` 줄을 뺀다.
- 이번 네이티브 출고 전까지 `dist=346` 사용자에게는 크래시가 계속 난다. 코드푸시 우회는 이 계획의 범위가 아니다.
