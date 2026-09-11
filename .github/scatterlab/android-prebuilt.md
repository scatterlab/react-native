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

## 저장소 순서 — 소비자도 한 가지를 해야 한다

`react.internal.mavenLocalRepo` 를 세팅하면 RNGP가 Maven Central에서 `com.facebook.react` 그룹을 제외한다. **그것만으로는 부족하다.** 그 제외는 **RNGP가 추가한** 저장소에만 붙고, RNGP는 app 프로젝트의 `afterEvaluate` 에서 저장소를 추가한다(`ReactPlugin.kt:90-99`). 소비자가 자기 빌드 스크립트에 `repositories { mavenCentral() }` 을 써 두었으면 그게 목록 앞자리를 차지하고, Gradle은 저장소를 선언 순서대로 조회하므로 우리 저장소에 닿기 전에 업스트림 AAR이 나간다.

zeta에서 실측한 저장소 목록:

```
[0] Google      https://dl.google.com/...
[1] MavenRepo   https://repo.maven.apache.org/maven2/   ← 필터 없으면 여기서 나간다
[8] maven6      file:.../scatterlab-react-native/<version>/maven/
[9] MavenRepo2  https://repo.maven.apache.org/maven2/   ← RNGP가 추가, excludeGroup 있음
```

그래서 **소비자가 자기 저장소 선언에서 그 모듈을 제외해야 한다.** 규칙은 "`mavenCentral()` 을 제외한다" 가 아니라 **소비자가 선언한 저장소 중 이 좌표를 서빙할 수 있는 것 전부**다 — 콘텐츠 필터는 그것이 붙은 저장소에만 적용되므로, 사설 미러나 `mavenLocal()` 을 앞에 하나 더 두면 그것이 먼저 응답한다.

zeta는 `google()`·`mavenCentral()` 둘뿐이라 `packages/app/android/app/build.gradle.kts` 가 이렇게 된다(뒤따르는 광고 SDK 저장소들은 이 좌표를 서빙하지 않는다):

```kotlin
val forkOnly: (org.gradle.api.artifacts.repositories.MavenArtifactRepository) -> Unit = {
    it.content { excludeModule("com.facebook.react", "react-android") }
}
google(forkOnly)
mavenCentral(forkOnly)
```

그룹 전체가 아니라 모듈 하나만 제외하는 이유는, RNGP가 `react-native` 를 `react-android` 로, `hermes-android` 를 `com.facebook.hermes` 그룹으로 치환해서 이 그룹에서 실제로 해석되는 좌표가 `react-android` 뿐이고, 그룹을 통째로 막으면 우리가 싣지 않는 것에서 깨지기 때문이다.

### 제외 범위는 릴리스가 싣는 좌표와 같이 간다

`publishAllToMavenTempLocal` 산출물은 현재 `com.facebook.react:react-android` 하나다. Hermes는 `com.facebook.hermes:hermes-android:<hermesVersion>` 으로 **다른 그룹·다른 버전**에서 해석되고(`DependencyUtils.kt` 의 `getDependencySubstitutions`) 우리는 그걸 싣지 않으므로, 소비자가 그것까지 제외하면 아무 저장소도 응답하지 못해 빌드가 깨진다.

`ReactAndroid` 의 C++ 수정은 `react-android` AAR의 `jniLibs` 로 들어가므로 이미 덮인다. 덮이지 않는 것은 **Hermes 엔진 자체**를 패치하는 경우다. 그때는 릴리스에 `hermes-android` 를 추가하고 소비자 제외 목록도 같이 늘려야 한다. 두 목록은 항상 같이 움직인다 — 한쪽만 늘리면 빌드가 깨지고, 다른 쪽만 늘리면 조용히 업스트림이 실린다.

### 이 실패는 조용하다

배선이 빠져도 **빌드는 성공하고 경고도 없다.** 아티팩트는 정확하고, 소비자만 그것을 쓰지 않는다. 이 레포의 검사는 전부 우리가 만든 AAR을 보므로 — 스모크, tarball 게이트, `verify_symbol` — 소비자 쪽 결함을 하나도 잡지 못한다. 판정 기준은 **소비자가 실제로 해석한 파일의 심볼 개수**다:

```groovy
import org.gradle.api.artifacts.component.ModuleComponentIdentifier

// 소비자 프로젝트에 init script 로 주입
def cfg = project.configurations.getByName('<variant>RuntimeClasspath')
def hits = cfg.incoming.artifactView { view ->
  view.componentFilter { id ->
    id instanceof ModuleComponentIdentifier &&
      id.group == 'com.facebook.react' && id.module == 'react-android'
  }
}.artifacts.artifacts
if (hits.size() != 1) {
  throw new GradleException("expected exactly 1 react-android artifact, got ${hits.size()}")
}
println "RESOLVED ${hits.first().variant.owner} :: ${hits.first().file}"
```

`lenient = true` 를 쓰지 않는 것과 개수를 단언하는 것이 둘 다 필요하다. lenient 는 해석에 실패한 아티팩트를 **조용히 결과에서 빼므로**, 빈 결과가 "업스트림이 안 실렸다" 인지 "해석이 깨졌다" 인지 구별되지 않는다. 문자열 `contains` 대신 `ModuleComponentIdentifier` 의 `group`·`module` 로 맞추는 것도 같은 이유다.

그 AAR의 `classes.jar` 를 풀어 그 버전이 도입한 식별자를 `javap -p` 로 센다. 0이면 업스트림이 실린 것이다. 모든 fork 버전이 같은 좌표(`com.facebook.react:react-android:0.87.1`)를 쓰므로 파일 경로나 존재 여부로는 판별할 수 없다.

**Kotlin 톱레벨 함수는 파일 파사드 클래스에 들어간다.** `0.87.1-scatterlab.4` 의 `visibleTextEnd` 는 `TextDecorationStyle.class` 가 아니라 `TextDecorationStyleKt.class` 에 있다. class 파일 하나만 보면 패치가 들어 있어도 0을 센다.

**검증은 반드시 실제 소비자에서 한다.** 저장소가 미리 선언돼 있지 않은 프로브 프로젝트는 이 결함을 재현하지 못한다 — 그런 프로젝트에서는 RNGP가 추가한 저장소가 유일하므로 항상 통과한다.

### `repositoriesMode` — 기본값에서만 성립한다

RNGP는 저장소를 **프로젝트 수준**(app 프로젝트의 `afterEvaluate`)에 추가한다. `react.internal.mavenLocalRepo` 경로든 아니든 마찬가지다. 따라서 소비자의 `dependencyResolutionManagement.repositoriesMode` 가 기본값이 아니면 RNGP 메커니즘 자체가 성립하지 않는다.

| 모드 | RNGP 기본 경로 | 우리 배선 | 결과 |
| --- | --- | --- | --- |
| `PREFER_PROJECT` (기본) | 동작 | 동작 | 지원 대상. zeta가 여기다 |
| `PREFER_SETTINGS` | 프로젝트 저장소가 무시된다 | 무시된다 | settings의 Maven Central이 업스트림 AAR을 **조용히** 서빙한다 |
| `FAIL_ON_PROJECT_REPOS` | 구성 오류 | 구성 오류 | 빌드가 죽는다 |

zeta는 `settings.gradle.kts` 에 `dependencyResolutionManagement` 블록이 없어 기본값이고, 저장소를 `app/build.gradle.kts` 의 프로젝트 수준에 선언한다. 다른 모드를 쓰는 소비자가 생기면 배선을 settings 수준(`dependencyResolutionManagement.repositories`)으로 옮겨야 한다.

### 알려진 한계

fork 쪽 스크립트가 `exclusiveContent` 로 이 모듈을 우리 저장소에 잠그면 순서에 의존하지 않으므로 소비자 배선 없이도 성립한다. 다만 그것을 `project.repositories` 에 등록하면 위 표의 두 비기본 모드에서 똑같이 무시되거나 깨진다. 스크립트는 settings 평가 중에 돌므로 `dependencyResolutionManagement.repositories` 에 등록하는 편이 옳고, 그러려면 세 모드 fixture와 위 harness로 실제 소비자에서 양·음 양쪽을 재현한 뒤여야 한다.

## 좌표 충돌 — 이 설계의 핵심 함정

`VERSION_NAME`이 base로 고정되므로 **모든 fork 버전의 AAR이 같은 좌표를 갖는다**: `com.facebook.react:react-android:0.87.1`. `-scatterlab.2`의 AAR과 `-scatterlab.3`의 AAR은 Gradle이 보기에 구별 불가능한 같은 모듈이다.

따라서 캐시 디렉터리를 **fork 버전으로 스코프**한다. 버전마다 별개의 maven 저장소 루트를 만들고, 그 경로를 `react.internal.mavenLocalRepo`로 넘긴다. 한 루트를 공유하면 새 버전을 받아도 Gradle 모듈 캐시가 옛 AAR을 계속 쓰고, **에러 없이 옛 네이티브 코드가 출고된다.**

iOS의 warm `~/Library/Caches/ReactNative` 함정과 같은 모양이지만, 여기서는 좌표까지 같아 더 조용하다.

## 빌드 — `scatterlab-prebuild-android.yml`

`workflow_dispatch(version, verify_symbol, dry_run)`. `prepare` → `build` → `verify` 3잡, iOS 워크플로와 같은 골격.

같은 버전에 대한 두 번의 dispatch가 겹치지 않도록 `concurrency: group: scatterlab-prebuild-android-<version>`으로 **큐잉**한다(취소가 아니라 대기). 취소를 택하면 먼저 돌던 실행이 에셋만 올리고 draft를 정리하지 못한 채 죽을 수 있는데, 그 상태가 뒤 실행이 잠깐 기다리는 것보다 나쁘다.

러너는 `arc-messenger-dev`(Linux). GitHub-hosted 러너는 org IP allow list 밖이라 인증된 `api.github.com` 쓰기가 403이다.

`prepare`는 빌드 전에 버전 두 개를 맞대본다.

1. `ReactAndroid/gradle.properties`의 `VERSION_NAME`이 `version` 입력에서 뽑은 upstream base와 같은지. AAR 좌표가 이 값으로 나가므로, 어긋나면 존재하지 않는 좌표를 빌드하게 된다.
2. 체크아웃한 `packages/react-native/package.json`의 `version`이 `version` 입력과 같은지. `dry_run=false`에서는 **하드 실패**다 — 소비자 스크립트가 만드는 다운로드 URL은 그 `package.json` 버전으로 정해지므로, 둘이 다르면 이 태그를 받은 소비자가 다른 버전용 바이너리를 받는다. `dry_run=true`에서는 경고만 남긴다. 그래서 fork의 `version` 필드 bump는 **이 워크플로를 실제로 돌리기 전에 먼저 머지돼 있어야 한다.**

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
- 빌드는 **zeta 의 네이티브 Android 출고가 도는 러너**(`[self-hosted, zeta-app-builder]`)에서 돈다 — SDK·NDK·CMake 가 이미 있고 조직 TLS 프록시도 이미 신뢰한다. 상류처럼 `reactnativecommunity/react-native-android` 컨테이너를 쓰는 길은 막혀 있다: dind ARC 러너의 잡 컨테이너 안에서는 git 이 github.com 을 검증하지 못하고(조직이 자체 CA로 TLS를 종단한다), `volumes:` 로도 못 고친다 — dind는 **docker 데몬 쪽** 파일시스템을 마운트하지 그 CA를 가진 러너의 것을 마운트하지 않는다. `ANDROID_HOME` 은 `deploy-native.yml` 과 같은 값을 쓴다.
- 러너의 Android SDK에 `cmake;3.30.5` 와 `ndk;27.1.12297006` 이 있어야 한다. zeta 앱 빌드는 prebuilt AAR을 링크할 뿐 ReactCommon을 컴파일하지 않아 이 둘을 쓸 일이 없었다. 워크플로가 `sdkmanager` 로 직접 설치하고 설치 여부를 디렉터리 존재로 확인한다 — 라벨 뒤에 머신이 여러 대라 손으로 깔면 한 대만 고쳐진다. 버전은 `libs.versions.toml`(ndkVersion)·`ReactAndroid/build.gradle.kts`(cmakeVersion)를 따르며 **base를 올릴 때 함께 맞춘다**.
- ccache를 러너에 유지한다. 없으면 매 실행이 전체 C++ 재컴파일이다.
- 빌드 산출물은 수 GB다. `if: always()`로 정리한다.

에셋 업로드는 **clobber 하지 않는다.** 소비자 캐시가 버전별로 스코프돼 있어 같은 태그의 에셋을 갈아끼우면 이미 받아 둔 개발자·러너는 영구히 옛 것을 쓴다. 새 `-scatterlab.N`을 낸다.

`build`는 릴리스를 **draft**로 만든다(`gh release create --draft`). draft는 push 권한자에게만 보이고 에셋 다운로드 URL이 그 외에는 404다 — `verify`가 전부 통과할 때까지 미검증 릴리스가 소비자에게 노출되지 않는다. 같은 태그가 이미 **공개**된 릴리스로 있으면 재실행을 abort한다(소비자가 이미 본 릴리스에 검증 안 된 에셋을 얹지 않기 위해서다). draft로 있으면 — 이전 실행이 에셋을 올리다 `verify`에서 실패해 남은 경우다 — 그 draft를 **삭제하고 새로 만든다.** draft는 push 권한 없는 쪽에는 애초에 존재한 적이 없어 지워도 안전하고, 재사용하는 대신 지우고 다시 만들어야 부분 실행에서 올라간 에셋(예: debug AAR만 올라간 상태)이 이번 실행 결과와 섞여 남지 않는다.

## 소비자 배선

로직은 fork의 npm 패키지에 담는다: `packages/react-native/scripts/android/scatterlab-prebuilt-maven.gradle`.

동작 순서:

1. `packages/react-native/package.json`을 읽는다. `name`이 `@scatterlab/react-native`가 아니면 **no-op** — 업스트림 react-native로도 이 스크립트가 붙은 채 동작해야 한다. 우리 패키지인데 `version`이 `^\d+\.\d+\.\d+-scatterlab\.\d+$`를 만족하지 않으면(예: rc 접미사) **빌드를 중단한다** — 그대로 두면 업스트림 AAR로 조용히 넘어간다.
2. 캐시 판정은 디렉터리 존재가 아니라 `~/.gradle/scatterlab-react-native/<version>/maven/com/facebook/react/react-android/<base>/react-android-<base>.pom` 파일의 존재다. 중단된 추출이나 부분 정리로 디렉터리만 남은 트리를 warm으로 오판하지 않기 위해서다. 그 파일이 있으면 그대로 쓴다.
3. 없거나 깨져 있으면(캐시 디렉터리를 지운 뒤) `https://github.com/scatterlab/react-native/releases/download/prebuilt-android-<version>/react-native-android-maven-<version>.tar.gz`를 받아 `.sha256`으로 검증하고, 최종 경로 옆에 만든 임시 디렉터리에 푼 뒤 rename으로 옮긴다. 부분 추출된 트리가 성공한 캐시로 남으면 안 된다.
4. 릴리스가 없거나 sha가 어긋나면 **빌드를 중단한다.** 메시지는 `rncore.rb:378`과 같은 형태로 — 무엇이 없고 어떤 워크플로를 돌려야 하는지 적는다.
5. `gradle.beforeProject`에서 각 프로젝트에 `react.internal.mavenLocalRepo`를 그 경로로 세팅한다.

캐시가 이미 있으면 네트워크를 타지 않으므로 `--offline` 빌드도 그대로 된다. 캐시가 없는데 네트워크가 없으면 abort한다 — 조용히 업스트림으로 떨어뜨리지 않는다.

**`SCATTERLAB_PREBUILT_BASE_URL`** — 다운로드 base URL을 덮어쓰는 환경변수. fork npm 패키지에 그대로 실려 있어 모든 소비자 빌드가 이 코드를 거친다. 오직 소비자 스크립트 스모크 테스트가 로컬 fixture 서버를 가리키기 위한 시임이라, 값의 host가 루프백(`127.0.0.1`, `[::1]`, `localhost`)일 때만 적용된다. `.sha256` 사이드카도 같은 base에서 받으므로, 루프백이 아닌 값을 그냥 받아들이면 아카이브와 그걸 검증할 체크섬을 같은 곳에서 받게 돼 무결성 검사가 아무것도 증명하지 못한다 — 그래서 루프백이 아니면 실제 릴리스로 폴백하지 않고 **빌드를 중단한다.**

스크립트는 `gradle.beforeProject` 에서 프로퍼티를 세팅한다. 그것만으로는 소비자가 이 AAR을 실제로 쓰게 되지 않는다 — 위 "저장소 순서" 참조.

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

- 에셋 이름이 정확히 기대한 2개인지 (`gh release view --json assets --jq '.assets[].name'` diff). GitHub은 예상 밖 문자가 든 에셋 이름을 재작성한다. REST의 "get a release by tag"(`gh api repos/.../releases/tags/<tag>`)는 draft를 못 찾으므로 쓰지 않는다 — `gh release view`가 쓰는 GraphQL 경로만 draft를 태그로 찾는다.
- tarball을 받아 sha256이 맞는지. 릴리스가 이 시점엔 아직 draft라 공개 다운로드 URL이 404다 — `gh release download`로 `GH_TOKEN` 인증된 API를 거쳐 받는다.
- 그 sha256이 `build` 잡이 산출한 값과 **같은지도** 확인한다. `.sha256` 사이드카는 아카이브가 자기 자신과 일치한다는 것만 증명하고, 이 비교라야 그 아카이브가 **이 실행이 만든** 것이라는 걸 증명한다.
- 릴리스의 `targetCommitish`가 이 실행의 `$GITHUB_SHA`와 같은지. 같은 태그를 다른 커밋에서 두 번 돌리면 릴리스는 하나만 존재하므로, 이 검사가 없으면 나중 실행의 `verify`가 앞선 실행이 만든(또는 그 반대의) 에셋을 검증 없이 승격시킬 수 있다.
- 트리에 `com/facebook/react/react-android/<base>/`의 `react-android-<base>-debug.aar`, `-release.aar`, `.module`, `.pom`이 모두 있는지.
- 위 검사가 전부 통과한 뒤에야 `gh release edit --draft=false`로 릴리스를 공개한다. 실패하면 draft로 남아 소비자에게 노출되지 않는다.

**패치가 실려 있는지 증명하는 게이트** — "내용이 바뀌었는데 식별자가 같다" 계열 사고를 막는 유일한 수단이다. 좌표가 버전 간 동일하므로 여기서는 필수다.

`workflow_dispatch`에 `verify_symbol` 입력을 둔다. `dry_run=false`인 실제 릴리스는 이 값이 **비어 있으면 `prepare`에서 실패한다** — 새 심볼이 없는 릴리스(예: base bump)라면 빈 값이 아니라 리터럴 `(none)`을 넣어야 한다. 값이 있고 `(none)`이 아니면 `build` 잡이 AAR 둘을 대조한다: 먼저 Maven Central의 **업스트림 base release AAR**에서 그 심볼을 찾아 0건인지 확인하고(있으면 실패 — 이 fork가 추가한 게 아니라는 뜻이므로 "패치가 들어 있다"의 증거가 못 된다), 그다음 이번에 빌드한 release AAR에서 같은 심볼을 찾아 1건 이상인지 확인한다. 둘 다 `classes.jar`를 풀어 `javap -p`로 디스어셈블한 뒤 문자열로 센다. `javap` 자체가 실행되지 못한 경우(예: 툴체인 문제)는 "심볼 없음"과 구별되는 별도 에러로 실패한다 — 조용히 0건으로 수렴하지 않는다. `(none)`이거나(`dry_run=true`에서) 빈 값이면 이 검사 전체를 건너뛰고 `::warning::`을 남긴다.

소비자 쪽 확인은 `--info` 실행에서 해석된 AAR 경로가 `~/.gradle/scatterlab-react-native/<version>/maven` 아래인지 보는 것으로 족하다. 새 fork 버전으로 처음 빌드할 때 한 번 본다.

**소비자 스크립트 스모크 테스트** — `.github/scatterlab/__tests__/android-prebuilt-consumer-test.sh`가 `prepare` 잡에서 (`actions/setup-java` 후) 매 워크플로 실행마다 자동으로 돈다. 확인하는 분기: 업스트림 패키지 no-op, 해석 불가능한 fork 버전(예: rc 접미사) abort, 릴리스 없을 때 abort(정상 네트워크·DNS 차단 양쪽), 빈 디렉터리만 있는 캐시는 warm으로 치지 않고 재다운로드, warm 캐시 오프라인 재사용, 루프백이 아닌 `SCATTERLAB_PREBUILT_BASE_URL` 거부, 그리고 로컬 HTTP fixture 서버로 실제 다운로드·추출까지 도는 콜드캐시 성공 경로 — 좌표가 버전 간 동일해 심볼 게이트만으로는 소비자 쪽 fail-closed를 보장 못 하므로, 이 스크립트가 그 나머지를 지킨다. 콜드캐시 케이스는 `python3`나 빈 로컬 포트가 없으면 건너뛴다 — 로컬에서는 `SKIP`으로 통과하지만, CI에서는 이 러너들이 우리 것이라 건너뜀 자체를 실패로 센다.

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
| 이미 **공개**된 릴리스에 재실행으로 에셋 업로드 | 소비자가 이미 본 릴리스에 검증 안 된 에셋을 얹게 된다. 재실행은 draft 상태일 때만 허용되고(그 draft를 지우고 새로 만든다), 공개된 태그는 새 `-scatterlab.N`으로 간다 |
