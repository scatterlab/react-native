# scatterlab React Native fork — 배포 파이프라인 (Phase 1)

## 목적

zeta가 **직접 수정한 React Native**를 쓸 수 있는 배포 경로를 확보한다. 첫 사용 사례는 iOS CJK IME composition 수정(상류 이슈 [56463](https://github.com/react/react-native/issues/56463), 수정 PR [56082](https://github.com/react/react-native/pull/56082) — 둘 다 우리가 작성, 미머지)이지만, **Phase 1은 IME 수정을 포함하지 않는다.** 파이프라인 자체를 먼저 확보하고, IME 수정은 정당성 재검증 후 Phase 2에서 별도로 반영한다.

Phase 1의 성공 기준은 단 하나: **상류를 왜곡 없이 재생산하는 사설 패키지를 배포하고, 실제 앱에서 빌드된다.**

## 결정 사항

| 항목 | 결정 | 근거 |
| --- | --- | --- |
| 레포 | `scatterlab/react-native` — `react/react-native`의 **public fork** | fork 가시성은 upstream network에 종속돼 private 불가. fork를 포기하면 Sync fork·cross-fork compare·상류 PR 생성이 전부 사라짐 |
| 패키지 | `@scatterlab/react-native`, **npmjs.org, public** | GitHub Packages는 public 패키지도 설치에 토큰이 필수라, 공개 배포에서는 마찰만 남는다. npmjs의 `scatterlab` 스코프는 실재 확인됨(`/-/org/scatterlab/user` → 200, 미존재 스코프는 404 `Scope not found`) |
| base | 태그 `v0.86.2` (npm `latest`, 2026-07-27) | `v0.86.1`은 GitHub·Maven엔 있으나 **npm 미배포**라 base 불가. `main`은 PR #56082 head보다 937커밋 앞서 비교 기준으로 부적합 |
| 브랜치 | `scatterlab/0.86.2` | 상류 CI의 `push: branches: [main, *-stable]` 패턴에 안 걸림 |
| 버전 | `0.86.2-scatterlab.N` — **대시 1개** | 접미사에 대시가 2개면 fork 관련 greedy 정규식(`/(.+)-(.+)/`)이 오파싱 |
| dist-tag | `0.86-stable`, `latest` | react-native-tvos 관례 |
| 소비 방식 | npm alias — `"react-native": "npm:@scatterlab/react-native@<ver>"` | 디스크 경로가 `node_modules/react-native`로 유지돼야 함 |

### 소비 방식이 alias여야 하는 이유

디렉터리명 `react-native`를 literal로 가정하는 지점들이 alias 하나로 전부 무력화된다.

- `@react-native/gradle-plugin` → `ReactExtension.kt:39` (`root.dir("node_modules/react-native")`), `PathUtils.kt:98` (`.../react-native/cli.js`)
- `@react-native-community/cli-config` → `resolveReactNativePath.js:20` (`resolveNodeModuleDir(root, 'react-native')`)
- zeta → `packages/app/ios/Podfile:13`, `packages/app/ios/z.xcodeproj/project.pbxproj:1205` 외 4곳
- `@react-native/metro-config/dist/index.js:32` (`"/node_modules/react-native/index.js$"`)
- codegen → `generate-artifacts-executor.js`가 `${path.sep}react-native${path.sep}`로 RN 자기 파일을 제외. 이름이 바뀌면 **codegen 산출물이 조용히 달라진다**

실측(이 레포의 yarn 4.12 바이너리, 격리 환경): alias의 on-disk 디렉터리명은 **의존성 키** 이름을 따른다. 레포 내 선례도 존재 — `node_modules/@babel/traverse--for-generate-function-map`.

## fork 변경 전량 (Phase 1)

파일 3개. product 소스는 하나도 포함하지 않는다.

```
packages/react-native/package.json
  name           → "@scatterlab/react-native"
  version        → "0.86.2-scatterlab.1"
  publishConfig  → { "access": "public" }
  repository     → scatterlab/react-native

packages/react-native/scripts/cocoapods/rncore.rb        stable_tarball_url 첫 줄
packages/react-native/scripts/cocoapods/rndependencies.rb  release_tarball_url 첫 줄
  version = version.sub(/-scatterlab\.\d+\z/, '')
```

### iOS prebuilt를 유지하기 위한 2줄

0.86에서 iOS prebuilt는 **opt-out**이다(`scripts/react_native_pods.rb:93` — env가 `'0'`이 아니면 `'1'`). 그리고 조회 버전은 fork의 package.json `version` 원문이다(`new_architecture.rb:147-153` → `rncore.rb:61`). 따라서 손대지 않으면:

```
react-native-artifacts-0.86.2-scatterlab.1-reactnative-core-debug.tar.gz  → 404 (실측)
react-native-artifacts-0.86.2-reactnative-core-debug.tar.gz               → 200 (실측)
```

404 → `artifacts_exists=false` → **prebuilt를 조용히 잃고 React core를 소스빌드**한다. 그래서 URL 빌더 안에서만 접미사를 벗긴다.

`RCT_TESTONLY_RNCORE_VERSION` env 우회는 **쓸 수 없다.** 다운로드된 로컬 tarball 파일명은 Ruby가 override된 버전으로 짓는데(`rncore.rb:409-412`), 빌드 시 그 파일을 다시 찾는 `replace-rncore-version.js`는 package.json 버전으로 이름을 만든다(`React-Core-prebuilt.podspec:53-76`). 두 이름이 어긋나 Release 빌드마다 `tar extraction failed`로 죽는다. URL 쪽만 고치면 파일명은 fork 버전으로 남아 양쪽이 정합한다.

접미사 정규식은 fork 전용이어야 한다 — 상류의 정상 prerelease(`0.87.0-rc.3`)는 그 전체 버전으로 아티팩트가 실제 존재하므로 벗기면 안 된다. 실측: `0.86.2-scatterlab.1`·`0.86.2-scatterlab.12` → `0.86.2`, `0.87.0-rc.3` → 보존.

`rncore.rb`/`rndependencies.rb`는 공유 코드가 없어 각각 고쳐야 한다. 두 파일 모두 URL 빌더는 stable 1개뿐이고(`stable_tarball_url` / `release_tarball_url`), 로컬 파일명은 `download_*_tarball`의 별도 `version` 인자에서 나온다 — 즉 서로 간섭하지 않는다.

### 절대 건드리지 않는 것

| 대상 | 현재 값 | 건드리면 |
| --- | --- | --- |
| `ReactAndroid/gradle.properties` `VERSION_NAME` | `0.86.2` | RNGP가 이 값으로 `resolutionStrategy.force("com.facebook.react:react-android:$v")` → Maven Central에 없는 좌표를 찾다 실패 (`DependencyUtils.kt:143,167,189,213-259`) |
| `react.internal.publishingGroup` | `com.facebook.react` | 위와 동일 경로 |
| `@react-native/*` sibling 7개 | exact `0.86.2` | `@react-native/codegen@0.86.2-scatterlab.1`을 npm에서 찾다 install 실패. 8개 패키지 전부 배포해야 함 |
| `bin` | `{"react-native": "cli.js"}` | zeta `packages/app/scripts/deploy/uploadCodePush.js:36`이 `node_modules/.bin/react-native` 심링크를 복사 → codepush 배포 전멸 |
| `sdks/hermes-engine/version.properties` | `HERMES_VERSION_NAME=0.17.0`, `HERMES_V1_VERSION_NAME=250829098.0.16` | Hermes Maven 좌표 |

### 실행 금지 스크립트

- `scripts/releases/set-version.js` — 모든 워크스페이스 이름을 새 버전으로 치환하며 `dependencies`/`devDependencies`의 sibling 범위까지 재작성 (`scripts/utils/monorepo.js:121-133`)
- `scripts/releases/set-rn-artifacts-version.js` — `VERSION_NAME=`을 재작성 (`:158-160`). 또한 `isStablePrerelease`가 `rc.`/`rc-`/`YYYYMMDD-HHMM`만 허용해 `-scatterlab.1`을 reject

버전은 `packages/react-native/package.json`의 `version` 필드만 바꾼다. `ReactNativeVersion.{kt,js}` / `RCTVersion.m` / `ReactNativeVersion.h`는 순수 보고용이며 pod install·런타임에 게이트가 없다(shipped Ruby의 유일한 `Gem::Version` 비교는 Xcode 버전 대상).

## 배포 파이프라인

### tarball 구성 사실

published tarball은 소스 트리의 부분집합이 아니다. `react-native@0.86.2` tarball(4575 파일) vs git tree(4911 blob) 비교 결과 **tarball에만 있는 파일 = 정확히 251개, 2그룹**.

| 그룹 | 개수 | 생성 주체 |
| --- | --- | --- |
| `types_generated/**` | 237 | 루트 `yarn build-types --skip-snapshot` (구현 위치 `scripts/js-api/build-types`, 출력 상수 `scripts/js-api/config.js:30`) |
| `React/FBReactNativeSpec/**` | 14 | `packages/react-native`의 `prepack` — `npm pack`/`npm publish`에 **자동 부착** |

> 비교 시 `LC_ALL=C sort` + `LC_ALL=C comm` 필수. ko_KR locale로 돌리면 `package.json` 같은 명백한 거짓 항목이 섞여 386개가 나온다.

부수 사실:
- `yarn build`는 react-native tarball에 **기여하지 않는다** (sibling 6개만 빌드 — `scripts/build/config.js`)
- `prepack`이 `../../README.md`를 복사하므로 **monorepo 체크아웃 안에서, cwd=`packages/react-native`로** pack해야 한다
- `sdks/hermesc/`는 0.86에서 tarball·git 양쪽 모두 부재(`files[]`의 dead entry). hermesc는 npm 의존 `hermes-compiler@250829098.0.16`이 공급

### 최소 시퀀스

```bash
git clone <fork> && git switch -c scatterlab/0.86.2 v0.86.2
# packages/react-native/package.json 4필드 수정
yarn install
yarn build-types --skip-snapshot
cd packages/react-native && npm pack        # prepack 자동 실행
# diff 게이트 통과 후
npm publish
```

### 배포 워크플로

`.github/workflows/scatterlab-publish.yml` — `workflow_dispatch(version, dist_tag, dry_run)`.

pack 전에 검사하는 불변식(각각 조용하거나 원인 오판하기 쉬운 실패를 막는다):

- 버전 형태 `^\d+\.\d+\.\d+-scatterlab\.\d+$` — 대시가 2개면 접미사 제거가 오작동
- `ReactAndroid/gradle.properties`의 `VERSION_NAME`이 상류 base와 일치
- `@react-native/*` sibling 핀이 상류 base와 일치
- `bin`이 `{"react-native": "cli.js"}` 유지

`version`·`dist_tag`는 `run:`에 도달하므로 env로 전달하고 문자셋을 제한한다(workflow_dispatch는 write 권한자 전용이지만 셸 인젝션 벡터는 실재).

### 배포 인증: npm Trusted Publishing (OIDC)

토큰을 쓰지 않는다. 업스트림이 이미 이 방식이고(`publish-npm.yml:1-14`), 우리도 동일하게 `permissions: id-token: write`만으로 배포한다.

제약 4개:

- **패키지가 존재하기 전에는 trusted publisher를 등록할 수 없다.** `npm trust` 전제조건: *"Package must exist: The package you're configuring must already exist on the npm registry."* 구조적 제약이다 — 토큰 교환 엔드포인트가 `/-/npm/v1/oidc/token/exchange/package/<name>`으로 패키지 스코프라, 없는 패키지면 교환이 실패하고 무인증으로 폴백한다(npm/cli#8544가 이 갭을 인정하는 오픈 이슈). **첫 배포만 수동**, 이후 OIDC.
- **npm ≥ 11.5.1 / Node ≥ 22.14.0.** `ubuntu-latest`의 기본 npm은 10.9.8로 미달이며 Node 22 최신도 동일하다. 워크플로가 `node-version: 24`를 핀해 npm 11.16.0을 얻는다 — **이 핀을 지우면 인증이 깨진다.**
- **워크플로 파일명이 계약이다.** npm은 OIDC `workflow_ref` 클레임을 **최상위** 워크플로 파일명(basename, 확장자 포함, 대소문자 구분)과 대조하고 패키지당 trusted publisher는 1개만 허용한다. 따라서 `npm publish`는 이 파일 안에서 직접 실행돼야 한다 — 재사용/컴포짓 워크플로로 옮기면 클레임이 바뀌어 인증이 깨진다. 업스트림이 배포 진입점 3개를 하나로 합친 이유가 이것이다. 브랜치 제약은 없고 `environment`는 선택.
- `NODE_AUTH_TOKEN`은 OIDC보다 우선하지 않지만(npm이 무조건 교환을 시도하고 성공 시 토큰을 덮어씀) 두지 않는다 — 교환 실패 시 낡은 토큰으로 폴백해 원인 진단이 꼬인다. `setup-node`의 `registry-url`은 유지한다.

부수 효과로 provenance attestation이 붙는다(`Signed provenance statement with source and build information from GitHub Actions`). 게이트(상류 대비 허용 목록 외 차이 0)와 합쳐지면 fork가 상류에서 무엇을 바꿨는지가 배포물 자체로 검증 가능해진다.

로컬에서 publish·view할 때는 `--@scatterlab:registry=https://registry.npmjs.org`까지 줘야 한다 — **스코프별 레지스트리 설정이 `--registry` 플래그보다 우선**하고, 이 조직 개발 머신은 `@scatterlab`을 GitHub Packages로 매핑해두고 있다. 이걸 빠뜨리면 install이 `npm.pkg.github.com`을 조회해 404가 난다.

### prerelease 버전과 peer 해석 (소비자 주의)

fork 버전이 prerelease이므로 **npm 기반 소비자는 `--legacy-peer-deps`가 필요하다.** 실측: `@react-native/new-app-screen@0.86.2`가 `peer react-native@"0.86.2"`를 걸고, npm의 semver에서 `0.86.2-scatterlab.1`은 그 범위를 만족하지 않는다(`*`·`^0.86.2`·`0.86.2` 전부 false. `includePrerelease`를 켜도 exact·caret은 여전히 false).

이는 fork에 내재된 성질이고 피할 수 없다 — exact peer 핀을 만족시키는 non-prerelease 버전은 문자 그대로 `0.86.2`뿐이며, 그건 npm 버전 불변성 때문에 반복 배포가 불가능하다. react-native-tvos도 같은 성질을 갖는다(`0.86.0-2`).

**zeta는 영향 없다** — Yarn 4는 `satisfiesWithPrereleases`로 검사하며 prerelease 태그를 벗기고 비교한다(실측 확인).

### 레포 운영 위생

fork에는 상류 워크플로 26개가 함께 딸려온다. 트리거를 전수 확인한 결과 전부 `main` / `*-stable` / 태그 `v0.*.*`로 한정돼 `scatterlab/**` push로는 아무것도 발화하지 않는다 — **트리에서 지우지 않는다**(지우면 상류 리베이스마다 충돌).

- ⚠️ `publish-npm.yml`의 태그 글롭 `v0.*.*`는 `v0.86.2-scatterlab.1`도 **매치한다.** fork에 `v*` 태그를 만들지 않는다(필요하면 `sl-` prefix)
- 위험한 상류 워크플로(`publish-npm`, `test-all`, `validate-*`, `create-*release`, `prebuild-ios-*`)는 API로 개별 disable — 트리 무관이라 리베이스 충돌이 없다
- CodeQL default setup은 fork 생성 직후 자동 실행되므로 `not-configured`로 해제
- `workflow_dispatch`는 워크플로 파일이 **기본 브랜치에 있어야** 노출되므로, fork 기본 브랜치를 `scatterlab/0.86.2`로 둔다. `main`은 상류 동기화용으로 남긴다(main에 push하면 상류 CI가 발화하므로 동기화 시 주의)

## 검증 게이트

1. **tarball 동등성** — 우리 tarball vs 상류 `react-native@0.86.2` tarball을 비교해, 허용 목록(`.github/scatterlab/allowed-tarball-diff.txt`) 밖의 파일이 하나라도 다르거나 추가·누락되면 실패. 소스 수정이 없는 Phase 1에서는 허용 목록이 곧 fork 변경 전량이므로 이 게이트는 완전하다.

   **실측 결과 (통과)**: 4575 / 4575 파일, 추가·누락 0, 바이트 차이 3개 = `package.json`, `scripts/cocoapods/rncore.rb`, `scripts/cocoapods/rndependencies.rb`. `types_generated/` 237개와 `React/FBReactNativeSpec/` 14개가 상류 배포본과 **바이트 동일**하게 재생성됐다 — 로컬 툴체인이 상류의 생성 산출물을 재현한다는 증거.
2. **설치 형태** — `node -p "require('react-native/package.json').name"` → `@scatterlab/react-native`, 디렉터리는 `node_modules/react-native`, `npx react-native --version` 동작
3. **iOS** — `pod install`이 prebuilt 경로를 유지하는지 (`Podfile.lock`에 `React-Core-prebuilt`), 시뮬레이터/기기 빌드 성공
4. **Android** — `./gradlew :app:dependencies | grep react-android` → `0.86.2` (공식 AAR), hermesc가 `node_modules/hermes-compiler/hermesc/%OS-BIN%/`에서 해소
5. **증명 대상** — 신규 생성한 0.86.2 샘플앱(배포 파이프라인) + fork 내 RNTester(Phase 2의 IME 수정 검증·상류 재리뷰 자료)

### Phase 1 실측 결과 (전부 통과)

| 항목 | 결과 |
| --- | --- |
| tarball 동등성 (로컬 + CI) | 4575/4575, 추가·누락 0, 허용 목록 3파일만 차이 |
| 배포 | `0.86.2-scatterlab.1` 수동(부트스트랩), `0.86.2-scatterlab.2` **OIDC 토큰 없이** + provenance 서명 |
| alias 설치 (레지스트리) | `@scatterlab/react-native @ 0.86.2-scatterlab.2`, 디렉터리 `node_modules/react-native`, `.bin/react-native` 심링크 생존 |
| `pod install` | 54s, `React-Core-prebuilt (0.86.2-scatterlab.1)` — **prebuilt 유지**, `hermes-engine/Pre-built` |
| 아티팩트 파일명 | `reactnative-core-0.86.2-scatterlab.1-debug.tar.gz` — URL은 base, 파일명은 fork (설계한 비대칭 확인) |
| iOS 빌드 | `** BUILD SUCCEEDED **` |
| Android 빌드 | `BUILD SUCCESSFUL in 2m 43s`, 91 tasks, 공식 AAR `com.facebook.react:react-android:0.86.2` |

## zeta 배선 (참조 — 적용은 RN 업그레이드 시)

base가 0.86.2이므로 zeta는 RN 0.79.7→0.86.2 업그레이드 완료 전까지 이 패키지를 소비할 수 없다. 업그레이드 프로젝트가 물려받을 배선은 다음과 같다.

- `packages/{app,core,ui,service}/package.json` → `"react-native": "npm:@scatterlab/react-native@<ver>"`. peerDependency(`packages/core/package.json:107`)는 **손대지 않는다** — Yarn이 `satisfiesWithPrereleases`로 검사해 `0.86.2-scatterlab.N`이 exact `0.86.2`를 만족한다(실측). 단 `0.86.3` 류로 가면 YN0060(경고, exit 0)
- root `package.json`의 `resolutions` 키 2개를 **rangeless**로 전환. **범위 한정 키는 scoped alias에서 구조적으로 매칭 불가이며 경고 없이 실패한다** — yarn `resolution.pegjs`의 `description = [^/]+`, 그리고 `/`가 `from/descriptor` 구분자라 `react-native@npm:@scatterlab/react-native@…`가 from=`react-native@npm:@scatterlab`로 오파싱됨. 8종 키 형태 실측 결과 rangeless만 동작
- `.github/workflows/check-main-library-dependency-version.yml:76-77`의 `cut -d: -f2`를 alias/patch 서술자 정규화로 교체. 지금도 `react-native-reanimated`가 `patch:` 서술자라 base/current 둘 다 `patch`로 나와 **사실상 검사되지 않는** 잠복 구멍이 있고, 같은 수정으로 닫힌다
- 무수정: `.yarnrc.yml`, `Podfile`, `project.pbxproj`, `android/**`, metro/babel/vitest/tsconfig/oxlint 전부 (모두 디렉터리명·모듈명 기반)

기존 yarn 패치 2개의 0.86.2 적용 판정(`git apply --check` 실측):

| 패치 | 판정 |
| --- | --- |
| `react-native-npm-0.79.7-1e9f017b38.patch` (NHQA 렌더러 가드) | **경로 개명 필요.** 0.86엔 `ReactNativeRenderer-{dev,prod,profiling}.js`가 없고 `ReactFabric-*.js`만 존재(레거시 아키 렌더러 제거). 대상 코드는 문맥까지 동일해 경로 치환 후 3 hunk 전부 통과(offset만). 애초에 계속 필요한지는 별도 판단 |
| `@react-native-virtualized-lists-npm-0.79.7-54563a3a91.patch` | **무수정 적용.** `_constrainToItemCount` 형태 동일, hunk succeeded at 849 (offset 5). 별도 npm 패키지이므로 fork alias와 무관하게 yarn 패치로 유지 |

### 업그레이드가 반드시 고쳐야 하는 것

`packages/app/android/app/build.gradle.kts:85`
```
hermesCommand.value("../../node_modules/react-native/sdks/hermesc/%OS-BIN%/hermesc")
```
0.86.2에 존재하지 않는 경로다. RNGP의 hermesc 탐색은 `react.hermesCommand`가 설정돼 있으면 **즉시 반환하고 fallthrough 하지 않으므로**(`PathUtils.kt:133-172`) 새 위치로 내려가지 못한다. 단순 삭제도 불가 — `react.root` 기본값이 `packages/app`이고 `packages/app/node_modules`에는 `.cache`/`.generated`뿐이라 상대경로가 빗나간다. 고칠 값: `../../node_modules/hermes-compiler/hermesc/%OS-BIN%/hermesc`

## 스코프 밖

- **IME 수정 반영** — 정당성 재검증 후 Phase 2. PR #56082은 상류에서 리뷰 0건이고, cause #7만 프로덕션 실증이 있으며, 나머지 6개는 미검증
- **iOS prebuilt 전략** — Phase 1은 소스 수정이 0이라 공식 prebuilt xcframework와 정합한다. 자체 prebuilt 호스팅 여부는 Phase 2에서 실측 빌드시간·아티팩트 크기를 근거로 결정
- **RN 0.79.7→0.86.2 업그레이드**, New Architecture 전환, zeta main 적용
- **Android 네이티브 수정** — 현재 수정 범위가 iOS ObjC++뿐이라 사설 Maven·자체 AAR·Hermes 재배포 전부 불필요. Android 소스를 건드리는 순간 이 결론이 뒤집힌다(`gradle.properties` 계약 참조)

## 함정 요약

| 함정 | 결과 |
| --- | --- |
| `set-version.js` 실행 | sibling 7개가 존재하지 않는 버전을 가리켜 install 실패 |
| `VERSION_NAME` 변경 | Android가 없는 Maven 좌표를 조회해 빌드 실패 (iOS는 정상이라 원인 오판 쉬움) |
| 범위 한정 resolutions 키 유지 | 패치가 **경고 없이** 미적용 |
| 접미사에 대시 2개 | fork 버전 파싱 오류 |
| `LC_ALL` 미설정 tarball 비교 | 거짓 diff (ko_KR locale에서 `comm`이 오조합해 386개 거짓 항목) |
| fork에 `v*` 태그 생성 | 상류 `publish-npm.yml`이 발화 |
| `RCT_TESTONLY_RNCORE_VERSION`으로 prebuilt 버전 우회 | Release 빌드마다 `tar extraction failed` |
| npm publish | 버전은 **되돌릴 수 없다**(unpublish 제약). 배포 전 `npm pack` + 게이트로 검증 |
| 로컬 publish에 `--registry`만 지정 | 스코프별 설정이 우선해 GitHub Packages로 발행됨. `--@scatterlab:registry`까지 필요 |
| npm 소비자에서 fork 설치 | prerelease가 exact peer 핀을 못 만족해 ERESOLVE. `--legacy-peer-deps` 필요 (Yarn은 무영향) |
