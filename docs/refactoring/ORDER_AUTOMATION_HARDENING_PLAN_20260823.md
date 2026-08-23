# 0101 주문 자동화 하드닝 계획 (0단계 기준선)

## 1. 문서 목적과 기준 시점

이 문서는 0101 주문화면 자동화를 구현하기 전에 저장소의 최신 기준선, 증거 우선순위, 안전 경계, 단계별 완료 조건을 고정한다. 제품 코드 변경 계획을 승인하는 문서이지, 이 문서 자체가 업무 규칙이나 실행 승인을 대신하지 않는다.

- 재점검 일자: 2026-08-24 (Asia/Seoul)
- 요청된 문서명 기준일: 2026-08-23
- 저장소: `https://github.com/RyuChaewon/securities-qa-automation.git`
- 기준 브랜치: `codex/order-screen-hardening`
- 기준 HEAD: `d679b115e970aaab3a3efb9fa96b352fe1696b66`
- 기준 `origin/main`: `d679b115e970aaab3a3efb9fa96b352fe1696b66`
- 분기 상태: 기준 브랜치를 `origin/main`에서 새로 만들었으며, 작성 시작 시점에 두 SHA가 같았다.
- 0단계 작성 범위: 이 문서 한 개만 추가했다. 이후 발견한 FlaUI 회귀 결함의 후속 수정은 13절에 별도로 기록한다.
- 루트 적용 지침: 저장소 작업 트리와 추적 파일에서 `AGENTS.md`를 찾지 못했다. 따라서 저장소 문서와 이 작업 요청의 안전 기준을 적용한다.

이 문서의 숫자는 다음 둘을 구분한다.

1. **현재 HEAD에서 직접 산출한 정적·오프라인 결과**: 현재 코드로 검증, 컴파일 또는 재판정한 값이다.
2. **저장된 2026-08-22 단말 증거를 현재 HEAD로 재판정한 결과**: 바인딩 알고리즘은 현재 코드이지만 UI 캡처 자체는 현재 단말에서 새로 얻은 것이 아니다. 따라서 현재 실화면의 실행 가능성을 확정하지 않는다.

## 2. 근거 우선순위와 사용 제한

업무 정답과 자동화 실행 허용 여부는 아래 우선순위로 판단한다.

| 등급 | 근거 | 허용 용도 | 제한 |
|---|---|---|---|
| 1 | 공식 업무요건, 화면설계서, 버전이 확인된 DGN/JS 규칙 | 업무 기대값, RuleID, 필수 Checkpoint와 판정 조건 정의 | 출처 버전·해시·적용 환경을 기록해야 한다. |
| 2 | 승인 메타데이터와 승인된 TestPack | 실행 대상·입력·locator·금지 동작·Checkpoint의 실행 승인 | 승인 대상의 데이터셋/프로필/locator 해시가 정확히 일치해야 한다. |
| 3 | 통제된 테스트 단말에서 반복 관찰한 화면 증거 | locator 안정성, 화면 상태 전이, 실제 오류문구 확인 | 관찰만으로 업무 규칙을 발명하거나 PASS 기준을 만들 수 없다. |
| 4 | 저장소 코드·테스트·문서 | 현재 구현과 계약, 회귀 여부 확인 | 현재 구현이 곧 업무 정답이라는 뜻은 아니다. |
| 5 | 비공식 메모·체크리스트 등 `ReferenceOnly` 후보 | 공식 근거를 찾기 위한 검색 단서 | 단독으로 기대값, RuleID, 합격 기준 또는 실행 가능한 테스트를 만들 수 없다. |

`사내 단말 화면 테스트 체크리스트 정제본.pdf`는 공식 문서가 아니다. 현재 저장소와 확인한 0101 설치 자료에서는 이 파일을 찾지 못했다. 향후 제공되더라도 등급 5의 `ReferenceOnly` 후보로만 등록하며, 이 PDF만으로 기대값, RuleID, 합격 기준, locator 또는 실행 가능한 테스트를 생성하지 않는다.

현재 확인한 `C:\1QHTS\screen`에는 0101 MAP 19개가 있지만, 0101 업무요건·화면설계서·DGN/JS 원본은 확인되지 않았다. MAP은 물리 컨트롤 후보를 제공할 수 있으나 업무 기대값과 PASS 조건의 단독 근거가 아니다.

## 3. 불변 안전 기준

다음 기준은 1~9단계 전체에서 완화하지 않는다.

- .NET 8, Windows, FlaUI/UIA3와 오프라인 결정론적 실행 구조를 유지한다.
- LLM, 외부 API, 임의 C# 또는 PowerShell 실행을 테스트 실행 경로에 넣지 않는다.
- 실제 화면 ID, 필드명, 업무값, 오류문구, API·DB·로그 endpoint를 추정하거나 발명하지 않는다.
- 승인된 TestPack과 승인 범위에 포함된 locator만 실행한다.
- 임의 데스크톱 절대좌표 클릭, 등록되지 않은 컨트롤 클릭, silent self-healing을 금지한다.
- 운영 또는 실계좌에서는 최종 주문, 정정·취소 제출, 출금·이체를 자동 실행하지 않는다.
- 물리 Action 성공은 업무 결과 PASS가 아니다. PASS에는 별도 필수 Checkpoint 증거가 모두 있어야 한다.
- 미실행, 무증거, 미확정, `ObservationOnly`는 PASS가 될 수 없다.
- 실패 시 screenshot과 UI tree를 보존하고 `AUTOMATION`, `ENVIRONMENT`, `TEST_DATA`, `APPLICATION`, `POLICY`, `UNKNOWN` 중 하나로 분류한다.
- 전면 재작성하지 않는다. 기존 공개 계약과 데이터 호환성을 보존하는 작은 단계로 변경한다.
- 안전 조건이 확인되지 않으면 실행 범위를 넓히지 않고 `PENDING` 또는 `UNRESOLVED`로 남긴다.

## 4. 현재 구조

### 4.1 책임 경계

| 영역 | 현재 주요 위치 | 유지할 책임 |
|---|---|---|
| Core | `src/HtsQa.Core` | 상태, 시나리오, TestPack, Checkpoint, 판정 계약 |
| FlaUI infrastructure | `src/HtsQa.FlaUi` | UIA/Win32 탐색, 물리 동작, 관측 수집 |
| TargetAdapter(0101) | `targets/1q-hts/0101`, `scripts/modules/hts-target-rule-*.ps1` | 0101 화면 상태, MAP, 업무별 locator, 허용·금지 동작 |
| Scripts/CLI | `scripts`, `src/HtsQa.Cli` | 얇은 orchestration, 명령행·파일 입출력 adapter |
| Reporting | `tools/reporting` | canonical `test-results.json` 표시. verdict 재판정 금지 |

### 4.2 우선 검토 파일의 현재 역할

- `docs/refactoring/PENDING_RESOLUTION_20260822.md`: 이전 PENDING 해소 시도, 승인과 실제 Action 실행 여부의 경계를 기록한다.
- `src/HtsQa.Core/Evaluation/ResultEvaluator.cs`: 증거 요구사항, 정책 차단과 verdict 판정을 담당하는 단일 C# 평가기다.
- `src/HtsQa.Core/Scenarios/ScenarioPlanning.cs`: 시나리오 파싱·검증·컴파일뿐 아니라 바인딩 계약과 물리 실행 계획 타입까지 함께 포함한다.
- `src/HtsQa.FlaUi/Automation/FlaUiAutomationEngine.cs`: UIA3/Win32를 통한 탐색, 동작, 변경 상태 확인을 구현한다.
- `targets/1q-hts/0101/tools/import-testcases.mjs`: 0101 자료를 dataset/approval/scenario 후보로 가져오는 결정론적 변환기다.
- `targets/1q-hts/0101/target-profile.json`: 19개 MAP family와 초기 활성 화면을 선언한다.
- `scripts/modules/*.ps1`: discovery, binding, action, observation, safety, reporting, orchestration 책임을 파일 단위로 나눈다.

### 4.3 완료된 모듈화

현재 HEAD에서 확인한 완료 항목은 다음과 같다.

- `scripts/run-target-rule-suite.ps1`는 31줄의 얇은 진입점이며, 함수나 `$script:` 상태를 직접 갖지 않는다.
- 실행 책임은 `scripts/modules`의 discovery, binding, action, observation, safety, reporting, orchestration 모듈로 분리되었다.
- 타깃 문맥은 `scripts/modules/hts-target-rule-context.ps1`과 target profile/adapter/MAP으로 분리되었다.
- TestPack 승인 상태와 데이터셋 스냅샷을 CLI에서 검증하는 계약이 존재한다.
- 판정은 `ResultEvaluator.cs`로 집중되었고 PowerShell 결과 평가는 이 C# 계약을 호출한다.
- Reporter에는 canonical 결과 로더와 view model이 있으며, 표시 계층에서 verdict를 재판정하지 않는 테스트가 있다.

관련 크기는 현재 HEAD 기준으로 다음과 같다.

| 파일 | 줄 수 | 비고 |
|---|---:|---|
| `scripts/run-target-rule-suite.ps1` | 31 | 얇은 진입점 |
| `scripts/modules/hts-rule-suite-orchestration.ps1` | 1,796 | 최상위 흐름이 여전히 집중됨 |
| `scripts/modules/hts-target-rule-discovery.ps1` | 1,219 | discovery 함수 34개 |
| `scripts/modules/hts-target-rule-binding.ps1` | 351 | binding 함수 4개 |
| `scripts/modules/hts-target-rule-action.ps1` | 477 | action 함수 9개 |
| `src/HtsQa.Core/Evaluation/ResultEvaluator.cs` | 336 | 단일 판정 계약 |
| `src/HtsQa.Core/Scenarios/ScenarioPlanning.cs` | 1,345 | 시나리오·바인딩·물리 계획 혼재 |
| `src/HtsQa.FlaUi/Automation/FlaUiAutomationEngine.cs` | 714 | UIA/Win32 동작 구현 |
| `targets/1q-hts/0101/tools/import-testcases.mjs` | 507 | import 변환기 |
| `tools/reporting/rule-results-xlsx-renderer.mjs` | 1,044 | 표시 구현이 큼 |

### 4.4 남은 결합도와 확인된 공백

1. `hts-rule-suite-orchestration.ps1`가 FlaUI 시작, 케이스 반복, 거래 제출 호출, 평가기 호출, 여러 결과 파일 저장을 한 파일에서 조정한다. 모듈을 dot-source했지만 흐름과 상태 소유권은 아직 두껍다.
2. `ScenarioPlanning.cs`가 시나리오 문법, 검증, 컴파일, 바인딩과 물리 실행 계획 계약을 함께 소유한다. 공개 타입 호환성을 지키면서 책임 단위 분리가 필요하다.
3. 추적 중인 `outputs/0101_automation/0101.dataset.json`에는 MAP 19개가 있지만 adapter가 없다. 저장된 승인 TestPack `TP-60f9481064b36a91`의 `datasetSnapshot`에도 adapter가 없다. 실행 시 TestPack에서 adapter를 읽는 현재 경로와 맞지 않는다.
4. 현재 HEAD로 재검증한 generated scenarios 1,159개 중 106개가 `SCENARIO.NO_EFFECT_STEP` 경고를 갖는다. 이 경고가 있는 시나리오는 PASS가 될 수 없다.
5. 저장된 2026-08-22 런타임 캡처는 `flaUiDiscoveryCalls=0`, `flaUiActionAttempts=0`이다. 이 증거만으로 FlaUI locator나 Action 실행 가능성을 확인할 수 없다.
6. 저장 캡처를 재사용해 얻은 high-confidence 후보 5개는 모두 `Win32/MAP` 근거다. UIA3 반복 관찰 근거가 아니며 실행 승인으로 승격할 수 없다.
7. 재판정 결과 실행 가능 후보 6개는 모두 `Click`을 포함한다. 한 건은 `DoubleClick`, `Popup`, `Restore`도 포함한다. 어느 것도 실제 실행하지 않았으며 승인된 locator·환경·Checkpoint가 확인될 때까지 PENDING이다.
8. 승인 TestPack dry-run은 `case-results.json`과 `summary.json` 등을 만들지만 canonical `test-results.json`을 만들지 않았다. dry-run summary에도 `actualScenarioActionsExecuted`가 없다. Reporting 단일 계약과 실제 미실행 표시를 강화해야 한다.
9. 최초 전체 .NET 테스트에서는 95개 중 1개가 실패했다. 후속 분석에서 분리된 ComboLBox 항목의 선택 상태를 실제 소유 콤보의 변경으로 잘못 인정한 거짓 성공 판정이 원인임을 확인했다. 소유 콤보를 재식별해 표시값 변경을 검증하도록 수정한 뒤 현재 회귀 기준선은 95/95 PASS다.

## 5. 현재 실행 가능성 지표

### 5.1 입력과 승인 상태

- 추적 dataset: `outputs/0101_automation/0101.dataset.json`, MAP 19개, adapter 없음.
- 현재 import 산출물: `artifacts/pending-resolution-20260822/current-import/0101.dataset.json`.
- 현재 import 승인: `artifacts/pending-resolution-20260822/current-import/scenario-approval.json`.
  - 상태 `Approved`
  - review decisions 26개 `Resolved`
  - scenario decisions 577개 `Approve`
  - accepted gaps 106개
- 승인 TestPack: `artifacts/pending-resolution-20260822/approved-plan-only-test-pack.json`.
  - ID `TP-60f9481064b36a91`
  - 상태 `Approved`
  - Cartesian 1 case
  - dataset snapshot에 adapter 없음

`artifacts` 아래 파일은 검증용 로컬 산출물이며 제품 소스 변경이 아니다. 이 파일을 승인 원본이나 장기 기준선으로 자동 승격하지 않는다.

### 5.2 정확한 재현 명령

아래 명령은 저장소 루트의 Windows PowerShell에서 실행한다. `.NET` 명령은 저장소 내부의 CLI home을 사용한다.

```powershell
$env:DOTNET_CLI_HOME = Join-Path (Get-Location) '.dotnet-home'

dotnet run --project src/HtsQa.Cli/HtsQa.Cli.csproj -c Release --no-build -- validate-test-pack `
  --file artifacts/pending-resolution-20260822/approved-plan-only-test-pack.json

dotnet run --project src/HtsQa.Cli/HtsQa.Cli.csproj -c Release --no-build -- validate-rule-dataset `
  --file artifacts/pending-resolution-20260822/current-import/0101.dataset.json

dotnet run --project src/HtsQa.Cli/HtsQa.Cli.csproj -c Release --no-build -- validate-generated-scenarios `
  --file artifacts/pending-resolution-20260822/current-import/generated-scenarios.json `
  --dataset artifacts/pending-resolution-20260822/current-import/0101.dataset.json `
  --out artifacts/order-hardening-baseline-20260824/scenario-validation.json

dotnet run --project src/HtsQa.Cli/HtsQa.Cli.csproj -c Release --no-build -- compile-scenarios `
  --file artifacts/pending-resolution-20260822/current-import/generated-scenarios.json `
  --dataset artifacts/pending-resolution-20260822/current-import/0101.dataset.json `
  --approval artifacts/pending-resolution-20260822/current-import/scenario-approval.json `
  --max-cases 2000 `
  --out artifacts/order-hardening-baseline-20260824/compiled-plan.json

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File scripts/plan-scenario-bindings.ps1 `
  -CompiledPlanPath artifacts/order-hardening-baseline-20260824/compiled-plan.json `
  -TestPackPath artifacts/pending-resolution-20260822/approved-plan-only-test-pack.json `
  -ReportDir artifacts/order-hardening-baseline-20260824/binding `
  -RuntimeControlPlanPath artifacts/pending-resolution-20260822/plan-only-reuse/control-plan.json `
  -RuntimeSummaryPath artifacts/pending-resolution-20260822/plan-only-reuse/summary.json

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File scripts/run-target-rule-suite.ps1 `
  -TestPackPath artifacts/pending-resolution-20260822/approved-plan-only-test-pack.json `
  -ReportDir artifacts/order-hardening-baseline-20260824/dry-run `
  -DryRun `
  -SkipExcel
```

컴파일과 바인딩 재판정 명령은 live HTS를 시작하지 않는다. 바인딩 명령은 명시적으로 2026-08-22 저장 런타임 파일을 입력하므로 결과를 현재 단말 캡처로 표현하면 안 된다. dry-run은 MAP 해시와 현재 설치 fingerprint를 읽지만 실제 UI Action을 수행하지 않는다.

### 5.3 현재 HEAD에서 직접 산출한 결과

| 항목 | 실제 결과 |
|---|---:|
| dataset screen | 1 |
| generated scenarios | 1,159 |
| variables | 457 |
| locator requests | 368 |
| required review items | 26 |
| covered controls | 242 |
| covered rules | 56 |
| validation warnings | 106 (`SCENARIO.NO_EFFECT_STEP`) |
| compiled plan ID | `PLAN-5ed8ab481a15` |
| compiled plan SHA-256 | `5ed8ab481a153f90495bb92614112d99ed2f1e210b19297906c625a1261a5e1d` |
| compiled status | `READY_FOR_BINDING` |
| binding requirements | 385 |
| total cases | 1,239 |
| total steps | 6,730 |

`READY_FOR_BINDING`은 실제 실행 준비 완료나 PASS를 뜻하지 않는다. 아직 런타임 binding, 실행 승인, 필수 Checkpoint가 필요하다.

### 5.4 저장된 단말 증거를 현재 HEAD로 재판정한 결과

사용한 저장 증거의 run ID는 `0101-tc-20260822-231024`, 종료 시각은 `2026-08-22T23:12:48.5386695+09:00`이다.

| 저장 런타임 캡처 | 값 |
|---|---:|
| 상태 | `PENDING` / Plan-only |
| runtime controls | 269 |
| control tests | 484 |
| FlaUI discovery calls | 0 |
| FlaUI elements discovered | 0 |
| FlaUI action attempts | 0 |
| MAP models | 19 |
| MAP-defined controls | 204 |
| MAP bound / unbound | 20 / 184 |
| runtime-only controls | 65 |
| installation fingerprint | `af385b348118ad82a0665a74117931c87c973a44eec80b175a78eca5c149eda5` |

현재 HEAD의 binding 판정 결과는 다음과 같다.

| binding 판정 | 값 |
|---|---:|
| runtime evidence reused | `true` |
| status | `PARTIAL` |
| required bindings | 385 |
| high confidence | 5 |
| medium confidence | 15 |
| ambiguous | 0 |
| unbound | 365 |
| execution-eligible bindings | 5 |
| total cases | 1,239 |
| executable candidates | 6 |
| pending approval | 0 |
| pending binding | 1,233 |
| actual control actions executed | `false` |

따라서 이전 참고값인 runtime control 269, required binding 385, high-confidence 5, 총 1,239 case, 실행 가능 후보 6, 실제 FlaUI action 0은 현재 HEAD에서 **재판정으로 재현**되었다. 단, runtime control과 UI 관찰값은 2026-08-22 캡처를 재사용한 것이므로 2026-08-24 현재 실화면 값이 아니다. 실행 가능 후보 6도 실행 승인이나 업무 PASS를 뜻하지 않는다.

승인 TestPack dry-run 결과는 `PENDING`, total 1, pass 0, fail 0, error 0, pending 1, `flaUiActionAttempts=0`이다. 현재 설치의 정적 fingerprint는 저장값과 일치했지만, dry-run은 live UI 상태·locator·Checkpoint를 검증하지 않았다.

## 6. 비파괴 기준 검증

### 6.1 실행 명령

```powershell
$env:DOTNET_CLI_HOME = Join-Path (Get-Location) '.dotnet-home'
dotnet build HtsQaPoc.sln
dotnet test HtsQaPoc.sln

$files = @(Get-ChildItem -LiteralPath scripts -Recurse -File -Filter '*.ps1')
foreach ($file in $files) {
  $tokens = $null; $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
  if ($errors) { throw $errors }
}
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/dev/verify-source-layout.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/dev/verify-refactoring-completion.ps1

$tests = @(Get-ChildItem -LiteralPath tests/PowerShell -File -Filter '*.tests.ps1' | Sort-Object Name)
foreach ($test in $tests) {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test.FullName
  if ($LASTEXITCODE -ne 0) { throw "FAILED: $($test.Name)" }
}

$files = @(Get-ChildItem -LiteralPath tools,tests -Recurse -File -Filter '*.mjs' |
  Where-Object { $_.FullName -notmatch '\\node_modules\\' })
foreach ($file in $files) { node --check $file.FullName }
node tests/reporting/rule-results-contract.tests.mjs
node tests/reporting/rule-results-workbook-golden.mjs
node tests/reporting/repository-hygiene.tests.mjs
```

### 6.2 실제 결과

| 검증 | 결과 |
|---|---|
| `dotnet build HtsQaPoc.sln` | PASS, 경고 0, 오류 0 |
| `dotnet test HtsQaPoc.sln` | PASS, 95/95 |
| 실패 테스트 단독 재실행 | 초기 실패 재현 후 수정본 PASS, 1/1 |
| PowerShell parser | PASS, 43 files, 0 errors |
| source layout | PASS, files 80 |
| refactoring completion | PASS, owners 11, assertions 48 |
| `tests/PowerShell/*.tests.ps1` 전체 | PASS, 22/22 files |
| `tools`, `tests` Node `.mjs` syntax | PASS, 12/12 files |
| Reporter Node tests | PASS, 3/3 test files |

해결한 회귀 테스트:

```text
HtsQa.Tests.FlaUiAutomationEngineTests.Action_Uses_FlaUi_Uia3_Patterns_And_Verifies_Changed_State
tests/HtsQa.Tests/Automation/FlaUiAutomationEngineTests.cs:58
초기 결과: response Success=true/Verified=true, 실제 WinForms SelectedIndex=0
수정 결과: 소유 콤보 값이 바뀌지 않으면 UIA3_COMBO_SELECTION_NOT_APPLIED fallback
```

저장소 전체 .NET 회귀는 통과했다. 이 Sample/Fake 성공은 실제 0101 HTS 동작이나 업무 PASS 증거가 아니며, live 단말·승인 TestPack·Checkpoint에 관한 PENDING 경계는 그대로다.

## 7. 생산환경과 테스트환경의 동작 경계

| 동작 | 운영/실계좌 | 통제된 테스트환경 |
|---|---|---|
| 설치·프로필·MAP·locator 정적 검증 | 읽기 전용이고 별도 승인된 경우만 | 허용 |
| 화면 탐색과 observation | 상태 변경이 없고 별도 승인된 범위만 | 승인 TestPack/locator와 환경 fingerprint 일치 시 허용 |
| 입력, 선택, 일반 버튼 클릭 | 금지 | 승인된 비거래 동작만 허용. 동적 재확인 필수 |
| 임의 좌표 또는 미등록 컨트롤 클릭 | 금지 | 금지 |
| silent self-healing/locator 자동 대체 | 금지 | 금지 |
| 주문 확인창 열기 | 금지 | 별도 승인된 sandbox TestPack에서만 허용, 제출 전 중단 |
| 최종 주문 제출 | 금지 | 기본 금지. 향후 별도 실행 승인과 안전한 sandbox 증거가 있을 때만 독립 단계로 검토 |
| 정정·취소 제출 | 금지 | 기본 금지. 주문과 별도 승인 없이는 실행 금지 |
| 출금·이체 | 금지 | 금지 |
| `-SubmitTransactionalDialogs` | 금지 | 기본 금지. 별도 승인된 sandbox 실행에서만 명시적으로 허용 가능 |

테스트환경 전용 동작도 환경 식별, 승인된 계정 유형, 데이터셋·adapter·TestPack 해시, locator, 사전·사후 Checkpoint가 모두 일치해야 한다. 하나라도 없으면 `POLICY` 또는 `PENDING`으로 중단한다.

## 8. Requirements Coverage Matrix 원칙

Coverage Matrix는 케이스 수가 아니라 공식 요구사항과 관측 증거가 어떻게 연결되는지 추적한다. 각 행은 최소한 아래 필드를 가져야 한다.

| 필드 | 의미 |
|---|---|
| Requirement ID / RuleID | 공식 출처의 식별자. 없으면 새로 발명하지 않고 `UNRESOLVED` |
| Source class | Official, ApprovedMetadata, RepeatedObservation, ImplementationEvidence, ReferenceOnly |
| Source version/hash | 출처 버전, 파일 해시, 승인 시점 |
| Screen/state | 승인된 0101 화면 상태 식별자 |
| Preconditions/test data | 승인된 입력과 환경 조건 |
| Locator ID | target adapter에 등록되고 승인된 locator |
| Allowed action | 해당 환경에서 허용된 동작 |
| Forbidden action | 제출·좌표 클릭 등 명시적 금지 동작 |
| Required checkpoints | PASS 전에 반드시 수집할 독립 증거 |
| Expected result | 공식 근거가 있는 값 또는 문구만 기록 |
| Evidence artifact | screenshot, UI tree, 관측값, 실행 로그의 위치와 해시 |
| Verdict rule | Core 평가 계약의 규칙 |
| Coverage status | Covered, Partial, Gap, ObservationOnly, ReferenceOnly, Unresolved |
| TestPack/case ID | 승인된 실행 단위와의 연결 |

분리 원칙:

1. `Official`과 해시가 일치하는 `ApprovedMetadata`만 실행 가능한 기대값과 Checkpoint를 정의할 수 있다.
2. `RepeatedObservation`은 locator와 상태 전이 확인을 보강하지만 공식 업무 기대값을 대체하지 않는다.
3. `ImplementationEvidence`는 코드가 현재 무엇을 하는지 설명할 뿐 요구사항의 정당성을 증명하지 않는다.
4. `ReferenceOnly`는 별도 표 또는 별도 섹션에 두고 Coverage 분자에 포함하지 않는다.
5. 저신뢰 후보와 승인 행을 자동 병합하지 않는다. 사람이 근거를 검토하고 새 승인 메타데이터를 발급해야 승격된다.
6. 근거가 충돌하면 높은 등급을 우선하되, 자동으로 덮어쓰지 않고 출처·버전 충돌을 `UNRESOLVED`로 기록한다.
7. 미확정 expected result, 누락 Checkpoint 또는 미승인 locator가 있는 행은 TestPack에 포함해도 실행 가능 상태가 될 수 없다.

## 9. 1~9단계 실행 계획

### 1단계 — 근거 레지스트리와 Coverage 계약 고정

- 범위: 공식 업무요건, 화면설계서, DGN/JS, MAP, 승인 메타데이터, 반복 관찰, ReferenceOnly 후보를 등급·버전·해시와 함께 등록한다. Coverage Matrix 스키마를 Core 계약으로 정의한다.
- 의존성: 0단계 기준선.
- 완료 조건:
  - 모든 Requirement/Rule 행이 출처 등급과 해시를 가진다.
  - 공식 식별자가 없는 규칙은 발명하지 않고 `UNRESOLVED`다.
  - ReferenceOnly 후보가 승인 Coverage와 물리적으로 분리된다.
  - 공식 문서 부재와 충돌이 기계 판독 가능한 gap으로 보고된다.

### 2단계 — 0101 TargetAdapter, dataset, TestPack 정합성 복구

- 범위: dataset snapshot에 실제 adapter, 19개 MAP과 locator allowlist를 포함하고, source hash에 묶인 새 승인 메타데이터와 최소 TestPack을 만든다.
- 의존성: 1단계의 출처·Coverage ID.
- 완료 조건:
  - 추적 dataset, target profile, adapter, MAP hash가 일치한다.
  - adapter가 없는 기존 TestPack은 실행 불가 사유를 명시한다.
  - 새 TestPack은 환경·screen/state·locator·Checkpoint·금지 동작을 명시한다.
  - 승인자는 정확한 payload와 해시를 확인하고 별도 승인한다.

### 3단계 — Core 상태·Checkpoint·판정 계약 하드닝

- 범위: Action 결과, observation, 필수 Checkpoint, 정책 차단, 실패 분류와 verdict를 분리한다. `ScenarioPlanning.cs`의 책임은 공개 계약을 유지하면서 작은 파일 단위로 분리한다.
- 의존성: 1~2단계 계약.
- 완료 조건:
  - Action success 단독으로 PASS가 되는 경로가 없다.
  - 미실행·무증거·ObservationOnly는 항상 PASS가 아니다.
  - 필수 Checkpoint 누락은 구체적인 PENDING/FAIL 사유를 갖는다.
  - 기존 golden/unit 계약과 새 부정 테스트가 모두 통과한다.

### 4단계 — discovery와 binding 하드닝

- 범위: UIA3/Win32/MAP 근거를 분리 기록하고, 동적 재탐색·창 식별·설치 fingerprint·locator allowlist를 강제한다. fallback은 명시적이고 가시적이어야 한다.
- 의존성: 2단계 adapter, 3단계 증거 계약.
- 완료 조건:
  - 각 binding에 engine, locator 출처, confidence, 관찰 시각과 runtime identity가 있다.
  - 임의 좌표, 미등록 컨트롤, silent self-healing 경로가 없다.
  - stale snapshot은 current-live로 표시되지 않는다.
  - 탐색 실패가 screenshot, UI tree와 분류 코드를 남긴다.

### 5단계 — Action과 안전 정책 하드닝

- 범위: 승인된 binding만 물리 Action으로 변환하고, 실행 직전 locator/창/환경을 재확인한다. 생산환경 금지 동작과 거래 동작의 기본 거부를 코드·설정·테스트에서 일치시킨다.
- 의존성: 3~4단계.
- 완료 조건:
  - 승인 범위 밖 Action은 실행 전에 `POLICY`로 차단된다.
  - 클릭 대상은 실행 직전 재식별되고 예상 상태를 만족한다.
  - 운영/실계좌에서 주문·정정·취소·출금·이체 제출이 불가능하다.
  - transactional submit은 기본 꺼짐이며 별도 승인 없이는 켤 수 없다.

### 6단계 — Observation과 Checkpoint 수집 하드닝

- 범위: 사전·사후 상태, 오류 메시지, 팝업, UI tree, screenshot과 필요한 승인된 외부 관측을 Checkpoint 증거로 수집한다.
- 의존성: 3~5단계.
- 완료 조건:
  - 각 PASS 가능한 케이스에 최소 필수 Checkpoint 집합이 있다.
  - Action과 observation 타임라인 및 상관관계 ID가 보존된다.
  - 실패가 여섯 분류 중 하나를 가지며 증거 파일 해시가 기록된다.
  - 증거가 없거나 서로 모순되면 PASS가 아니다.

### 7단계 — 시나리오와 승인 TestPack 커버리지 정제

- 범위: Coverage Matrix에서 승인 케이스를 생성하고 no-effect 시나리오를 해소한다. assertion-only, 비거래 Action, 거래 확인창, 제출 후보를 서로 다른 TestPack으로 분리한다.
- 의존성: 1~6단계.
- 완료 조건:
  - `SCENARIO.NO_EFFECT_STEP` 106개가 공식 근거에 따라 수정·제외·gap 처리된다.
  - Coverage 행과 case가 양방향 추적된다.
  - assertion-only smoke pack이 실제 Action 없이 기대대로 판정된다.
  - 거래성 TestPack은 별도 승인 없이는 실행 불가다.

### 8단계 — 얇은 orchestration과 canonical reporting 완성

- 범위: orchestration은 상태 전이와 adapter 호출만 담당하게 줄이고, dry/live 모두 canonical `test-results.json`을 만든다. Reporter는 파일을 읽어 표시만 한다.
- 의존성: 3~7단계 계약 안정화.
- 완료 조건:
  - 모든 종료 경로에 canonical `test-results.json`이 있다.
  - `actualScenarioActionsExecuted`와 실제 Action count가 명시된다.
  - Reporter가 verdict를 변경하지 않는 계약 테스트가 통과한다.
  - 중단·재시도·부분 실패에서도 artifact manifest와 원자적 출력이 유지된다.

### 9단계 — 실제 Windows 테스트 단말 단계적 검증과 릴리스 기준

- 범위: 정적 검증 → fake/sample → PlanOnly discovery → assertion-only test 환경 → 비거래 Action → 주문 확인창 진입 후 미제출 순으로 확대한다. 최종 제출은 별도 프로젝트 승인 없이는 포함하지 않는다.
- 의존성: 1~8단계 통과와 실제 테스트 단말·승인 계정.
- 완료 조건:
  - 현재 설치 fingerprint와 live UIA3 discovery를 새로 캡처한다.
  - 승인 locator가 반복 실행에서 안정적이고 실패 시 증거가 보존된다.
  - 필수 Checkpoint가 실제 화면에서 수집되어 Core가 동일 결과를 재현한다.
  - 생산환경 금지 정책을 부정 테스트로 확인한다.
  - 실행하지 않은 주문 제출은 `PENDING`으로 명시하고 PASS로 보고하지 않는다.

## 10. 실제 Windows 단말에서만 확인할 항목

다음 항목은 오프라인 컴파일, MAP 또는 저장 캡처만으로 확정할 수 없다.

- 현재 설치에서 0101 창의 실제 UIA3 tree와 안정적인 window identity.
- 화면 상태별 AutomationId, Name, ControlType, pattern과 동적 변화.
- 승인 locator가 재시작, 팝업, 포커스 변화 후에도 동일 대상을 찾는지 여부.
- 실제 업무 입력값과 오류문구. 공식 근거가 확보되기 전에는 기록하지 않는다.
- 주문 전·후 필수 Checkpoint와 PASS 기대값.
- 계정이 실계좌인지 승인된 테스트/sandbox 계정인지 판별하는 확실한 방법.
- 거래 확인창과 최종 제출 컨트롤의 구분, 그리고 제출 없이 안전하게 복귀하는 경로.
- screenshot/UI tree 수집이 민감정보를 안전하게 처리하는지 여부.
- 승인된 경우에만 사용할 API·DB·로그 관측 endpoint와 접근 정책.
- 실제 FlaUI Action의 성공률, 실패 분류, 반복성. 저장 캡처에는 Action 시도가 0회다.

## 11. 다음 단계 진입 전 blocker

1. 추적 dataset과 승인 TestPack snapshot에 0101 adapter가 없다. 실행 계약과 입력 payload가 불일치한다.
2. 공식 업무요건·화면설계서·DGN/JS 원본이 확보되지 않았다. 업무 기대값과 RuleID를 확정할 수 없다.
3. 현재 실단말의 새 UIA3 discovery가 없다. 저장 런타임 캡처는 2026-08-22 것이며 discovery call 0회다.
4. high-confidence 후보 5개는 Win32/MAP 근거뿐이고, 실행 가능 후보 6개는 모두 Click을 포함한다. 승인된 Action으로 간주할 수 없다.
5. generated scenarios 1,159개 중 106개가 no-effect 경고다.
6. dry-run이 canonical `test-results.json`과 `actualScenarioActionsExecuted`를 항상 제공하지 않는다.

위 blocker를 무시하고 Click 또는 거래 흐름을 실행하지 않는다. 1단계는 읽기·계약·근거 정리로 시작하고, 실제 Action은 앞 단계 완료 조건과 별도 승인이 모두 충족된 뒤에만 확대한다.

## 12. 0단계 완료 판정

0단계에서 완료할 수 있는 범위는 저장소 기준선, 현재 구조, 재현 명령, 검증 결과, 안전 경계와 1~9단계 완료 조건을 문서화하는 것이다. 다음은 완료로 간주하지 않는다.

- 실제 0101 FlaUI Action 실행: 미실행
- 주문·정정·취소 제출: 미실행, PENDING
- 현재 live binding 확인: 미실행
- 업무 규칙 및 expected result 확정: 공식 근거 부재로 UNRESOLVED
- 저장소 전체 .NET 회귀 검증: 95/95 PASS

따라서 이 문서의 완료는 제품 자동화가 사용 가능하거나 주문 테스트가 PASS했다는 뜻이 아니다. 후속 단계는 각 단계의 증거와 안전 게이트를 독립적으로 통과해야 한다.

## 13. 후속 FlaUI 회귀 결함 해소 (2026-08-24)

- 원인: `SelectionItem.IsSelected`는 분리된 WinForms ComboLBox 항목에서 true였지만 실제 소유 콤보의 값과 `SelectedIndex`는 바뀌지 않았다. 엔진이 이 항목 자체 상태를 `Verified=true`의 충분한 근거로 사용해 거짓 성공을 반환했다.
- 제품 수정: `selectIndex`와 `selectText`가 Action 뒤 원래 selector로 소유 콤보를 재식별하고, 실제 표시값이 기대값으로 바뀐 경우에만 성공하도록 강화했다. 바뀌지 않으면 `UIA3_COMBO_SELECTION_NOT_APPLIED`, `FallbackRequired=true`, `Verified=false`를 반환한다.
- 테스트 수정: 환경에 따라 실제 선택 성공 또는 명시적 fallback을 허용하되, 성공이면 목표 `SelectedIndex`, fallback이면 목표 인덱스로 바뀌지 않았음을 실제 WinForms 컨트롤에서 검증한다.
- 검증: 대상 테스트 1/1 PASS, 전체 `dotnet test HtsQaPoc.sln` 95/95 PASS.
- 안전 영향: UIA 항목 패턴 호출만 성공하고 업무 컨트롤 상태가 바뀌지 않은 경우를 성공으로 가장하지 않는다. 실제 HTS Action은 실행하지 않았다.
