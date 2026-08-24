# 주문화면 상태별 control discovery 기준

## 현재 기준선

이 단계의 상태 discovery는 실제 HTS를 조작하지 않는 offline 계약과 fake 실행으로만 검증한다. `targets/1q-hts/0101/target-profile.json`에 이미 있던 `statefulControls` option 세 건을 상태 후보로 연결했지만, 승인된 semantic locator, arrival Checkpoint, baseline state 및 restore action이 없으므로 `stateGraph.configurationStatus`와 각 상태는 `ConfigurationRequired`다. 승인된 transition은 0건이다.

| 설정에 있던 후보 | 기존 근거 | MAP/mapHost 근거 | 현재 상태 | 승인 transition |
|---|---|---|---|---:|
| `buy` / `order-tab:buy` | `statefulControls[0].options[0]` | `HT010115` / `0101\|HT010115` | ConfigurationRequired | 0 |
| `sell` / `order-tab:sell` | `statefulControls[0].options[1]` | `HT010115` / `0101\|HT010115` | ConfigurationRequired | 0 |
| `modify-cancel` / `order-tab:modify-cancel` | `statefulControls[0].options[2]` | `HT010115` / `0101\|HT010115` | ConfigurationRequired | 0 |

이 표는 실제 단말에서 세 상태의 도착과 control 구성을 확인했다는 뜻이 아니다. 이름, MAP 연결 및 control logical name은 체크인된 TargetAdapter 설정의 후보를 그대로 인용한 것이며, 실제 상태별 control 수와 executable locator 수는 모두 PENDING이다. `사내 단말 화면 테스트 체크리스트 정제본.pdf`는 State Graph 근거로 사용하지 않는다.

## 책임 경계

- Core의 `States/StateDiscovery.cs`는 화면 독립적인 `StateGraph`, `StateContext`, `StateTransition`, `ArrivalCheckpoint`, `RestorePolicy`, 상태별 결과와 정책 검증을 소유한다. final submit, amend submit, cancel submit, trade confirmation, transactional/prohibited risk 및 coordinate locator를 등록 단계에서 거부한다.
- FlaUI의 `observeState`는 현재 HWND의 UIA root, process ID, DPI, bounds 및 window fingerprint를 읽기만 한다. 상태명을 정하거나 action을 실행하지 않는다.
- 0101 TargetAdapter는 근거가 있는 상태 후보, MAP/mapHost key 및 향후 승인될 transition/restore 설정만 소유한다. 현재는 후보만 있고 transition과 baseline은 비어 있다.
- `scripts/modules/hts-state-discovery.ps1`은 의존성을 주입받아 상태 순회, 전환 전 재관측, timeout, 상태별 evidence와 baseline restore를 조정한다. 화면별 literal, 파일 저장 및 verdict 판정은 하지 않는다.
- Reporting은 선택적인 `state-discovery-results.json`을 읽어 `상태탐색` 표시 행으로 전달한다. 상태나 restore 결과를 다시 계산하지 않으며 action 전달만으로 기록된 `SUCCESS`와 증거 없는 `FAILED`를 계약 오류로 거부한다.

## 전환과 복구의 fail-closed 조건

실행 가능한 transition에는 source/target, source-state precondition, TargetAdapter의 논리 control identity와 연결된 `targetControlId`, allowlist와 승인 근거가 있는 semantic locator action, required arrival Checkpoint, timeout, 안전한 restore action, risk class 및 evidence requirement가 모두 있어야 한다. `targetControlId`가 주문·정정·취소 명령 control로 등록돼 있으면 action kind를 바꾸어도 transition 등록을 거부한다. action 전달 성공과 action 자체의 readback은 상태 도착 증거가 아니다. arrival Checkpoint가 충족되지 않거나 timeout이면 해당 상태 결과는 `FAILED`이며 screenshot과 UI tree를 남긴다.

순회 종료 시 baseline이 이미 확인된 경우를 제외하고 deterministic restore action과 별도 baseline arrival Checkpoint를 사용한다. restore 성공·실패·PENDING은 상태 discovery 결과와 분리한다. restore 실패도 failure category, screenshot 및 UI tree를 보존한다. configuration-required 그래프는 어떤 UI dependency도 호출하지 않고 모든 후보와 restore를 `PENDING`으로 반환한다.

## 상태별 control 측정 방법

실제 승인 실행에서 생성될 `state-discovery-results.json`만 현재 수치의 근거로 사용한다. 각 상태의 `controls`를 `stateContextId`별로 분리하고 다음 규칙으로 집계한다.

- `executable=true`: 해당 상태가 active이고 visible/enabled이며 승인된 High-confidence locator가 있는 control만 계산한다.
- 다른 상태에서만 visible한 같은 identity: 현재 상태의 executable control로 승격하지 않고 state-dependent control로 분류한다.
- 모든 상태에서 없거나 hidden인 MAP control: unbound와 hidden을 분리한다. 다른 상태에서 발견됐다는 실제 결과가 없으면 “비활성 상태 때문에 누락”으로 추정하지 않는다.
- 동일 HWND/UIA/MAP/runtime identity라도 `stateContextId`가 다르면 별도 관측으로 유지한다.

결과 파일이 있을 때 상태별 수치는 다음 읽기 전용 명령으로 재산출한다.

```powershell
$result = Get-Content -LiteralPath <report-dir>\state-discovery-results.json -Raw -Encoding UTF8 | ConvertFrom-Json
$result.states | ForEach-Object {
  [pscustomobject]@{
    State = $_.stateContext.stateContextId
    Status = $_.status
    Controls = @($_.controls).Count
    Executable = @($_.controls | Where-Object executable).Count
    Screenshot = $_.screenshotRef
    UiTree = $_.uiTreeRef
  }
}
$result.restore
```

## Offline 검증 명령

```powershell
$env:DOTNET_CLI_HOME = Join-Path (Get-Location) '.dotnet-home'
dotnet test .\tests\HtsQa.Tests\HtsQa.Tests.csproj -c Release --filter "FullyQualifiedName~StateDiscoveryTests|FullyQualifiedName~TargetAdapterTests|FullyQualifiedName~ObserveState_Returns_ReadOnly_Window_Fingerprint_Without_Action"
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\PowerShell\hts-state-discovery.tests.ps1
node .\tests\reporting\rule-results-contract.tests.mjs
```

전체 Windows 회귀는 `.github/workflows/windows-regression.yml`과 같은 순서로 solution build/test, 모든 `tests/PowerShell/*.tests.ps1`, Node syntax와 importer/reporter contract를 실행한다. 이 검증은 WinForms fake/UIA fixture만 사용하며 실제 HTS, 계좌 로그인, 주문 입력 또는 거래 action을 실행하지 않는다.

## 실제 Windows 단말에서만 확인할 항목

- 현재 보이는 0101 상태를 식별할 approved arrival Checkpoint
- 각 후보 상태의 실제 MAP/mapHost client rect, process ownership, DPI/window fingerprint
- locator source와 confidence를 승인할 반복 관찰 증거
- 비거래 상태 전환 allowlist와 전환 전 process/window/state 재확인
- 상태별 screenshot/UI tree 및 control 수, hidden/active 구분
- 결정적인 baseline state와 locator 기반 restore 경로
- 실패가 AUTOMATION 또는 ENVIRONMENT 중 어디에 해당하는지 판단할 실제 증거

이 항목들이 승인되기 전에는 현재 보이는 상태의 읽기 전용 snapshot 외의 실제 전환을 실행하지 않는다. 실제 transactional action count는 항상 0이어야 한다.
