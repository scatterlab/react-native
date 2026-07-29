# iOS CJK IME — 기능 검증 런북

이 fork가 싣고 있는 IME 수정(cause 7a)은 **구조적 검증만 끝났다**: 패치가 xcframework에 컴파일돼 소비자 앱에 링크되고 빌드된다는 것까지다. 밑줄이 실제로 복원되는지, 그리고 비-CJK 사용자에게 회귀가 없는지는 **실기기에서만** 확인된다.

시뮬레이터는 유효한 오라클이 아니다 — UIKit의 marked-text 동작은 문서화되어 있지 않고 iOS 버전 간에 달라진다.

## 1. 7a 기능 검증

**대상**: `@scatterlab/react-native@0.86.2-scatterlab.4` 이상.

**기기/OS**: iOS 26(유일한 3자 데이터 포인트가 나온 버전)과 iOS 18, 최소 두 버전. 한 버전만 통과해도 증명되지 않는다.

**IME**: 한국어 2-set, 일본어 로마자 かな漢字, 일본어 12-key 플릭, 중국어 간체 병음. 여기에 **자동수정·QuickType이 붙은 빠른 영문 타이핑**을 반드시 포함한다 — 그게 실제 회귀면이다.

세 케이스는 결과가 통과로 나와도 **증명력이 없다**는 점을 알고 돌린다: emoji(`NSOriginalFont`를 설치해 비교 경로를 우회), 받아쓰기, `secureTextEntry`. 이들은 결함을 가린다.

**prop 조합** (zeta의 채팅 입력창 형태 기준): controlled `value` + `onChangeText`, multiline 오토그로우, 긴 `maxLength`와 짧은 `maxLength` 양쪽, `onSelectionChange` 부착, `autoFocus`, JS가 미리 채운 값에 탭으로 포커스, 변형하는 `onChangeText`, **조합 중 전송**(블러 없이 전송 버튼 탭), `ref.clear()`, 그리고 단일행 입력.

### 하나라도 나오면 릴리스를 막는 관측

| | 관측 | 의미 |
| --- | --- | --- |
| **F1** | controlled 단일행에서 빠른 영문 타이핑·자동수정 중 캐럿이 점프하거나 선택이 붕괴 | 7a를 그대로 쓸 수 없다. 상류 이슈 #44157의 증상이며, 대응은 7b가 **아니라** 등가성 비교를 stripped 키에 둔감하게 만드는 쪽이다 |
| **F2** | JS가 쓴 텍스트 안/뒤에 캐럿을 두고 조합을 시작했을 때 밑줄이 여전히 없음 | 7a만으로는 부족하다. 7b로 답하면 F1을 부른다 |
| **F3** | `textShadowColor` + offset/radius 0 인 텍스트, 또는 `DynamicColorIOS` 배경을 가진 텍스트의 렌더가 변함 | no-op 판정 술어가 오분류하고 있다 |
| **F4** | 롤아웃 후 Sentry에 `NSRangeException` / `NSMutableRLEArray objectAtIndex:effectiveRange:`가 새로 나타남 | 별개 크래시(상류 #55950 클램프로도 재현 보고됨). 7a와 무관하지만 같은 창에서 관측된다 |

**한국어에는 가시적 변화가 없는 것이 정상이다.** 상류 PR의 테스트 플랜 자체가 "Korean: no underline expected (inline replacement)"라고 적고 있고, 프로덕션 보고 3건은 모두 일본 시장이다. 한국어에서 보이는 증상(자모 유실·조기 확정·캐럿 점프)은 아래 cause 2의 영역이다.

## 2. cause 2 실측 — `markedTextRange` 생애 관측

일곱 개 후보 수정 전부가 **아무도 관측하지 않은 가정** 위에 있다: UIKit이 델리게이트 콜백과 Fabric state 왕복에 대해 `markedTextRange`를 언제 set/clear 하는가. 상류 PR의 테스트로는 확인할 수 없다 — mock을 KVC로 주입해 `markedTextRange`를 오버라이드하고, `updateProps:`를 부르지 않아 `multiline`이 기본값 false이며, state·event emitter도 세우지 않는다. 실제 IME가 한 번도 돌지 않는다.

브랜치 `scatterlab/0.86.2-ime-probe`가 다섯 지점에 로그를 심는다.

```bash
cd packages/react-native && npm pack           # 계측된 tarball
# 샘플앱에서
npm i "file:<tarball>" --legacy-peer-deps
cd ios && RCT_USE_PREBUILT_RNCORE=0 bundle exec pod install
```

`RCT_USE_PREBUILT_RNCORE=0`이 핵심이다 — prebuilt가 켜져 있으면 계측한 소스가 컴파일되지 않고 조용히 무시된다. 그래서 이 실험은 npm 배포도, prebuilt 릴리스도 필요 없다.

기기 로그에서 `SLIME`을 grep 한다. 각 줄은 `marked=`(조합 활성), `markedText=`, `sel=시작..끝`, `text=`를 찍는다.

### 무엇을 타이핑하고, 무엇이 결정되는가

| 시나리오 | 볼 것 | 결정되는 것 |
| --- | --- | --- |
| 한국어로 `한` 조합 (ㅎ→하→한) | `_setAttributedString`이 `marked=Y`인 상태로 찍히는가 | 찍히면 조합 중 JS 왕복이 실제로 마크드 텍스트를 파괴한다 = cause 2의 진단이 맞다 |
| 같은 조합 중 **전송 버튼 탭**(블러 없이) | `setTextAndSelection`이 `marked=Y`로 찍히는가 | 찍히면 cause 2를 **작성 그대로 쓰면 안 된다** — 그 가드가 JS의 `''`를 삼켜 자모가 남는다. 좁히기(가드를 `updateState:` 호출부로)가 필요한 근거 |
| `maxLength` 경계에서 한글 조합 | `shouldChangeText`가 `marked=Y`로 찍히는가 | 찍히면 maxLength가 조합 중에 평가된다 = cause 3의 진단이 맞다(다만 cause 3의 구현은 별개 이유로 기각됨) |
| 조합 완료 직후 | `didChange`의 `marked=` 값 | flush 지점에서 조합이 이미 끝나 있는지 = cause 1의 flush 조건이 실제로 만족되는지 |
| 조합 중 JS가 `value`를 바꿈 | `updateState` → `_setAttributedString` 순서와 각각의 `marked=` | 왕복 경로 전체의 실제 순서 |

관측 결과는 코드 판단보다 우선한다. 여기서 나온 순서가 위 표의 예상과 다르면, 그 cause의 진단문 자체를 다시 써야 한다.

> 이 브랜치는 배포하지 않는다. `RCTScatterlabIMEProbe`는 임시 계측이며 릴리스 브랜치에 병합되지 않는다.
