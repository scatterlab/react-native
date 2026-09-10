# CLAUDE.md

`scatterlab/react-native` — `react/react-native`의 fork. 설계 문서는 [`.github/scatterlab/README.md`](.github/scatterlab/README.md), Android 아티팩트 배포는 [`.github/scatterlab/android-prebuilt.md`](.github/scatterlab/android-prebuilt.md), IME 검증 절차는 [`.github/scatterlab/ime-qa.md`](.github/scatterlab/ime-qa.md). 이 파일은 **여기서 작업할 때의 운용 규칙과 함정**만 담는다.

## 이 레포의 목적

zeta가 **자체 수정한 RN을 출고할 수 있는 경로**를 갖기 위한 fork. 첫 화물은 iOS CJK IME 조합 밑줄 수정이지만, 목적은 그 수정 자체가 아니라 파이프라인이다.

- 상류: `react/react-native` (`facebook/react-native`는 301 alias). remote `upstream`
- 작업 브랜치: **`scatterlab/0.87.1`** (기본 브랜치, 태그 `v0.87.1`에서 분기)
- 지난 라인: `scatterlab/0.86.2`, `scatterlab/0.87.0` — 남겨두지만 새 작업은 올리지 않는다
- 계측 브랜치: `scatterlab/0.86.2-ime-probe` — `SLIME` 로그가 붙은 실험용. 0.86.2 라인에 묶여 있고 **배포 대상 아님**
- 산출물: npm `@scatterlab/react-native@0.87.1-scatterlab.N` + GitHub Release `prebuilt-ios-<version>` + `prebuilt-android-<version>`(모든 fork 버전에 필수)
- 소비: npm alias — `"react-native": "npm:@scatterlab/react-native@<version>"`

`main`은 상류 동기화용으로만 둔다. **`main`에 push하지 않는다** — 상류 워크플로가 발화한다.

## 절대 하면 안 되는 것

| 금지 | 이유 |
| --- | --- |
| `ReactAndroid/gradle.properties`의 `VERSION_NAME` 변경 | RNGP가 이 값으로 `com.facebook.react:react-android:<v>`를 force resolve → Maven Central에 없는 좌표를 찾다 실패. **Android만** 죽어서 원인 오판하기 쉽다 |
| `@react-native/*` sibling 7개 exact 핀 변경 | `@react-native/codegen@<fork버전>`을 npm에서 찾다 install 실패. 8개 패키지를 다 배포해야 함 |
| `scripts/releases/set-version.js` / `set-rn-artifacts-version.js` 실행 | 전자는 sibling 범위를 전부 재작성, 후자는 `VERSION_NAME`을 재작성. 둘 다 위 두 항을 정확히 깨뜨린다 |
| `package.json`의 `bin` 변경 | zeta의 codepush 배포가 `node_modules/.bin/react-native` 심링크를 복사한다 |
| `v*` 태그 생성 | 상류 `publish-npm.yml`의 글롭 `v0.*.*`가 `v0.87.1-무엇이든`도 매치하고, 그 워크플로의 `set_hermes_versions` 잡은 repo 게이트가 없다. 태그는 `prebuilt-ios-` / `prebuilt-android-` / `sl-` 처럼 `v`로 시작하지 않게 |
| 버전 접미사에 대시 2개 | `-scatterlab.N` 고정. fork 접미사 제거 정규식이 greedy하다 |
| 릴리스 에셋 clobber | warm `~/Library/Caches/ReactNative`를 가진 개발자가 낡은 xcframework를 영구히 쓴다. 새 `-scatterlab.N`을 낸다 |

버전은 `packages/react-native/package.json`의 `version` 필드만 바꾼다. `ReactNativeVersion.*`·`RCTVersion.m`은 순수 보고용이라 불일치가 무해하다.

## 배포

```bash
gh workflow run scatterlab-publish.yml --repo scatterlab/react-native --ref scatterlab/0.87.1 \
  -f version=0.87.1-scatterlab.N -f dist_tag=latest -f dry_run=false
```

- 인증은 **npm Trusted Publishing (OIDC)** — 토큰 없음. `permissions: id-token: write` + `node-version: 24`(핀 제거 금지, `ubuntu-latest` 기본 npm 10.9.8은 요구치 11.5.1 미달)
- npm은 **workflow_ref 클레임을 최상위 워크플로 파일명과 대조**하고 패키지당 trusted publisher는 1개다. `npm publish`를 재사용/컴포짓 워크플로로 옮기면 인증이 깨진다
- **게이트**: tarball이 상류 동일 base 버전과 `allowed-tarball-diff.txt` 밖에서 다르면 실패. 소스를 새로 건드리면 그 파일에 경로를 추가해야 한다
- publish 직후 **~1분간 install이 `ETARGET`으로 실패**한다(packument와 dist-tags 캐시가 별개). **소비자(zeta) 쪽 핀 bump PR**은 install 확인 후에 — fork 자체의 `version` 필드 bump는 이것과 다른 얘기로, 이 워크플로를 돌리기 **전에** 이미 머지돼 있어야 한다(아래 "Android prebuilt" 참조)

## Android prebuilt

Android는 `com.facebook.react:react-android:<VERSION_NAME>`을 Maven Central에서 force resolve 하므로 **fork의 `ReactAndroid/**` 수정은 npm으로 안 간다**. 패치된 AAR을 따로 낸다.

```bash
gh workflow run scatterlab-prebuild-android.yml --repo scatterlab/react-native --ref scatterlab/0.87.1 \
  -f version=0.87.1-scatterlab.N -f verify_symbol=<이번에 추가한 식별자> -f dry_run=false
```

`--ref`로 체크아웃하는 브랜치의 `packages/react-native/package.json` `version`이 **이미** `-f version=`과 같아야 한다 — 워크플로의 `prepare`가 이 둘을 대조하고, 실제 릴리스(`dry_run=false`)에서 다르면 하드 실패한다. 즉 fork의 버전 bump 커밋은 이 명령을 돌리기 전에 먼저 머지돼 있어야 한다.

**순서 제약**: prebuilt 릴리스가 npm보다 먼저 있어야 한다. 없으면 소비자 Gradle configure가 abort한다. 설계·함정은 [`.github/scatterlab/android-prebuilt.md`](.github/scatterlab/android-prebuilt.md).

`verify_symbol`이 load-bearing이다. 모든 fork 버전의 AAR 좌표가 동일해서, 이 검사 없이는 "아티팩트가 있다"가 "패치가 들어 있다"를 전혀 보증하지 않는다.

## iOS prebuilt

prebuilt가 기본(0.84+)이고, 켜지면 **모든 React\* pod의 구현이 `React.xcframework`에서 온다**. 즉 **iOS 소스 수정은 prebuilt가 켜진 채로는 조용히 무효**다. 그래서 자체 빌드·호스팅한다.

```bash
gh workflow run scatterlab-prebuild-ios.yml --repo scatterlab/react-native --ref scatterlab/0.87.1 \
  -f version=0.87.1-scatterlab.N
```

**순서 제약**: `FORK_REQUIRES_OWN_PREBUILT = true`이므로 **prebuilt 릴리스가 npm보다 먼저** 있어야 한다. 없으면 소비자 `pod install`이 abort한다(그게 의도다 — 조용히 패치 없는 프레임워크를 출고하는 것보다 낫다).

한 flavor만 성공한 **부분 릴리스가 위험하다**: probe는 debug 에셋만 확인하므로 통과시키고 release flavor에서 404가 난다. 그때는 에셋을 지우거나 새 `-scatterlab.N`을 낸다.

**prebuilt 조회는 fail-closed다.** core와 deps는 한 덩어리로 움직인다 — 한쪽만 source로 내려간 조합은 warm `Pods/`에서는 이월된 `React-Core-prebuilt` 스펙 때문에 해석이 깨지고, clean `Pods/`에서는 반대로 해석에 성공해 prebuilt core가 source 빌드 third-party와 링크된 바이너리를 **에러 없이** 출고한다. 그래서 그 조합은 `pod install` 초반에 중단시킨다. 판정은 env 플래그가 아니라 **core가 실제로 계산한 모드**로 한다 — 로컬 tarball이 있으면 플래그가 `0`이어도 prebuilt이고, `FORK_REQUIRES_OWN_PREBUILT = false`인 버전에선 플래그가 `1`이어도 source로 내려간다. 조회는 `ReactNativePodsUtils.probe_artifact`(`scripts/cocoapods/utils.rb`) 하나를 쓰고 재시도·HTTP 상태·curl 종료 코드를 남긴다. 둘 다 소스로 빌드하려면 `RCT_USE_PREBUILT_RNCORE=0`를 준다. 상세는 `.github/scatterlab/README.md`의 "artifact probe는 fail-closed다".

## CI 러너

맥은 `[self-hosted, zeta-app-builder]`, 리눅스는 `arc-messenger-dev`. **GitHub-hosted 러너로는 릴리스를 만들 수 없다** — org IP allow list가 인증된 `api.github.com` 쓰기를 403으로 막는다(아티팩트 업로드는 Actions 서비스라 통과). `publish-prebuilt.sh`가 그 상황용 fallback.

맥 러너는 zeta의 네이티브 출고(`zeta-frontend`의 `deploy-native.yml`)와 같은 라벨을 쓴다. gaudi보다 빠른 것도 있지만, 본질적인 이유는 Xcode를 핀하지 않는 정책과 맞물린다 — 프레임워크의 Swift module interface가 **앱을 빌드하는 그 Xcode**에서 나와야 호환성 계약이 자동으로 성립한다. 두 러너의 유저명은 모두 `scatterlab`이라 절대 경로 전제도 그대로 유효하다.

self-hosted에서만 나타나는 함정:

- **matrix 잡이 같은 `$HOME`을 공유한다.** yarn 1 전역 캐시는 동시성 안전하지 않아 tar 추출이 깨진다. `YARN_CACHE_FOLDER`를 `$GITHUB_ENV`로 export(플래그로는 부족 — prebuild setup이 **내부적으로 두 번째 yarn**을 부른다) + `max-parallel: 1`
- `runner` 컨텍스트는 **잡 레벨 `env:`에서 못 쓴다** — 워크플로 파싱 자체가 HTTP 422로 실패하고, 증상이 "워크플로가 없다"처럼 보인다
- Xcode를 핀하지 않는다(러너 기본값 사용). 대신 `Toolchain` 스텝이 버전을 찍는다 — **그 Xcode가 프레임워크의 Swift module interface에 들어가므로 호환성 계약의 일부**다
- 빌드 산출물은 flavor당 수 GB다. `rm -rf .build third-party`를 `if: always()`로 둔다
- 상류 워크플로 24개는 트리거가 `main`/`*-stable`/`v0.*` 태그라 `scatterlab/**` push엔 무발화 → **트리에서 지우지 않는다**(지우면 리베이스마다 충돌). 위험한 것만 API로 개별 disable

fork 자체 워크플로는 셋이다: `scatterlab-publish.yml`·`scatterlab-prebuild-ios.yml`(둘 다 `workflow_dispatch` 전용)과 `scatterlab-test-prebuilt-probe.yml`. 마지막 것만 `scatterlab/**` push와 `scripts/cocoapods/**` PR에서 자동으로 돈다 — 상류 `test-all`의 Ruby 잡이 `github.repository` 게이트에 막혀 이 fork에서는 아무 테스트도 돌지 않기 때문이다.

## 개발 루프

기능 검증은 소스빌드 경로로 한다 — **배포도 prebuilt 릴리스도 필요 없다**:

```bash
cd packages/react-native && npm pack
# 샘플앱에서
node -e '…dependencies["react-native"] = "file:<abs tgz>"…'   # ← alias 형태 필수
npm install --legacy-peer-deps
cd ios && RCT_USE_PREBUILT_RNCORE=0 bundle exec pod install
```

`RCT_USE_PREBUILT_RNCORE=0`이 load-bearing이다. 안 주면 수정한 소스가 컴파일되지 않고 실험이 **조용히 아무것도 측정하지 않는다**.

### "내용이 바뀌었는데 식별자가 같다" 계열 함정

세 번 밟았다. 전부 에러 없이 조용히 옛 것을 쓴다:

1. `file:` tarball을 **같은 버전으로 재팩** → npm이 캐시된 것을 재사용. 버전을 올리거나 `node_modules`+lock을 지운다
2. `npm i file:<tgz>` → tarball 자체 이름(`@scatterlab/react-native`)으로 설치되고 `node_modules/react-native`는 그대로. **반드시 `dependencies["react-native"] = "file:…"` 키 형태**로
3. `node_modules` 교체 후 **Metro 캐시 불일치** → 존재하는 파일에 `Unable to resolve`. 단서는 `candidateExts: []` 하나. `find "$TMPDIR" -maxdepth 1 -name 'metro-*' -exec rm -rf {} +`

그래서 **설치본에 변경이 실렸는지 먼저 증명하는 게이트**를 항상 둔다(버전 출력 + 변경 문자열 grep 카운트).

### 기기 빌드·설치

```bash
xcrun devicectl list devices
xcodebuild -workspace <ws>.xcworkspace -scheme <scheme> -configuration Release \
  -destination "platform=iOS,id=<id>" -derivedDataPath dd-device -allowProvisioningUpdates \
  PRODUCT_BUNDLE_IDENTIFIER=<고유 id> DEVELOPMENT_TEAM=XK4C83B395 CODE_SIGN_STYLE=Automatic build
xcrun devicectl device install app --device <id> <path>.app
xcrun devicectl device process launch --device <id> --console --terminate-existing <bundle-id>
```

- **자동 서명을 쓴다.** 팀 wildcard 프로파일(`XK4C83B395.*`)에 개발 인증서가 없으면 Xcode가 그 프로파일을 갱신해 넣어준다 → App ID를 새로 등록하지 않고 임의 번들 식별자를 쓸 수 있다. `match Development` 프로파일을 재사용하면 기기의 zeta 앱을 덮어쓰므로 하지 않는다
- **Release로 빌드한다.** JS 번들이 내장돼 Metro 없이 단독 실행되고, `NSLog`는 그대로 나온다
- `process launch`의 번들 식별자는 **위치 인자**다(`--bundle-id` 플래그는 없다). `--console` 없이는 `NSLog`가 안 잡힌다 — `device console`은 별개 채널
- 표시명은 빌드 설정으로 못 바꾼다. 템플릿 `Info.plist`에 `CFBundleDisplayName`이 명시돼 있어 plist를 직접 고쳐야 한다
- 시뮬레이터는 marked-text에 대해 **유효한 오라클이 아니다**

## 커밋

커밋 메시지 본문은 **한국어**로 쓴다. 타입 접두어(`feat`/`fix`/`ci`/`docs`/`chore`)와 스코프, 코드 식별자·파일 경로·에러 문자열·명령어는 원문 유지. 상류로 올릴 PR 커밋만 영어 예외.

푸시는 항상 브랜치를 명시한다 — 로컬에 상류 `v0.*` 태그가 660여 개 있어서 `--tags`/`--follow-tags`가 사고를 낸다.

```bash
git push origin scatterlab/0.87.1
```

## 상류 기여

fork(같은 repository network)이므로 여기서 상류로 PR을 열 수 있다. 개인 fork `kdwkr/react-native`는 git 접근이 403으로 막혀 있어 **PR #56082에 새 커밋을 올릴 수 없다** — 상류 재리뷰는 이 레포에서 새 PR로 가야 한다. 그 PR head 커밋은 로컬 태그 `pr-56082-head`로 고정해뒀다.
