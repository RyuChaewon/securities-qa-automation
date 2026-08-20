# HTS QA 자동화 리팩터링 기준선

작성일: 2026-08-19 (Asia/Seoul)
분석 기준: [`68d4b0abe2a6052ecff93ec4f816d42dd4c9494e`](https://github.com/RyuChaewon/securities-qa-automation/commit/68d4b0abe2a6052ecff93ec4f816d42dd4c9494e)
대상 저장소: `RyuChaewon/securities-qa-automation`

이 문서는 운영 로직을 변경하지 않고 현재 진입점, 책임 배치, 중복, 상태 계약과 안전하게 재현한 검증 결과를 고정한다. 파이프라인 완료와 테스트 성공은 별개이며, 실제로 실행하지 않은 케이스는 `PASS`로 기록하지 않는다.

## 1. 저장소와 기준 커밋 상태

- 저장소 안에는 `AGENTS.md`가 없다.
- 로컬 Git 저장소는 `main` 브랜치의 unborn 상태로 `HEAD`가 없고 remote도 등록되어 있지 않다.
- 로컬 파일은 모두 untracked로 보이므로 Git만으로 기존 사용자 변경과 기준 커밋의 차이를 전체 판별할 수 없다.
- GitHub의 기준 커밋은 존재하며 커밋 메시지는 `feat: publish HTS QA automation`이다.
- 아래 분석 핵심 파일 12개는 로컬 Git blob SHA와 기준 커밋의 blob SHA가 모두 일치했다.

| 기준선 일치 파일 | 책임 |
| --- | --- |
| `src/HtsQa.Cli/Program.cs` | CLI 명령 라우팅 |
| `scripts/run-auto-scenario-pipeline.ps1` | 자동 파이프라인 오케스트레이션 |
| `scripts/invoke-scenario-pipeline.ps1` | 외부/수동 단계 파이프라인 |
| `scripts/run-target-rule-suite-recorded.ps1` | 녹화, 실행기, 보고서 결합 |
| `scripts/run-target-rule-suite.ps1` | 런타임 실행과 판정 |
| `scripts/modules/rule-control-exploration.ps1` | 컨트롤 발견, 계획, 조작 어댑터 |
| `scripts/modules/pipeline-common.ps1` | manifest, 경로, 대상 context 공통 처리 |
| `scripts/export-rule-results-xlsx.ps1` | 상세 결과 Excel 진입점 |
| `scripts/export-tc-results-xlsx.ps1` | TC 결과 Excel 진입점 |
| `tools/build-rule-results-workbook.mjs` | 상세 결과 workbook 생성 |
| `tools/build-tc-results-workbook.mjs` | TC workbook 생성 |
| `config/pipeline.manifest.json` | 공개 진입점과 단계 연결 |

이번 작업에서 만든 저장소 파일은 이 문서 하나뿐이다. 다만 로컬 Git 메타데이터가 정상 checkout 상태가 아니므로, 현재 환경에서는 이 문서만 나타나는 통상적인 `git diff` 또는 커밋 후보 상태를 증명할 수 없다. `.git` 복구나 재-clone은 사용자 변경을 침범할 수 있어 수행하지 않았다.

## 2. 안전 및 판정 기준

- 검증 범위는 정적 검사, 단위/통합 테스트, dry-run, Sample/Fake로 한정한다.
- 실제 HTS의 주문, 매수, 매도, 정정, 취소, 이체, 출금 등 상태 변경 동작은 실행하지 않는다.
- 실제 HTS UI를 열거나 관찰해야 하는 `PlanOnly`, `PrepareOnly`, recorded/live 단계도 이번 기준선 검증에서는 실행하지 않는다.
- 실행 증거가 없거나 관찰이 부족하면 `PENDING`으로 둔다. 현재 공개 최상위 테스트 상태에는 `UNRESOLVED`가 없으므로 미해결 바인딩/검토는 `PENDING`과 이유 코드, `Unbound`, `Review`로 표현된다.
- 승인된 TestPack이 아닌 입력은 실행할 수 있어야 한다는 목표와 달리, 현재 코드에는 `TestPack`이라는 명시적 계약이 없다. 현재의 가장 가까운 계약은 generated source + approval overlay + compiled plan + binding catalog + physical plan이다.

## 3. 실제 진입점과 실행 흐름

### 3.1 Manifest 기준 공개 연결

`config/pipeline.manifest.json`은 다음 공개 진입점과 공유 모듈을 연결한다.

| Manifest 역할 | 실제 파일 |
| --- | --- |
| automaticPipeline | `scripts/run-auto-scenario-pipeline.ps1` |
| externalPipeline | `scripts/invoke-scenario-pipeline.ps1` |
| targetRunner | `scripts/run-target-rule-suite.ps1` |
| recordedRunner | `scripts/run-target-rule-suite-recorded.ps1` |
| recorder | `scripts/record-desktop-frames.ps1` |
| reportExporter | `scripts/export-rule-results-xlsx.ps1` |
| tcReportExporter | `scripts/export-tc-results-xlsx.ps1` |
| bindingPlanner | `scripts/plan-scenario-bindings.ps1` |
| sharedLibraries | `scripts/modules/pipeline-common.ps1`, `rule-control-exploration.ps1`, `report-sanitization.ps1` |

### 3.2 CLI

`src/HtsQa.Cli/Program.cs`가 단일 CLI 진입점이다.

```text
validate-rule-dataset
  -> RuleDatasetValidator

expand-rule-cases
  -> RuleCaseExpander

run-rule-dataset --dry-run
  -> dataset validation -> deterministic case expansion
  -> RuleDryRunExecutor -> summary/case-results/expanded-cases
  -> 모든 실행 결과 PENDING

extract-map-models
  -> 설치/MAP 정적 모델 추출

generate-rule-scenarios
  -> RuleScenarioDeterministicGenerator

validate-generated-scenarios
  -> GeneratedScenarioValidator

create-rule-scenario-approval / create-scenario-approval
  -> approval overlay 생성

compile-scenarios
  -> ScenarioPlanCompiler -> compiled logical plan

plan-scenarios
  -> validation + compile 요약

materialize-scenario-bindings
  -> ScenarioRuntimeBindingPlanner

build-physical-scenario-plan
  -> ScenarioRuntimeBindingPlanner.BuildPhysicalPlan

analyze-run
  -> JSON 결과 요약 분석
```

`run-rule-dataset`은 `--dry-run`이 없으면 거부하며, 실제 HTS 조작 없이 모든 결과를 `PENDING`으로 기록한다.

### 3.3 자동 파이프라인

`scripts/run-auto-scenario-pipeline.ps1`의 현재 순서는 다음과 같다.

```text
manifest/target context 해석
  -> dotnet build Release --no-restore
  -> CLI extract-map-models
  -> StaticOnly가 아니면 targetRunner -PlanOnly -SkipExcel
  -> CLI generate-rule-scenarios
  -> CLI validate-generated-scenarios
  -> CLI create-rule-scenario-approval
  -> CLI compile-scenarios
  -> compiled status가 READY_FOR_BINDING인지 확인
  -> StaticOnly이면 STATIC_PLAN_READY / testOutcome=PENDING 종료
  -> CLI materialize-scenario-bindings
  -> CLI build-physical-scenario-plan
  -> 미완료 바인딩은 PENDING_BINDING
  -> PrepareOnly이면 PHYSICAL_PLAN_READY / testOutcome=PENDING 종료
  -> recordedRunner
  -> 녹화 실행 상태 파일 확인
  -> auto state DONE 또는 ERROR
```

여기서 `PlanOnly`는 시나리오 동작을 실행하지 않지만 실제 HTS 프로세스/화면 접근과 컨트롤 관찰을 수행한다. `StaticOnly`만 실제 HTS UI 접근이 없다.

자동 파이프라인은 recorded runner의 상태를 정확히 `DONE`으로 요구한다. recorded runner가 정상적으로 완료했더라도 테스트 결과가 `FAIL`, `ERROR`, `PENDING`이면 각각 `DONE_WITH_TEST_FAILURES`, `DONE_WITH_TEST_ERRORS`, `DONE_WITH_PENDING`이므로 자동 파이프라인에서는 `ERROR`/`PENDING`으로 변환된다. 이는 파이프라인 완료 상태와 테스트 판정 상태가 결합된 지점이다.

### 3.4 외부/수동 단계 파이프라인

`scripts/invoke-scenario-pipeline.ps1`은 다음 단계를 독립 호출한다.

```text
RequestPackage
  -> MAP/런타임 입력을 외부 시나리오 요청 패키지로 내보냄

ImportAndPlan
  -> 외부 응답 검증/가져오기
  -> approval overlay
  -> compiled logical plan

BindingPlan
  -> plan-scenario-bindings.ps1
  -> targetRunner -PlanOnly
  -> binding catalog + physical plan

Execute
  -> run-target-rule-suite-recorded.ps1
  -> recorder + targetRunner + Excel
```

각 단계의 wrapper 상태는 `COMPLETED`이며, `actualScenarioActionsExecuted`는 `Execute`에서만 참이다. 이 상태는 내부 테스트 성공을 뜻하지 않는다.

### 3.5 Recorded runner

`scripts/run-target-rule-suite-recorded.ps1`은 다음을 결합한다.

```text
선택적 plan refresh
  -> 관리자 권한 child runner 시작
  -> desktop frame recorder 시작
  -> action marker/timeout/launch error 수집
  -> video 인코딩 및 cursor audit
  -> 실패 프레임 추출
  -> rule/TC Excel export
  -> pipelineCompleted + testStatus + overallStatus 계산
```

`pipelineCompleted`와 `testStatus`는 별도 필드이다. `DONE`은 `testStatus=PASS`일 때만 사용되고, 완료했지만 성공이 아닌 경우에는 `DONE_WITH_*`가 사용된다.

### 3.6 Target runner와 FlaUI/UIA3

`scripts/run-target-rule-suite.ps1`은 실제 실행의 중앙 오케스트레이터다.

```text
dataset/target context/설치/MAP preflight
  -> DryRun이면 CLI run-rule-dataset로 종료
  -> FlaUI bridge 프로세스 시작
  -> HTS main window와 화면 찾기/열기
  -> rule-control-exploration 모듈로 발견/계획/바인딩
  -> 입력 보호와 대상 화면 확인
  -> FlaUI.UIA3 우선 조작, 제한된 Win32 fallback
  -> dialog/log/window/control observation 수집
  -> 기대 결과와 관찰 비교
  -> case-results/control-plan/summary/checkpoint 기록
  -> 선택적으로 Excel export
```

`src/HtsQa.FlaUi/Program.cs`는 JSON bridge 요청을 받고, `Automation/FlaUiAutomationEngine.cs`가 UIA3 발견·조작을 수행한다. `scripts/modules/rule-control-exploration.ps1`은 MAP/런타임 컨트롤을 계획하고 실제 runner helper로 관찰과 조작을 위임한다.

현재 runner에는 `ScenarioPlanPath`/`PhysicalPlanPath` 없이 dataset rule을 직접 실행하는 legacy 경로가 남아 있다. 따라서 dry-run이 아닌 직접 호출에 승인된 compiled/physical plan을 강제하는 전역 게이트가 없다. 이는 승인된 TestPack만 실행해야 한다는 목표에 대한 `FIX` 항목이다.

또한 compiler는 승인 대상이나 필수 검토가 없는 generated source를 approval 없이도 `READY_FOR_BINDING`으로 만들 수 있다. runtime의 transaction 동작에는 추가 승인 검사가 있지만 모든 비거래 동작에 동일한 승인 요건이 적용되지는 않는다. 향후 명시적 TestPack 승인 계약을 실행 직전 한 곳에서 강제해야 한다.

### 3.7 결과 리포트

| 단계 | 구현과 산출물 |
| --- | --- |
| 런타임 JSON | `run-target-rule-suite.ps1`: `case-results.json`, `control-plan.json`, `summary.json`, checkpoint |
| 결과 병합 | `merge-target-rule-runs.ps1`: CaseId 기준 병합과 summary 재계산 |
| 보고서 정리 | `sanitize-rule-report.ps1` + `modules/report-sanitization.ps1` |
| 상세 Excel | `export-rule-results-xlsx.ps1` -> `tools/build-rule-results-workbook.mjs` |
| TC Excel | `export-tc-results-xlsx.ps1` -> `tools/build-tc-results-workbook.mjs` |
| 녹화 증거 | `record-desktop-frames.ps1` + 영상/프레임 Python 도구 |
| 결과 재분석 | CLI `analyze-run` |

Node workbook 도구는 summary/cases와 선택적 MAP, compiled plan, binding, physical plan, review 증거를 읽어 여러 sheet를 만들고 preview/formula 검사를 수행한다. runner 자체의 선택적 Excel export와 recorded wrapper의 export가 중복 오케스트레이션이다.

## 4. 책임 위치와 중복 지도

아래 `KEEP/CLEAN/REMOVE/FIX`는 후속 리팩터링 후보 분류이며 이번 단계에서 코드 변경을 뜻하지 않는다.

| 책임 | 주 구현 위치 | 중복/분산 위치 | 기준선 판정 |
| --- | --- | --- | --- |
| Dataset validation | `HtsQa.Core/Datasets/RuleBased.cs`의 `RuleDatasetValidator`; CLI `validate-rule-dataset` | `pipeline-common.ps1`의 target context 검사, target runner preflight, 일부 importer/도구의 독자 검사 | **KEEP** Core 계약. **CLEAN** wrapper는 Core 결과를 소비하고 경로/실행 전제만 검사하도록 축소 |
| Combination generation | `RuleCaseExpander`의 deterministic Cartesian expansion | `run-target-rule-suite.ps1`의 `Get-VariableCombinations`/`Get-RuleCases`; `ScenarioPlanCompiler`의 별도 시나리오별 Cartesian; generator의 per-control 조합 | **CLEAN** 공통 Cartesian/limit 규칙. 단 generator의 전역 조합 폭증 방지 전략은 **KEEP** |
| CaseId generation | `RuleCaseExpander`의 `RC-` 해시; `ScenarioPlanCompiler`의 `SC-` 해시 | runner의 legacy `RC-` 생성 로직 | **CLEAN** 단일 canonical 생성기와 golden test. `RC`/`SC` 의미 차이는 공개 계약으로 **KEEP** |
| TestPack compile/approval | `ScenarioPlanning.cs`의 validator, approval overlay, compiler, binding/physical planner; `RuleScenarioGeneration.cs`의 제한적 auto-approval | auto pipeline과 external pipeline이 단계 순서를 각각 조립; runtime transaction 승인 검사 | 명시적 TestPack 타입/서명이 없음. **FIX** 실행 직전 승인+source/dataset/plan hash+physical READY를 일괄 강제 |
| FlaUI execution | `HtsQa.FlaUi/Automation/FlaUiAutomationEngine.cs` | runner의 bridge 수명주기, UIA/Win32 helper; exploration 모듈의 동작 라우팅 | 엔진과 JSON bridge는 **KEEP**. 수명주기/호출 계약과 fallback 경계는 **CLEAN** |
| Observation collection | runner의 dialog/log/window/control 수집; exploration 모듈의 discovered controls/assertion | MAP oracle, connection dialog, result text, log tail 수집이 runner 여러 구간에 분산 | 원시 증거 보존은 **KEEP**. 공통 observation DTO/collector로 **CLEAN** |
| Result evaluation | runtime의 `Get-HtsSignalJudgment`와 summary 우선순위 | Core `RuleOutcomePolicy.cs`; recorded wrapper와 merge script가 상태를 다시 계산 | **FIX/CLEAN** Core 정책을 단일 기준으로 사용하고 wrapper는 결과를 재해석하지 않도록 함 |
| Reporting | JSON 산출물 + 두 exporter/두 workbook builder | runner와 recorded wrapper의 Excel 호출, merge/sanitize의 summary 재계산 | 증거 파일과 workbook 포맷은 **KEEP**. 중복 export/summary 계산은 **CLEAN** |
| Target-specific behavior | dataset `targetProfile`, `HtsInstallation.cs`, `HtsMap.cs`의 제품 어댑터 | runner/exploration의 Afx, 4자리 화면, F12, 주문 탭/확인창 규칙; `import-0101-testcases.ps1`의 제품 기본값 | 제품 어댑터 경계는 **KEEP**. generic runner의 제품 literal은 **CLEAN**. 생산 기본 경로는 **FIX** |

### KEEP

- `.NET 8`, Windows TFM, FlaUI/UIA3와 오프라인 JSON/PowerShell 실행 구조.
- `RuleDatasetValidator`, deterministic expansion, 실행 증거가 없으면 `PENDING`인 dry-run.
- generated source, approval, compiled plan, binding catalog, physical plan의 해시 기반 산출물.
- 원시 observation과 case/summary/report 증거 분리.
- runtime `ERROR > FAIL > PENDING > PASS` 우선순위와 미관찰 성공 금지 원칙.
- targetProfile/dataset 기반 제품 차이와 `HtsInstallation`/`HtsMap` 어댑터 경계.

### CLEAN

- C#과 PowerShell에 중복된 dataset/Cartesian/CaseId 로직.
- Core `RuleOutcomePolicy`와 runtime PowerShell 판정 정책의 이중 구현.
- runner, recorded wrapper, merge script의 summary/완료 상태 재계산.
- runner와 recorded wrapper의 Excel export 중복.
- auto/external pipeline의 compile/bind 단계 조립 중복.
- generic runtime에 섞인 Afx/주문 탭/제품별 control 규칙.

### REMOVE

- 승인 계획 없이 실제 dataset rule을 직접 실행할 수 있는 legacy live 경로. 후속 단계에서는 제거하거나 `DryRun`/`PlanOnly` 전용으로 제한한다.
- wrapper가 하위 테스트 상태를 다시 추측해 다른 의미로 바꾸는 경로. 하위 결과 계약을 그대로 전달하는 방식으로 대체한다.
- canonical Core 구현이 연결된 뒤 남는 PowerShell Cartesian/CaseId/판정 사본.

### FIX

- 실행 직전 승인된 TestPack 게이트를 단일 지점에서 강제한다.
- auto pipeline의 `DONE` 요구로 pipeline completion과 test outcome이 섞이는 문제를 분리한다.
- `scripts/import-0101-testcases.ps1`의 `C:\1QHTS` 생산 기본값을 명시적 target profile/인자로 이동한다.
- 정적 검사에서 보고된 PowerShell 함수 목적 주석 13건을 보완한다.
- `UNRESOLVED`를 공개 상태로 추가할지, `PENDING` 이유 코드로만 유지할지 계약을 명시한다.

## 5. 현재 상태 값 목록

### 5.1 테스트 및 판정 상태

| 계약 | 가능한 값 | 의미/주의 |
| --- | --- | --- |
| `TestStatus` | `PASS`, `FAIL`, `ERROR`, `PENDING` | 실제 case와 summary의 canonical 상태 |
| 관찰 이벤트 | `Success`, `InputValidation`, `NoData`, `Warning`, `ProductFailure`, `GenericError` | `RuleOutcomePolicy` 입력 |
| 판정 disposition | `Expected`, `Unexpected`, `Defect`, `Review`, `Observed` | `Review`는 성공으로 올릴 근거가 아님 |
| generated validation | `VALIDATED`, `VALIDATED_WITH_WARNINGS`, `INVALID` | compile 전 정적 검증 |
| approval overlay | `Draft`, `Approved`; compiled 기본 `NotProvided` | `Approved`에는 승인자/시간과 필수 결정이 필요 |
| scenario readiness | `ReadyForBinding`, `PendingBinding`, `PendingApproval`, `ManualReview`, `Rejected`, `Invalid` | 개별 논리 시나리오 상태 |
| compiled plan | `READY_FOR_BINDING`, `NEEDS_APPROVAL` | 현재는 모든 source에 명시 승인 필수라는 뜻은 아님 |
| binding item | `BoundHigh`, `BoundMedium`, `Ambiguous`, `Unbound` | 실행 가능은 고신뢰 단일 후보만 |
| binding catalog | `READY`, `INCOMPLETE` | 필수 바인딩 완료 여부 |
| physical scenario | `READY`, `PENDING_APPROVAL`, `PENDING_BINDING` | 개별 물리 disposition |
| physical plan | `READY`, `PARTIAL`, `BLOCKED` | 실행 가능한 case 범위 |

Top-level `UNRESOLVED`는 없다. 현재 미해결 증거는 `PENDING`, `Review`, `Ambiguous`, `Unbound`, `PENDING_BINDING`과 이유 코드로 분산되어 있다.

### 5.2 파이프라인 상태

| 생성 주체 | 가능한 값 |
| --- | --- |
| auto pipeline | `STARTED`, `PENDING_ADMIN_RUNNER_REQUIRED`, `STATIC_PLAN_READY`, `PENDING_BINDING`, `PHYSICAL_PLAN_READY`, `DONE`, `ERROR` |
| external stage wrapper | `COMPLETED` |
| binding-plan summary | `PENDING_RUNTIME_DISCOVERY_ERROR`, `PENDING_HTS_NOT_ACCESSIBLE`, 이후 physical plan의 `READY`/`PARTIAL`/`BLOCKED` |
| action marker | `DONE`, `ERROR`, `PENDING_ADMIN_RUNNER_REQUIRED`, `PENDING_ADMIN_APPROVAL_DECLINED`, `LAUNCH_ERROR` |
| recorded overall | `PENDING_*`, `LAUNCH_ERROR`, `TIMEOUT`, `ERROR`, `REPORT_ERROR`, `CURSOR_AUDIT_ERROR`, `DONE_WITH_TEST_ERRORS`, `DONE_WITH_TEST_FAILURES`, `DONE_WITH_PENDING`, `DONE`, `VIDEO_ERROR` |

recorded 결과의 `pipelineCompleted`, `testStatus`, `testPassed`가 분리되어 있는 구조가 가장 명확한 기준이다. 후속 리팩터링은 이 분리를 상위 wrapper까지 보존해야 한다.

## 6. 기준선 검증 결과

### 6.1 실행한 정확한 명령

#### 빌드

```powershell
$env:DOTNET_CLI_HOME=(Join-Path (Get-Location) '.dotnet-home'); dotnet build .\HtsQaPoc.sln -c Release --no-restore
```

결과: .NET SDK `8.0.401`, 성공, 경고 0, 오류 0, 경과 2.54초.

#### 단위/통합 테스트

```powershell
$env:DOTNET_CLI_HOME=(Join-Path (Get-Location) '.dotnet-home'); dotnet test .\HtsQaPoc.sln -c Release --no-build --no-restore
```

결과: 성공 58, 실패 0, 건너뜀 0, 총 58, 경과 약 33초. 이 중 2개는 격리된 WinForms/FlaUI UIA3 Sample 통합 테스트이고 나머지는 dataset, scenario, planning, outcome의 Fake/정적 테스트다. 실제 HTS 테스트는 아니다.

#### 저장소 정적 레이아웃 검사

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev\verify-source-layout.ps1
```

결과: 종료 코드 1, 정적 레이아웃 검사 실패.

전체 규칙을 같은 파일 집합에 대해 읽기 전용으로 집계한 위반은 14건이다.

- 대상별 생산 기본값 1건: `scripts/import-0101-testcases.ps1:7`의 `C:\1QHTS`.
- PowerShell 함수 목적 주석 누락 13건:
  - `scripts/import-0101-testcases.ps1`: `Resolve-LocalPath`
  - `scripts/run-target-rule-suite.ps1`: `Get-RuleFileSha256`, `Export-RuleResultWorkbooks`, `Set-HtsScreenNumber`, `Test-PreservedTargetScreen`, `Get-HtsConnectionDialogs`, `Set-ScenarioPhysicalBinding`
  - `scripts/modules/rule-control-exploration.ps1`: `Test-RuleControlExecutionEligible`, `Test-RuleOrderTabContext`, `Get-RuleOrderTabItem`, `Set-RuleOrderTabState`, `Get-RuleOrderTabState`, `Get-RuleMapGeometry`

manifest 경로, 내부 module 중복, 파일 역할 헤더, 금지 화면군 literal에서는 추가 위반이 수집되지 않았다.

#### PowerShell 구문 검사

```powershell
$files=@(Get-ChildItem -LiteralPath '.\scripts' -Recurse -File -Filter '*.ps1'); $errors=@(); foreach($file in $files){$tokens=$null;$parseErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors);$errors+=@($parseErrors)}; "POWERSHELL_FILES=$($files.Count) PARSE_ERRORS=$($errors.Count)"; if($errors.Count -gt 0){$errors;exit 1}
```

결과: `POWERSHELL_FILES=24 PARSE_ERRORS=0`, 종료 코드 0.

#### 기존 dry-run

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Users\ch1\Desktop\1QHTS_TEST\scripts\run-target-rule-suite.ps1 -DatasetPath C:\Users\ch1\Desktop\1QHTS_TEST\data\rule-tests\1q-hts-non07-static-smoke.dataset.json -ReportDir C:\Users\ch1\AppData\Local\Temp\hts-refactoring-baseline-dryrun-20260819-210041 -DryRun -SkipExcel
```

결과: 종료 코드 0. `summary.json`은 `status=PENDING`, `total=1`, `pass=0`, `fail=0`, `error=0`, `pending=1`, `dryRun=true`다. `flaUiActionAttempts=0`, `flaUiDiscoveryCalls=0`, `discoveredControls=0`, `popupObservations=0`이며, 실행 모드는 `드라이런 - 실제 HTS 조작 없음`이다.

dry-run은 로컬 설치의 MAP/정적 카탈로그를 읽어 `mapModels=1`, `mapDefinedControls=3`, `integrityMatched=4`를 기록했지만 HTS UI를 열거나 조작하지 않았다. 산출물은 임시 폴더의 `summary.json`, `case-results.json`, `expanded-cases.json`, `control-plan.json`, `map-screen-models.json`이며 Excel은 `-SkipExcel`로 실행하지 않았다.

### 6.2 실제/Fake/미실행 구분

| 구분 | 상태 | 증거 |
| --- | --- | --- |
| 실제 HTS UI 실행 | **미실행 / PENDING** | HTS window 접근, UIA 발견/조작, dialog/log 관찰을 실행하지 않음 |
| 실제 HTS 상태 변경 | **미실행 / 금지 유지** | 주문·매수·매도·정정·취소·이체·출금 실행 0건 |
| Sample/Fake 테스트 | **실행** | `dotnet test`: 58/58 통과. 실제 HTS 성공 증거로 사용하지 않음 |
| 정적 dry-run | **실행 / PENDING** | 1 case, PASS 0, PENDING 1, FlaUI action 0 |
| build | **실행** | 0 warning, 0 error |
| PowerShell parse | **실행** | 24 files, 0 parse errors |
| source layout | **실행 / FAIL** | 위반 14건 |
| PlanOnly/BindingPlan | **미실행 / PENDING** | 실제 HTS 접근이 필요하므로 제외 |
| StaticOnly auto pipeline | **미실행 / PENDING** | 구성 요소 검증은 수행했으나 wrapper 전체는 실행하지 않음 |
| PrepareOnly/recorded/live | **미실행 / PENDING** | 실제 HTS/녹화/관리자 권한 경로이므로 제외 |
| Excel workbook 생성 | **미실행 / PENDING** | dry-run에 `-SkipExcel` 사용 |

## 7. 알려진 중복과 위험

1. **승인 게이트 부재**: legacy runner는 approved compiled/physical plan 없이 live dataset rule 실행이 가능하다. 현재 가장 높은 위험이다.
2. **approval 의미의 빈틈**: 검토 대상이 없는 source는 approval overlay 없이 `READY_FOR_BINDING`이 될 수 있고, 비거래 동작 전체에 승인 확인이 일관되게 적용되지 않는다.
3. **CaseId drift**: C# Core, scenario compiler, PowerShell legacy runner가 각각 identity/hash 입력을 소유한다. 사소한 정규화 차이로 재실행/병합 키가 달라질 수 있다.
4. **조합 규칙 drift**: dataset Cartesian, runner Cartesian, scenario별 expansion, generator의 per-control 전략이 분산되어 limit와 순서가 달라질 수 있다.
5. **판정 정책 drift**: Core `RuleOutcomePolicy`는 테스트되지만 실제 runtime은 PowerShell `Get-HtsSignalJudgment`를 사용한다. 정책 테스트 통과가 runtime 판정 일치를 증명하지 않는다.
6. **상태 계층 혼합**: recorded runner는 completion/outcome을 분리하지만 auto/external wrapper가 이를 다시 단일 상태로 변환한다.
7. **report 재계산**: runner, recorded wrapper, merge script가 summary와 최종 상태를 각각 계산하므로 같은 evidence에 다른 상태가 붙을 수 있다.
8. **target-specific leakage**: generic runner와 exploration module에 Afx/4자리 화면/주문 탭/특정 control 규칙이 남아 있다. `import-0101-testcases.ps1`의 기본 설치 경로는 정적 검사에 실제로 실패한다.
9. **대형 orchestration script**: 실행, 관찰, 판정, 보고가 `run-target-rule-suite.ps1`에 집중되어 작은 변경의 영향 범위가 크다.
10. **Git 증거 불완전**: 로컬 `HEAD`가 없고 모든 파일이 untracked이므로 전체 저장소가 기준 커밋과 같은지, 기존 사용자 변경이 무엇인지 확정할 수 없다.

## 8. 실제 HTS 없이 검증할 수 없는 항목

다음 항목은 이번 기준선에서 모두 `PENDING`이다.

- 설치 fingerprint와 현재 실행 중 HTS의 일치.
- 화면 열기/복원, target screen 활성화와 보존.
- FlaUI/UIA3 실컨트롤 발견, 클릭, 입력, 선택, 체크 상태 검증.
- UIA 실패 시 Win32/좌표 fallback의 실제 안전성과 focus 유지.
- owner-drawn/Afx, order-tab state, MAP state transition의 실제 동작.
- dialog, log, window text, result control observation의 완전성.
- runtime binding의 `BoundHigh` 재현성과 물리 계획의 실제 실행 가능성.
- 영상, cursor audit, 실패 프레임과 case evidence의 시간 정렬.
- 실제 결과 workbook 생성과 시각적 검증.
- 실제 HTS에서의 성공/실패/제품 결함 판정.
- 주문·매수·매도·정정·취소·이체·출금 등 상태 변경 시나리오. 이 항목은 후속 단계에서도 별도 안전 대상과 승인 없이는 실행 금지다.

## 9. 후속 변경 시 계약 영향과 마이그레이션 전제

이번 단계에서는 공개 계약이나 운영 코드를 변경하지 않았다. 후속 단계에서 아래를 바꾸려면 먼저 영향 범위와 마이그레이션 방안을 확정해야 한다.

- 승인 게이트 강화는 기존 `run-target-rule-suite.ps1 -DatasetPath ...` live 호출을 차단한다. 전환안은 `ScenarioPlanPath` + 승인 overlay/hash + `PhysicalPlanPath`를 필수화하고 legacy 호출은 `DryRun`/`PlanOnly`로만 허용하는 것이다.
- CaseId/조합 로직 통합은 기존 JSON, merge, workbook join key에 영향을 준다. 현재 ID를 golden fixture로 고정하고 schema/version migration을 제공해야 한다.
- 결과/파이프라인 상태 분리는 `auto-pipeline-state.json`, `pipeline-state.json`, `녹화실행완료.json` 소비자에 영향을 준다. 기존 필드를 유지하면서 `pipelineStatus`와 `testStatus`를 병행 추가한 뒤 단계적으로 전환해야 한다.
- 판정 정책의 Core 통합은 현재 PowerShell reason/errorCode와 workbook 열에 영향을 줄 수 있다. 같은 observation fixture에 대한 양쪽 결과를 먼저 characterisation test로 고정해야 한다.

이 문서가 이번 단계의 종료점이다. 다음 리팩터링 단계는 자동으로 진행하지 않는다.
