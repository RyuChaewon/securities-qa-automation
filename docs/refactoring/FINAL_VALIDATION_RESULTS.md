# 리팩터링 완료 검증 결과

검증일은 2026-08-22, 최초 비교 기준은 `68d4b0abe2a6052ecff93ec4f816d42dd4c9494e`, 검증 대상 HEAD는 `27369d5`이다. 이 검증에서는 실제 HTS 프로세스나 주문·매수·매도·정정·취소·이체·출금 동작을 실행하지 않았다.

## 결론

- Dataset 조합, 실행 CaseId, TestResult 판정은 각각 C# 단일 구현을 사용한다.
- PowerShell Runner는 `-TestPackPath`만 실행 입력으로 받고, 승인 검증이 FlaUI session 시작보다 앞선다.
- Reporter는 canonical `test-results.json`을 읽어 표시할 뿐 상태 불일치와 안전하지 않은 PASS를 거부한다.
- generic 생산 코드의 target 전용 literal 경계 검사는 69개 파일, 78개 assertion을 통과했다.
- 미실행 dry-run은 `PENDING`이고 FlaUI action 시도는 0이었다.
- 요청된 선형 흐름의 `TargetSnapshot -> DatasetValidator` 연결은 실제 데이터 의존이 아니다. UI Discovery의 `control-plan.json`은 승인 뒤 시나리오 생성·바인딩이 소비하며, DatasetValidator는 원본 Dataset만 소비한다. 승인 전에 UI를 열지 않는 현재 순서가 안전 계약이다.

## 계약과 단일 소유자

| 단계 | 입력 계약 | 출력 계약 | 단일 구현/계약 소유자 | 검증 결과 |
|---|---|---|---|---|
| Discovery | 승인 TestPack의 target profile, 대상 창 snapshot, MAP model | `RuleDiscoveredControl[]` | `scripts/modules/hts-discovery.ps1`; target 의미는 adapter가 주입 | PASS |
| TargetSnapshot | 발견된 control 배열과 화면 식별값 | `RuntimeControlPlanRow[]`, `control-plan.json` | `src/HtsQa.Core/Scenarios/ScenarioPlanning.cs` | PASS; DatasetValidator의 직접 입력은 아님 |
| DatasetValidator | `RuleTestDataset` | `ValidationResult` | `RuleDatasetValidator`, `src/HtsQa.Core/Datasets/RuleBased.cs` | PASS |
| CombinationGenerator | 검증된 Dataset, `CombinationPolicy`, `maxCases` | 결정론적 `RuleTestCase[]` | `CombinationGenerator`, `src/HtsQa.Core/TestPacks/TestPack.cs` | PASS |
| ExpectationResolver | 선택된 변수값별 기대 계약 | `ResolvedExpectedResult` | `ExpectationResolver`, 같은 파일 | PASS |
| CaseId | dataset/screen/account/정렬된 variables | canonical JSON SHA-256 기반 ID | `CaseIdFactory`, 같은 파일 | PASS |
| TestPackCompiler | 검증된 Dataset, source hash, policy, approval overlay | 불변 `RuleTestPack` | `TestPackCompiler`, 같은 파일 | PASS |
| Approved TestPack | `RuleTestPack` | 승인·hash 검증된 고정 cases | `TestPackValidator`와 `TestPackRunnerContract`, 같은 파일 | PASS |
| FlaUI Runner | Approved TestPack cases, 명시적 실행 옵션 | UIA3 action 사실과 raw observation | `HtsQa.FlaUi` 및 `scripts/modules/hts-*-action/session` | PASS: Sample/Fake만 검증 |
| Observation | 실행 사실, 증거, 메시지, source code | `Observation`/`ResultEvaluationDocument` | `src/HtsQa.Core/Evaluation/ResultEvaluator.cs`; 수집은 `hts-observation.ps1` | PASS |
| ResultEvaluator | Observation + ExpectedResult + EvaluationPolicy | 완성된 `TestResult` | `ResultEvaluator`, 같은 C# 파일 | PASS |
| Reporter | canonical `TestResultDocument`와 표시용 실행 문맥 | XLSX와 preview 파생 산출물 | `tools/reporting/*` | PASS |

요청 흐름은 두 의존 lane으로 읽어야 실제 구현과 일치한다.

```text
compile lane:
Dataset -> DatasetValidator -> CombinationGenerator -> ExpectationResolver
        -> TestPackCompiler -> Approved TestPack

execution lane:
Approved TestPack -> FlaUI Runner -> Discovery/TargetSnapshot 및 Action
                  -> Observation -> ResultEvaluator -> TestResult -> Reporter
```

`TargetSnapshot`은 compile lane을 우회하거나 Dataset을 확장하지 않는다. 시나리오 생성·binding에 runtime evidence를 제공하는 승인 이후 산출물이다.

## 중복 전체 검색 결과

| 후보 | 기준선 발생 수 | 현재 독립 구현 | 판정 |
|---|---:|---:|---|
| `Get-VariableCombinations` | 3 | 0 | 제거, `CombinationGenerator`로 대체 |
| `Get-RuleCases` | 2 | 0 | 제거, Approved TestPack `cases` 사용 |
| `Get-HtsSignalJudgment` | 4 | 0 | 제거, CLI `evaluate-results` adapter 사용 |
| `CombinationGenerator` 선언 | 해당 없음 | 1 | C# 단일 소유자 |
| `CaseIdFactory` 선언 | 해당 없음 | 1 | C# 단일 소유자; scenario ID도 `SC` prefix로 같은 factory 호출 |
| `ResultEvaluator` 선언 | 해당 없음 | 1 | C# 단일 소유자 |

`RuleCaseExpander`는 외부 호환용 sanitize/secret helper와 `CombinationGenerator` 위임만 남아 있다. `RuleOutcomePolicy`도 legacy signal 계약을 `ResultEvaluator`로 변환하는 adapter이며 TestStatus를 자체 결정하지 않는다. CLI의 `expand-rule-cases`는 진단용 목록 생성 명령이고 Runner가 아니다. `run-rule-dataset` 실행 명령은 명시적으로 거부된다.

## 안전 경계 검사

- PowerShell entrypoint parameter: `TestPackPath` 있음, `DatasetPath` 없음.
- CLI `RunTestPack`: `TestPackRunnerContract.LoadApprovedCases` 사용, Dataset load/확장 없음.
- orchestration: `validate-test-pack`이 `Start-FlaUiBridge`보다 먼저 실행됨.
- Reporter loader: canonical status 불일치 거부, PASS에는 `executed=true`와 `evidencePresent=true` 필수.
- Reporter view model/XLSX renderer: 평가 명령 또는 evaluator 호출 없음.
- ResultEvaluator: `executed=false`를 먼저 PENDING 처리하고, 완료 결과 집계에서도 미실행·무증거 PASS 거부.
- target literal boundary: target 전용 화면·내부화면·control·confirmation 문구가 generic 생산 코드에 없음.

## 실행한 명령과 결과

### Restore와 빌드

```powershell
$env:DOTNET_CLI_HOME=Join-Path (Get-Location) '.dotnet-home'
dotnet restore HtsQaPoc.sln
```

첫 sandbox 실행은 NuGet network 차단으로 `NU1301`이 발생했다. 같은 명령을 승인된 network 권한으로 재실행해 4개 프로젝트 restore를 완료했다. 코드나 package 버전 변경은 없었다.

```powershell
$env:DOTNET_CLI_HOME=Join-Path (Get-Location) '.dotnet-home'
dotnet build HtsQaPoc.sln -c Release --no-restore
```

결과: 성공, 경고 0, 오류 0.

### .NET 전체와 Sample/Fake

```powershell
$env:DOTNET_CLI_HOME=Join-Path (Get-Location) '.dotnet-home'
dotnet test HtsQaPoc.sln -c Release --no-build --no-restore
```

결과: 95/95 PASS, 실패 0, 건너뜀 0.

```powershell
$env:DOTNET_CLI_HOME=Join-Path (Get-Location) '.dotnet-home'
dotnet test HtsQaPoc.sln -c Release --no-build --no-restore --filter "FullyQualifiedName~FlaUiAutomationEngineTests|FullyQualifiedName~FlaUiProcessSessionTests|FullyQualifiedName~TargetAdapterTests"
```

결과: 6/6 PASS. WinForms Sample/FlaUI UIA3 2건과 Fake/checked-in Target Adapter 4건이다.

### PowerShell 회귀와 정적 검사

```powershell
$tests=@(Get-ChildItem -LiteralPath tests\PowerShell -File -Filter '*.tests.ps1' | Sort-Object Name)
foreach($test in $tests){
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test.FullName
  if($LASTEXITCODE -ne 0){ throw "FAILED: $($test.Name)" }
}
```

결과: 22/22 test file PASS. 주요 개별 결과는 다음과 같다.

- `TEST_PACK_RUNNER_TESTS=PASS assertions=14`
- `PIPELINE_STATUS_TESTS=PASS assertions=23`
- `TARGET_LITERAL_BOUNDARY=PASS files=69 assertions=78`
- `result-evaluator golden`: CLI/PowerShell 동일 8 cases
- `REFACTORING_COMPLETION_TESTS=PASS assertions=1`

```powershell
$files=@(Get-ChildItem -LiteralPath scripts -Recurse -File -Filter '*.ps1')
foreach($file in $files){
  $tokens=$null; $errors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
  if($errors){ throw $errors }
}
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\dev\verify-source-layout.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\dev\verify-refactoring-completion.ps1
```

결과: PowerShell parse 43/43 PASS, source layout 80 files PASS, refactoring ownership 11 owners/48 assertions PASS.

### Node와 Reporter

```powershell
$files=@(Get-ChildItem -LiteralPath tools,tests -Recurse -File -Filter '*.mjs' |
  Where-Object {$_.FullName -notmatch '\\node_modules\\'})
foreach($file in $files){ node --check $file.FullName }
node tests\reporting\rule-results-contract.tests.mjs
node tests\reporting\rule-results-workbook-golden.mjs
node tests\reporting\repository-hygiene.tests.mjs
```

결과:

- Node syntax 12/12 PASS.
- Reporter contract 12 assertions PASS.
- Workbook golden 18 sheets, `PASS/FAIL/ERROR/PENDING` 상태 보존 PASS.
- Repository hygiene 6 assertions PASS, tracked output 2개만 허용.

### Approved TestPack dry-run

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\PowerShell\test-pack-runner.tests.ps1
```

이 회귀 테스트는 임시 TestPack compile, PendingApproval 실행 거부, hash 결합 승인, C# dry-run과 PowerShell Runner dry-run을 순서대로 수행한다. 결과는 14 assertions PASS이며 두 경로의 case 수·CaseId 순서가 같았다. PowerShell summary는 `PENDING`, `flaUiActionAttempts=0`이었다.

## 실제 실행, Fake 실행, 미실행

| 구분 | 결과 | 범위 |
|---|---|---|
| 정적 실행 | PASS | restore/build, source/parser/중복/경계 검사 |
| Fake/Sample 실행 | PASS | 6개 .NET Sample/Fake, 22개 PowerShell 회귀, 3개 Reporter fixture 테스트 |
| dry-run | PASS(도구 실행 성공), TestStatus는 PENDING | Approved TestPack case 소비, UI action 0 |
| 실제 HTS 조회/탐색 | 미실행/PENDING | 실제 창, 설치별 runtime control snapshot, binding drift |
| 실제 HTS 상태 변경 | 미실행/PENDING | 주문·매수·매도·정정·취소·이체·출금 전체 |

## 남은 PENDING과 기술 부채

- 실제 설치별 UIA provider가 노출하는 RuntimeId, pattern, native fallback 및 재탐색 안정성.
- 실제 HTS의 PlanOnly discovery가 만드는 `control-plan.json`과 `RuntimeControlPlanRow` schema의 현장 일치.
- 실제 화면의 popup/message/log evidence 품질과 ResultEvaluator 입력 완전성.
- 영상·cursor audit·XLSX까지 포함한 recorded pipeline 인프라 완료 상태. 상태 변경 동작 없이 조회 전용 대상으로만 별도 승인 후 확인해야 한다.
- `hts-rule-suite-orchestration.ps1` 1,796줄과 `rule-results-xlsx-renderer.mjs` 1,044줄은 책임 분리는 됐지만 여전히 큰 파일이다.
- 사용자가 제시한 선형 도식은 compile lane과 execution lane의 실제 의존을 한 줄로 합친다. `TargetSnapshot -> DatasetValidator`를 실제 계약으로 만들려면 공개 파이프라인 변경이므로 이번 검증 단계에서는 구현하지 않았다.
