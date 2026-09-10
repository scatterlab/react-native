# Android prebuilt

fork가 수정한 **Android** 네이티브 코드를 소비자에게 실어 보내는 경로. iOS prebuilt([README.md](README.md))와 대칭이며, 존재 이유도 같다 — **소스만 고치면 조용히 무효다.**

## 왜 필요한가

iOS는 prebuilt가 켜진 채로 소스를 고치면 무효였다. Android는 그보다 앞선 지점에서 끊긴다: 소비자의 빌드는 fork의 npm tarball에 든 `ReactAndroid/**` 소스를 **아예 컴파일하지 않는다.**

RNGP가 모든 configuration에 대해 좌표를 force resolve 한다:

```kotlin
// DependencyUtils.kt:132
configuration.resolutionStrategy.force(
    "${coordinates.reactGroupString}:react-android:${coordinates.versionString}")
```

`versionString`은 `ReactAndroid/gradle.properties`의 `VERSION_NAME`이고(`readVersionAndGroupStrings`), 그 값은 업스트림 base로 고정해야 한다(fork 접미사를 붙이면 존재하지 않는 좌표가 된다). 따라서 소비자는 기본적으로 **Maven Central의 업스트림 `com.facebook.react:react-android:<base>` AAR**을 받는다. fork의 Kotlin·C++ 변경은 그 AAR에 없다.

`node_modules`에 든 소스로 빌드하게 만들려면 `includeBuild`로 ReactAndroid 전체를 소비자 빌드에 끌어와야 하는데, NDK·CMake 컴파일이 소비자 CI마다 반복된다. 그래서 iOS와 같은 형태를 택한다 — **fork가 한 번 빌드해 배포하고, 소비자는 받아 쓴다.**

## 결정

| 항목 | 값 | 이유 |
| --- | --- | --- |
| 산출물 | `/tmp/maven-local` 트리 전체를 tar | `publishAllToMavenTempLocal`의 고정 출력 경로(`ReactAndroid/publish.gradle:16`) |
| 릴리스 태그 | `prebuilt-android-<fork-version>` | iOS의 `prebuilt-ios-<fork-version>`과 대칭. `v`로 시작하지 않아 상류 `publish-npm.yml`의 `v0.*.*` 글롭에 안 걸린다 |
| 에셋 | `react-native-android-maven-<fork-version>.tar.gz` + `.sha256` | |
| 호스팅 | GitHub Release 에셋 | 릴리스 AAR 160MB · 디버그 AAR 268MB. npm tarball 동봉은 tarball-diff 게이트와 install 시간을 둘 다 깨뜨린다 |
| 소비 배선 | fork npm 패키지의 gradle 스크립트 + 소비자 `settings.gradle.kts` 한 줄 | 판정·다운로드·검증·abort를 fork가 소유한다. `@react-native/gradle-plugin`에는 넣을 수 없다 — sibling 7개는 업스트림 정확 버전 고정이 불변식이다 |
| 게이트 | 릴리스가 없으면 **abort** | iOS `FORK_REQUIRES_OWN_PREBUILT`와 동일. 모든 `-scatterlab.N`이 Android 릴리스를 가져야 한다 |
| 공개 시점 | `build`가 **draft**로 만들고, `verify`가 통과한 뒤에만 공개(`--draft=false`) | draft는 push 권한자에게만 보이고 에셋 URL이 나머지에게 404다. 미검증 릴리스가 그 창에서 노출되지 않는다 |
| 캐시 | `~/.gradle/scatterlab-react-native/<fork-version>/maven` | 아래 "좌표 충돌" 참조 |

## 좌표 충돌 — 이 설계의 핵심 함정

`VERSION_NAME`이 base로 고정되므로 **모든 fork 버전의 AAR이 같은 좌표를 갖는다**: `com.facebook.react:react-android:0.87.1`. `-scatterlab.2`의 AAR과 `-scatterlab.3`의 AAR은 Gradle이 보기에 구별 불가능한 같은 모듈이다.

따라서 캐시 디렉터리를 **fork 버전으로 스코프**한다. 버전마다 별개의 maven 저장소 루트를 만들고, 그 경로를 `react.internal.mavenLocalRepo`로 넘긴다. 한 루트를 공유하면 새 버전을 받아도 Gradle 모듈 캐시가 옛 AAR을 계속 쓰고, **에러 없이 옛 네이티브 코드가 출고된다.**

iOS의 warm `~/Library/Caches/ReactNative` 함정과 같은 모양이지만, 여기서는 좌표까지 같아 더 조용하다.

## 빌드 — `scatterlab-prebuild-android.yml`

`workflow_dispatch(version)`. `prepare` → `build` → `verify` 3잡, iOS 워크플로와 같은 골격.

러너는 `arc-messenger-dev`(Linux). GitHub-hosted 러너는 org IP allow list 밖이라 인증된 `api.github.com` 쓰기가 403이다.

핵심 스텝:

```bash
env ORG_GRADLE_PROJECT_react.internal.useHermesStable=true \
    ./gradlew publishAllToMavenTempLocal -PenableWarningsAsErrors=true
```

- **상류 `.github/actions/build-android`를 재사용하지 않는다.** 그 액션은 `scripts/releases/set-rn-artifacts-version.js`를 부르는데, 이 스크립트가 `VERSION_NAME`을 재작성해 위의 불변식을 정확히 깨뜨린다(실행 금지 목록에 있다).
- `react.internal.useHermesStable=true`로 Hermes는 빌드하지 않고 Maven Central 안정판을 쓴다. `com.facebook.hermes:hermes-android`는 다른 publishing group이라 아래의 그룹 제외에 걸리지 않는다.
- `isSnapshot`을 켜지 않는다. 켜면 버전에 `-SNAPSHOT`이 붙어 좌표가 어긋난다.
- ABI는 기본값(`armeabi-v7a,arm64-v8a,x86,x86_64`)을 그대로 둔다. 소비자의 `reactNativeArchitectures`와 같아야 한다.
- Debug·Release 두 variant는 `components.default` 멀티 variant 퍼블리시로 한 번에 나온다(`publish.gradle`).
- ccache를 러너에 유지한다. 없으면 매 실행이 전체 C++ 재컴파일이다.
- 빌드 산출물은 수 GB다. `if: always()`로 정리한다.

에셋 업로드는 **clobber 하지 않는다.** 소비자 캐시가 버전별로 스코프돼 있어 같은 태그의 에셋을 갈아끼우면 이미 받아 둔 개발자·러너는 영구히 옛 것을 쓴다. 새 `-scatterlab.N`을 낸다.

`build`는 릴리스를 **draft**로 만든다(`gh release create --draft`). draft는 push 권한자에게만 보이고 에셋 다운로드 URL이 그 외에는 404다 — `verify`가 전부 통과할 때까지 미검증 릴리스가 소비자에게 노출되지 않는다. 같은 태그가 이미 있으면: draft면 그대로 재사용해 에셋을 마저 올리고, 이미 **공개**된 릴리스면 재실행을 abort한다(소비자가 이미 본 릴리스에 검증 안 된 에셋을 얹지 않기 위해서다).

## 소비자 배선

로직은 fork의 npm 패키지에 담는다: `packages/react-native/scripts/android/scatterlab-prebuilt-maven.gradle`.

동작 순서:

1. `packages/react-native/package.json`의 `version`을 읽는다. `^\d+\.\d+\.\d+-scatterlab\.\d+$`가 아니면 **no-op** — 업스트림 react-native로도 이 스크립트가 붙은 채 동작해야 한다.
2. `~/.gradle/scatterlab-react-native/<version>/maven`이 이미 있으면 그대로 쓴다.
3. 없으면 `https://github.com/scatterlab/react-native/releases/download/prebuilt-android-<version>/react-native-android-maven-<version>.tar.gz`를 받아 `.sha256`으로 검증하고 임시 디렉터리에 푼 뒤 최종 경로로 rename 한다. 부분 추출된 트리가 성공한 캐시로 남으면 안 된다.
4. 릴리스가 없거나 sha가 어긋나면 **빌드를 중단한다.** 메시지는 `rncore.rb:378`과 같은 형태로 — 무엇이 없고 어떤 워크플로를 돌려야 하는지 적는다.
5. `gradle.beforeProject`에서 각 프로젝트에 `react.internal.mavenLocalRepo`를 그 경로로 세팅한다.

캐시가 이미 있으면 네트워크를 타지 않으므로 `--offline` 빌드도 그대로 된다. 캐시가 없는데 네트워크가 없으면 abort한다 — 조용히 업스트림으로 떨어뜨리지 않는다.

그러면 RNGP가(`DependencyUtils.kt:56-87`):

- 그 디렉터리를 maven 저장소로 추가하고,
- **Maven Central에서 `com.facebook.react` 그룹 전체를 제외한다.**

두 번째가 중요하다 — 우리 저장소가 그 그룹의 아티팩트를 **전부** 들고 있어야 한다. `publishAllToMavenTempLocal`의 산출물이 정확히 그 집합이다.

소비자(zeta) 쪽 변경은 `packages/app/android/settings.gradle.kts` 한 줄이다:

```kotlin
apply(from = "../../../node_modules/react-native/scripts/android/scatterlab-prebuilt-maven.gradle")
```

`settings.gradle` 평가 시점에 동기적으로 받는다. `pod install`이 xcframework를 받는 자리와 같다. 별도 태스크로 빼고 CI·postinstall이 먼저 부르게 하는 형태는 택하지 않는다 — 그 단계를 빠뜨린 로컬 빌드가 **에러 없이 업스트림 AAR로 돌아간다.**

## 검증

**워크플로 `verify` 잡** — 릴리스가 소비 가능한지 확인하고, 통과해야만 릴리스를 공개한다:

- 에셋 이름이 정확히 기대한 2개인지 (`gh api ... --jq '.assets[].name'` diff). GitHub은 예상 밖 문자가 든 에셋 이름을 재작성한다.
- tarball을 받아 sha256이 맞는지. 릴리스가 이 시점엔 아직 draft라 공개 다운로드 URL이 404다 — `gh release download`로 `GH_TOKEN` 인증된 API를 거쳐 받는다.
- 트리에 `com/facebook/react/react-android/<base>/`의 `react-android-<base>-debug.aar`, `-release.aar`, `.module`, `.pom`이 모두 있는지.
- 위 검사가 전부 통과한 뒤에야 `gh release edit --draft=false`로 릴리스를 공개한다. 실패하면 draft로 남아 소비자에게 노출되지 않는다.

**패치가 실려 있는지 증명하는 게이트** — "내용이 바뀌었는데 식별자가 같다" 계열 사고를 막는 유일한 수단이다. 좌표가 버전 간 동일하므로 여기서는 필수다.

`build` 잡에 `verify_symbol` 입력을 둔다. 이 버전이 도입한 식별자(예: 클래스명·메서드명)를 넣으면 이 잡이 릴리스 AAR의 `classes.jar`를 풀어 `javap -p`로 그 심볼을 찾고, 0건이면 실패한다. `javap` 자체가 실행되지 못한 경우(예: 툴체인 문제)는 "심볼 없음"과 구별되는 별도 에러로 실패한다 — 조용히 0건으로 수렴하지 않는다. 빈 값이면 이 검사를 건너뛰고 `::warning::`을 남긴다 — base bump처럼 새 심볼이 없는 릴리스도 있지만, 빈 값이 실수인 경우와 구별할 신호가 필요해서다.

소비자 쪽 확인은 `--info` 실행에서 해석된 AAR 경로가 `~/.gradle/scatterlab-react-native/<version>/maven` 아래인지 보는 것으로 족하다. 새 fork 버전으로 처음 빌드할 때 한 번 본다.

**단위 테스트** — 수정마다 ReactAndroid의 Robolectric 테스트를 붙인다.

**엔드투엔드** — 소비자에서 release APK를 빌드해 실기기로 증상을 확인한다. 시뮬레이터·에뮬레이터로 대체하지 않는다.

## 출고 순서

iOS와 같은 제약이 하나 더 붙는다.

```
prebuilt-ios-<N>  릴리스
prebuilt-android-<N>  릴리스      ← 추가
npm publish (scatterlab-publish.yml)
소비자 핀 갱신
```

두 prebuilt 릴리스가 npm보다 **먼저** 있어야 한다. 뒤집으면 소비자의 `pod install`(iOS)과 Gradle configure(Android)가 각각 abort한다. 그게 의도다 — 패치 없는 네이티브를 조용히 출고하는 것보다 낫다.

"있어야 한다"는 **공개(published)** 상태를 뜻한다. Android는 `verify`가 통과하기 전까지 draft다 — 소비자는 공개 다운로드 URL만 쓰므로, 그 창에는 존재해도 없는 것과 같고 똑같이 abort한다.

이 순서를 `scatterlab-publish.yml`이 검사하지는 **않는다.** iOS와 같은 선택이다 — 강제는 소비자 쪽 abort 한 곳에만 두고, publish는 순서를 모른 채 돈다. publish 후 릴리스를 만들어도 결과는 같고, 그 사이에 설치한 소비자만 abort를 본다.

한 flavor만 성공한 **부분 릴리스**가 iOS에서 위험했던 것과 같은 이유로, Android도 `verify` 잡이 두 variant를 모두 확인한 뒤에야 릴리스를 소비 가능으로 본다.

## 절대 하면 안 되는 것

[README.md](README.md)의 표에 이어서:

| 금지 | 이유 |
| --- | --- |
| `scatterlab-prebuild-android.yml`에서 상류 `.github/actions/build-android` 재사용 | 그 액션이 `set-rn-artifacts-version.js`를 불러 `VERSION_NAME`을 재작성한다 |
| 캐시 디렉터리를 fork 버전으로 스코프하지 않기 | 좌표가 버전 간 동일해 옛 AAR이 조용히 재사용된다 |
| 릴리스 에셋 clobber | 이미 받아 둔 소비자가 영구히 옛 AAR을 쓴다 |
| `isSnapshot=true` | 좌표에 `-SNAPSHOT`이 붙어 어긋난다 |
| maven 트리에서 일부 아티팩트만 골라 올리기 | RNGP가 Maven Central에서 `com.facebook.react` 그룹을 통째로 제외하므로, 빠진 아티팩트는 어디서도 못 찾는다 |
| 이미 **공개**된 릴리스에 재실행으로 에셋 업로드 | 소비자가 이미 본 릴리스에 검증 안 된 에셋을 얹게 된다. 재실행이 필요하면 draft 상태일 때만 재사용하고, 공개된 태그는 새 `-scatterlab.N`으로 간다 |
