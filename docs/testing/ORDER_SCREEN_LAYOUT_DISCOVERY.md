# 주문화면 레이아웃 Discovery

`discoverLayout`은 이미 열린 화면의 UIA 트리를 읽는 관찰 연산이다. Focus, Input, Select, Toggle, Click, 키 입력을 보내지 않으며 Scenario 실행이나 `ResultEvaluator` 호출도 하지 않는다.

## 공개 명령

```powershell
dotnet build HtsQaPoc.sln -c Release
.\targets\1q-hts\0101\scripts\inspect-order-screen.ps1 -OutputDirectory <로컬 산출물 폴더>
```

명령은 표시 중인 대상 메인 창이 정확히 1개이고 그 아래 `[0101]` 화면 창이 정확히 1개일 때만 진행한다. 화면을 열거나 상태를 전환하지 않는다. 0개 또는 2개 이상이면 `LAYOUT_*_WINDOW_COUNT_INVALID`로 중단한다.

## 안전 기본값

- `includeCurrentValues=false`; offscreen/invisible 제외; container 포함
- `timeoutMs=10000`, `maxDepth=16`, `maxElements=5000`
- 요소별 provider 예외 격리 및 중복 제거
- password/account/customer/user/token/auth 후보는 값 대신 마스킹 메타데이터만 기록
- UI Action 및 transactional Action count는 항상 0

영역은 root bounds의 정규화 좌표로 `GlobalHeader`, `QuotePanel`, `OrderEntryPanel`, `TradeInfoPanel`, `PopupOrOverlay`, `Unclassified` 가설을 기록한다. 이는 업무 의미 확정이나 locator 승인이 아니다.

## 산출물 분리

`screen-layout-observation.json`, `control-discovery-results.json`, `state-observation-results.json`, `calibration-session.json`, `control-repository-candidates.json`, `scenario-authoring-hints.json`은 모두 `artifactRole=Discovery`, `verdictEligible=false`, `testExecution=false`, `resultEvaluatorInvoked=false`다.

`scenarioId`, `caseId`, `canonicalVerdict`는 null이며 상태는 `NotExecuted`, `NoCanonicalVerdict`, `ResultEvaluatorNotInvoked`로 고정된다. 이 파일을 `test-results.json`으로 바꾸거나 PASS/FAIL로 해석해서는 안 된다.

Control Repository 후보는 `ReviewRequired`/`Unapproved`, 캘리브레이션과 시나리오 힌트는 `ConfigurationRequired`로 남는다. 자동 승인, repository 병합, executable Scenario/TestPack 생성은 수행하지 않는다.

현재 상태를 먼저 수집한 뒤 운영자가 직접 안전한 비거래 상태를 바꾼 경우 같은 명령을 별도 폴더에 다시 실행한다. 승인 transition/baseline/restore locator가 없는 동안 도구가 상태를 바꾸지 않는다.

실제 계좌번호, 비밀번호, 사용자 ID, token, 현재 입력값, pixel crop은 산출물에 저장하지 않는다. 현장 산출물은 로컬 증거이며 자동 commit 대상이 아니다.
