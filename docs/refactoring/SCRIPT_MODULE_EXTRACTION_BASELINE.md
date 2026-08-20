# 거대 PowerShell 실행기 모듈 분리 기준선

작성 기준 HEAD: `d3bd5577acd8adb16085755c05551d78e47ed2bd`

대상:

- `scripts/run-target-rule-suite.ps1` — 3,426줄, 함수 81개
- `scripts/modules/rule-control-exploration.ps1` — 2,099줄, 함수 49개

이 문서는 함수 이동 전에 PowerShell AST로 확인한 호출 관계와 공유 상태를 고정한다. 이번 단계는 실행 의미, 판정, 조합 생성, CaseId, TestPack 승인 규칙을 변경하지 않는다.

## 1. 현재 최상위 실행 흐름

```text
parameter/TestPack validation
  -> manifest + target context + approved plan load
  -> FlaUI bridge session start
  -> HTS main-window session attach
  -> screen navigation/open/focus
  -> runtime discovery + MAP merge
  -> logical-to-physical binding
  -> guarded UI action
  -> raw observation collection
  -> C# ResultEvaluator adapter
  -> completed TestResult reporting
  -> screen/bridge session cleanup
```

`run-target-rule-suite.ps1`의 최상위 실행 블록이 위 단계를 직접 호출한다. `rule-control-exploration.ps1`은 주 실행기에 dot-source되어 주 실행기 함수와 `$script:` 변수를 역으로 참조하므로 로딩 순서가 계약처럼 동작한다.

## 2. 함수 호출 그래프

아래 그래프는 모든 표준 cmdlet 호출을 생략하고 저장소 내부 함수 간 주요 간선을 책임별로 묶은 것이다.

### Session

```text
top-level
  -> Start-FlaUiBridge
       -> Invoke-FlaUiBridgeRequest
            -> ConvertTo-FlaUiAsciiJson
       -> Stop-FlaUiBridge (ping 실패 정리)
  -> Find-HtsMainWindow
       -> Get-TopWindows -> Get-WindowInfo
  -> Wait-HtsMainWindow -> Find-HtsMainWindow
  -> Stop-FlaUiBridge
```

### Navigation

```text
top-level
  -> Find-ScreenNumberEdit
       -> Get-ChildWindows -> Get-WindowInfo
  -> Open-HtsScreen
       -> Set-HtsScreenNumber
            -> Test-HtsScreenNavigationInputAccess
            -> Invoke-FlaUiControlAction
       -> Find-ScreenWindow
       -> Focus-HtsInputWindow / Send-Key (검증된 fallback)
  -> Focus-HtsRequestedScreen
       -> Test-HtsRequestedScreen
            -> Get-WindowInfo -> Get-HtsScreenNumber
  -> Get-HtsLinkedScreens
       -> Get-HtsScreenWindows -> Get-ChildWindows
       -> Get-HtsScreenNumber
  -> Close-HtsLinkedScreens -> Close-HtsScreen
  -> Close-ExistingTargetScreens -> Close-HtsScreen
  -> Close-ScreenSearchOverlays -> Close-HtsScreen
```

### Discovery

```text
top-level
  -> Get-FlaUiActionableControls
       -> Invoke-FlaUiBridgeRequest(discover)
  -> Get-RuleDiscoveredControls
       -> Get-RuleActualTabOrderMap
       -> Get-RuleAfxControlKind / Get-RuleButtonKind
       -> Get-RuleComboOptions / Get-RuleListOptions
       -> Merge-RuleMapBaseline
            -> Merge-RuleSingleMapBaseline
            -> Get-RuleMapTransform / Get-RuleMapGeometry
```

### Binding

```text
top-level
  -> Get-ClaimedControlHwndMap -> Resolve-RoleControl
  -> Resolve-RuleLiveControl
       -> Get-RuleDiscoveredControls
       -> Test-RuleRuntimeKindCompatible
       -> Test-RuleStateContextMatch
  -> Set-ScenarioPhysicalBinding
```

### Action

```text
top-level
  -> Invoke-RuleControlPlanItem
       -> Focus-HtsRequestedScreen
       -> Resolve-RuleLiveControl
       -> Set-RuleCoordinateFocus
       -> Invoke-FlaUiControlAction
       -> Set-AutomationText / Click-Center / native message fallback
  -> Invoke-RuleDatasetVariable
       -> Set-AutomationText / Invoke-RuleComboOptionClick / Invoke-RuleListOptionClick
```

### Observation and evaluation

```text
top-level
  -> Get-HtsDialogs / Get-HtsConnectionDialogs
  -> Add-PopupObservations
  -> Add-LinkedScreenObservations
  -> Add-UnnumberedTransitionObservation
  -> Get-LogState -> Get-TransmissionDelta / Get-LogErrors
  -> Get-HtsSignalObservation / Get-HtsDialogObservation
  -> Invoke-HtsRawObservationEvaluation
       -> ResultEvaluator CLI adapter
  -> reporter(TestResult only)
```

### Safety

```text
physical or UIA input
  -> Set-HtsInputSurface
  -> Assert-HtsClickScope / Assert-HtsKeyboardScope
       -> Test-RuleContentControl
       -> Get-HtsActiveInputSurface
  -> Assert-HtsForeground
  -> Assert-HtsPhysicalPointOwner / Assert-HtsPhysicalCursorTarget
  -> Write-HtsInputBoundaryAudit
```

## 3. 공유 상태와 dot-sourcing 결합

| 소유 후보 | 현재 공유 상태 | 소비 책임 | 위험 |
|---|---|---|---|
| Session | `activeHtsMainHwnd`, `activeHtsPid`, `flaUiBridge` | session, navigation, safety, discovery | 창 재생성 시 여러 함수가 암묵적으로 같은 값을 갱신한다. |
| Navigation | `targetWindowClassName`, `targetWindowTitlePrefix`, `targetScreenIdRegex`, `targetScreenTitleRegex`, `targetMapScreenCodeRegex`, `preservedTargetScreenHwnds` | session, navigation, observation | 데이터셋/대상 프로필과 창 선택 규칙이 숨은 전역 계약이다. |
| Safety | `activeInputSurfaceHwnd`, `activeInputSurfaceKind`, `activeInputSurfaceLabel`, `visiblePointerMotion`, `pointerDwellMilliseconds`, `inputBoundaryAuditPath` | action, navigation, safety | 입력 경계가 호출 인자에 나타나지 않는다. |
| Discovery | `flaUiDiscoveryCalls`, `flaUiElementsDiscovered`, `flaUiFallbackRequests`, `flaUiFallbackReasons` | discovery, reporting | 탐색과 보고가 같은 mutable counter를 공유한다. |
| Action | `flaUiActionAttempts`, `flaUiActionSuccesses`, `lastTextAutomationEngine` | action, reporting, exploration | UI 동작 모듈이 보고 필드에 직접 결합된다. |
| Observation | `currentRequiredExpectations`, `currentResultEvaluationCases`, `currentSignalEvaluationGroups`, `resultEvaluationSequence` | observation, evaluation | 원시 관찰과 평가 호출 순서가 한 스크립트 상태로 결합된다. |
| Exploration | `ruleRoot`, `ruleDataset`, `ruleRegionConfig`, `ruleMapCatalog`, `ruleMapTransformCache`, `ruleActualTabOrderCache`, `ruleOrderTabStateByScreenMap`, `ruleCurrentInteractionStrategy`, `ruleFastScenarioDiscovery`, `lastLiveControlResolution` | discovery, binding, action | 초기화 호출 순서가 누락되면 함수 계약만으로 실패 원인을 알 수 없다. |

추가로 `rule-control-exploration.ps1`의 Win32 메시지 상수도 `$script:` 변수로 선언되어 있다. 상수는 mutable 실행 상태와 분리할 필요가 있지만, 이번 최소 묶음에서는 이동하지 않는다.

AST 기준 공유 상태 접근 함수 수:

- `run-target-rule-suite.ps1`: 81개 중 36개
- `rule-control-exploration.ps1`: 49개 중 21개

두 파일 사이에서 직접 공유되는 대표 값은 `activeHtsMainHwnd`, `lastTextAutomationEngine`, `ruleCurrentInteractionStrategy`, `ruleFastScenarioDiscovery`다.

## 4. 순수 함수와 UI 의존 함수

| 구분 | 대표 함수 | 판단 근거 |
|---|---|---|
| 순수 | `ConvertTo-FlaUiAsciiJson`, `Get-RuleMapCompatibility`, `Test-RuleRuntimeKindCompatible`, `Test-RuleControlExecutionEligible`, `Test-RuleStateContextMatch`, `Test-RuleOrderTabContext`, `Get-RuleMapSemanticScore`, `Get-RuleRelativeRect`, `Test-InRegion`, `Get-MapOracleMessageMatch`, `Get-HtsSignalObservation` | 입력 객체만으로 반환값을 계산하며 UI/파일/프로세스 변경이 없다. |
| 읽기 I/O | `Get-WindowInfo`, `Get-TopWindows`, `Get-ChildWindows`, `Get-FlaUiActionableControls`, `Get-HtsDialogs`, `Get-LogState`, `Capture-HtsScreenshot` | 프로세스·창·파일 상태를 읽지만 판정을 확정하지 않는다. |
| UI 변경 | `Set-HtsScreenNumber`, `Open-HtsScreen`, `Focus-HtsRequestedScreen`, `Close-HtsScreen`, `Click-Center`, `Set-AutomationText`, `Invoke-RuleControlPlanItem`, `Invoke-RuleDatasetVariable` | HWND/UIA/키보드/마우스 상태를 변경한다. |
| 외부 수명 | `Start-FlaUiBridge`, `Invoke-FlaUiBridgeRequest`, `Stop-FlaUiBridge`, `Wait-HtsMainWindow` | 별도 프로세스와 창 수명을 관리한다. |
| 평가·보고 | `Invoke-HtsRawObservationEvaluation`, `Add-Action`, `Export-RuleResultWorkbooks` | ResultEvaluator 호출 또는 파일 리포트 생성을 담당한다. UI 모듈로 이동하면 안 된다. |

## 5. 목표 모듈과 이번 단계 범위

| 목표 모듈 | 책임 | 이번 단계 |
|---|---|---|
| `hts-session.ps1` | FlaUI 프로세스 연결·요청·종료, HTS 메인 창 세션 탐색 | 완료 대상 |
| `hts-navigation.ps1` | 화면 식별·선택·연계 화면 계산과 화면 이동 순서 | 완료 대상 |
| `hts-discovery.ps1` | UIA3 원시 snapshot, MAP/룰 탐색 어댑터와 탐색 계측 | 완료 |
| `hts-binding.ps1` | 역할 locator, claimed HWND, 승인 physical binding 연결 | 완료 |
| `hts-action.ps1` | UIA3 selector·입력·클릭·선택과 검증된 fallback 결과 | 완료 |
| `hts-observation.ps1` | 원시 메시지·대화상자·오류코드·기대 증거 정규화 | 완료 |
| `hts-safety.ps1` | 프로세스·창·콘텐츠 입력 경계, 소유권과 감사 증거 | 완료 |
| orchestration | 위 모듈의 순서와 결과 조립 | 모든 추출이 끝난 뒤 최종 축소 |

이번 단계의 Session/Navigation 모듈은 명시적 context와 dependency 객체를 받고 결과를 반환한다. 판정, TestResult 생성, 리포트 파일 생성은 포함하지 않는다. 기존 함수명은 주 실행기의 얇은 호환 어댑터가 유지하여 실행 의미를 고정한다.

## 6. 변경 안전 기준

- Approved TestPack 검증과 Runner 진입 계약을 유지한다.
- 미실행 dry-run은 계속 `PENDING`이며 FlaUI 동작 시도는 0이어야 한다.
- 실제 HTS 및 상태 변경 동작은 실행하지 않는다.
- 모듈 하나를 이동할 때마다 .NET 테스트, PowerShell 회귀 테스트, PowerShell Parser, Approved TestPack dry-run 안전망을 실행한다.
- 모듈은 raw session/navigation 결과만 반환하고 PASS/FAIL/PENDING 판정 또는 보고서를 생성하지 않는다.

## 7. 이번 단계 추출 결과

- `hts-session.ps1`로 FlaUI 브리지 시작·요청·종료와 HTS 메인 창 탐색·대기를 이동했다.
- `hts-navigation.ps1`로 화면 열기·식별·포커스·연계 화면 계산·업무 화면 종료 순서를 이동했다.
- 두 모듈은 `$script:` 또는 `$global:` 상태를 사용하지 않고 context와 dependency adapter만 받는다.
- `rule-control-exploration.ps1`의 live control 실행 경로는 `NavigationContext`를 명시적으로 받는다. 기존 `activeHtsMainHwnd`, `Get-HtsScreenNumber`, `Focus-HtsRequestedScreen` 역참조를 제거했다.
- `run-target-rule-suite.ps1`에는 기존 내부 호출 계약을 보존하기 위한 Navigation 호환 어댑터와 dependency 조립이 남아 있다. Discovery/Binding/Action/Observation/Safety 추출 전까지 최종 orchestration-only 상태는 `PENDING`이다.
- 주 실행기는 3,426줄에서 3,273줄로 감소했다. `rule-control-exploration.ps1`은 이번 단계에서 Navigation 의존성만 명시화했으며 Discovery/Binding/Action 본체 이동은 하지 않았다.

### Discovery 단계

- `hts-discovery.ps1`이 FlaUI UIA3 원시 요소 수집과 MAP/룰 탐색 호출 경계를 소유한다.
- 탐색 횟수, 발견 요소 수와 fallback 사유는 명시적 `Metrics` 객체에 기록되며 탐색 모듈은 `$script:` 상태를 사용하지 않는다.
- 주 실행기와 기존 rule-control 구현 사이에는 context 기반 어댑터만 남겼다. 탐색 모듈은 판정, `TestResult` 생성 또는 리포트 파일 작성을 하지 않는다.

### Binding 단계

- `hts-binding.ps1`이 역할 locator 해석, claimed HWND 계산, 조회 컨트롤 수집과 승인된 physical binding identity 검증을 소유한다.
- Binding은 명시적 Discovery context와 창 열거·실행 적격성 dependency를 받으며 `$script:` 상태를 사용하지 않는다.
- identity가 승인 계획과 다르면 기존 계약대로 `PHYSICAL_BINDING_DRIFT`와 `PENDING`을 보존한다. UI 입력과 최종 결과 판정은 수행하지 않는다.

### Action 단계

- `hts-action.ps1`이 UIA3 selector 생성, 의미 동작 요청, 검증 여부와 fallback 사유 계측을 소유한다.
- rule-control의 plan item·dataset variable 실행은 Action context dependency로 호출되며 주 실행기가 해당 함수의 내부 분기를 직접 해석하지 않는다.
- Action 모듈은 UI 동작의 원시 성공·검증·오류 정보만 반환하고 테스트 상태 판정과 리포트 생성을 수행하지 않는다.

### Observation 단계

- `hts-observation.ps1`이 MAP 메시지, 설치 오류코드, 시스템·입력 검증 문구를 원시 event type과 증거 객체로 정규화한다.
- 케이스별 required expectation, signal group, sequence 상태는 명시적 Observation context에 보존되며 기존 `$script:` 공유 상태를 제거했다.
- 모듈은 평가 입력용 Observation만 만들고 ResultEvaluator 호출, 최종 테스트 상태 선택 또는 리포트 파일 쓰기를 수행하지 않는다.

### Safety 단계

- `hts-safety.ps1`이 HTS PID·메인 HWND, 활성 콘텐츠 표면, 클릭·키보드·물리 커서 소유권 경계를 명시적 context로 관리한다.
- 기존 `$script:` 입력 표면과 audit path 공유 상태를 제거했으며, 허용·차단 조건과 오류 코드는 그대로 유지했다.
- Action과 Navigation은 Safety 어댑터를 통해서만 입력 경계를 등록·검증하며, Safety 모듈은 업무 동작이나 테스트 판정을 수행하지 않는다.

검증 결과:

- .NET 빌드: 경고 0, 오류 0
- .NET 단위 테스트: 91/91 PASS
- 기존 PowerShell 회귀: pipeline status 23, evaluator golden 8, TestPack Runner 14 PASS
- 신규 PowerShell 회귀: Session 14, Navigation 15, characterization 11 PASS
- PowerShell Parser: 34개 파일 PASS
- Approved TestPack dry-run: C#과 PowerShell Runner CaseId 순서 동일, 결과 `PENDING`, FlaUI action attempt 0

`scripts/dev/verify-source-layout.ps1`은 기존 범위 밖인 `scripts/import-0101-testcases.ps1:7`의 target-specific production 기본값을 계속 지적한다. 이번 단계에서는 해당 파일을 수정하지 않았다.
