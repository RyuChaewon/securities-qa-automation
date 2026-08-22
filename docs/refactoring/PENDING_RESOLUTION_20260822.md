# 실제 HTS PENDING 해제 검증 (2026-08-22)

## 범위와 안전 경계

이 검증은 로그인된 1Q HTS의 기존 0101 창을 대상으로 `PlanOnly` discovery와 물리 binding plan 생성까지만 수행했다. 주문·매수·매도·정정·취소·이체·출금, 확인 대화상자 제출, 녹화 실행은 수행하지 않았다. 실제 계좌 값, screenshot, raw log와 로컬 절대 경로가 포함된 산출물은 `artifacts/` 아래에만 보존하며 Git에 추가하지 않는다.

승인된 TestPack은 Dataset hash와 결합된 로컬 검증용 산출물이다. 이 승인으로 트랜잭션 제출을 허용하지 않았고 모든 Runner 호출에서 `-SubmitTransactionalDialogs`를 생략했다.

## 해제 조건과 결과

| 조건 | 결과 | 증거 |
|---|---|---|
| 로그인된 HTS와 0101 창 | 충족 | 기존 대상 창 1개를 확인하고 재사용 |
| Approved TestPack | 충족 | `TP-60f9481064b36a91`, Cartesian, 1 case, Dataset hash 일치 |
| 기존 화면 안전 재사용 | 충족 | 최초 `SCREEN_SEQUENCE_GUARD` 후 `ReuseExisting`/`RequireExisting`/`Preserve` 적용 |
| 실제 discovery | 충족 | 269 controls, 484 control tests, MAP models 19 |
| 실제 scenario action 없음 | 충족 | `flaUiActionAttempts=0`, `actualScenarioActionsExecuted=false` |
| 현재 설치 fingerprint | 충족 | static MAP과 live runtime fingerprint 일치 |
| 현재 시나리오 plan | 충족 | 1,159 scenarios, 1,239 cases, 6,730 steps, 승인 대기 0 |
| 물리 binding | 부분 충족 | required 385, high-confidence/execution-eligible 5, medium 15, unbound 365 |
| 실행 가능 case | 계획만 생성 | 6 executable, 1,233 `PENDING_BINDING`; 6개 모두 실제 실행하지 않음 |

실제 `PlanOnly` TestStatus는 `PENDING`이다. PASS=0, FAIL=0, ERROR=0, PENDING=1이며 실행되지 않은 검사를 PASS로 올리지 않았다. popup/message/log observation은 0건이므로 해당 평가도 계속 PENDING이다.

## 실행 명령과 결과

### Dataset 및 TestPack

```powershell
dotnet run --project src\HtsQa.Cli\HtsQa.Cli.csproj -c Release --no-build -- validate-rule-dataset --file outputs\0101_automation\0101.dataset.json
dotnet run --project src\HtsQa.Cli\HtsQa.Cli.csproj -c Release --no-build -- compile-test-pack --dataset outputs\0101_automation\0101.dataset.json --combination-policy Cartesian --max-cases 2000 --out artifacts\pending-resolution-20260822\pending-test-pack.json
dotnet run --project src\HtsQa.Cli\HtsQa.Cli.csproj -c Release --no-build -- create-test-pack-approval --test-pack artifacts\pending-resolution-20260822\pending-test-pack.json --out artifacts\pending-resolution-20260822\approval.json
dotnet run --project src\HtsQa.Cli\HtsQa.Cli.csproj -c Release --no-build -- compile-test-pack --dataset outputs\0101_automation\0101.dataset.json --combination-policy Cartesian --max-cases 2000 --approval artifacts\pending-resolution-20260822\approval.json --out artifacts\pending-resolution-20260822\approved-plan-only-test-pack.json
dotnet run --project src\HtsQa.Cli\HtsQa.Cli.csproj -c Release --no-build -- validate-test-pack --file artifacts\pending-resolution-20260822\approved-plan-only-test-pack.json --dataset outputs\0101_automation\0101.dataset.json
```

결과: Dataset valid, projectedCases=1. Approved TestPack 무결성·Dataset hash 검증 통과, caseCount=1.

### 실제 HTS PlanOnly

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-target-rule-suite.ps1 -TestPackPath .\artifacts\pending-resolution-20260822\approved-plan-only-test-pack.json -ReportDir .\artifacts\pending-resolution-20260822\plan-only -ScreensCsv 0101 -MaxCases 1 -PlanOnly -SkipExcel
powershell -ExecutionPolicy Bypass -File .\scripts\run-target-rule-suite.ps1 -TestPackPath .\artifacts\pending-resolution-20260822\approved-plan-only-test-pack.json -ReportDir .\artifacts\pending-resolution-20260822\plan-only-reuse -ScreensCsv 0101 -MaxCases 1 -PlanOnly -SkipExcel -ReuseExistingTargetScreen -RequireExistingTargetScreen -PreserveTargetScreenAfterRun
```

첫 명령은 기존 화면 1개 때문에 `SCREEN_SEQUENCE_GUARD`로 discovery 전에 안전 차단됐다. 프로세스 종료 코드는 0이었지만 case evidence는 executor error/PENDING이며 UIA discovery와 action은 각각 0이었다. 두 번째 명령은 기존 화면만 재사용해 종료 코드 0으로 완료됐다. 결과는 controls 269, control tests 484, MAP defined/bound/unbound/runtime-only controls=204/20/184/65, 설치 무결성 135 일치/0 실패, action attempts=0, TestStatus=PENDING이다.

### 현재 fingerprint 기반 시나리오·바인딩

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\plan-scenario-bindings.ps1 -CompiledPlanPath .\outputs\0101_automation\compiled-plan.json -TestPackPath .\artifacts\pending-resolution-20260822\approved-plan-only-test-pack.json -ReportDir .\artifacts\pending-resolution-20260822\binding-plan -ScreensCsv 0101 -RuntimeControlPlanPath .\artifacts\pending-resolution-20260822\plan-only-reuse\control-plan.json -RuntimeSummaryPath .\artifacts\pending-resolution-20260822\plan-only-reuse\summary.json
```

결과: 종료 코드 1. 이전 compiled plan과 현재 설치 fingerprint가 달라 정확히 거부됐다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-auto-scenario-pipeline.ps1 -DatasetPath .\outputs\0101_automation\0101.dataset.json -TestPackPath .\artifacts\pending-resolution-20260822\approved-plan-only-test-pack.json -ScreensCsv 0101 -OutputDir .\artifacts\pending-resolution-20260822\auto-static -ReferenceDate 20260822 -MaxOptionsPerControl 40 -MaxCases 2000 -StaticOnly
node .\targets\1q-hts\0101\tools\import-testcases.mjs --workbook .\outputs\0101_screen_testcases\0101_국내주식_매수주문_테스트케이스_공식가이드보완.xlsx --map-catalog .\artifacts\pending-resolution-20260822\auto-static\map-catalog.json --target-profile .\targets\1q-hts\0101\target-profile.json --output-dir .\artifacts\pending-resolution-20260822\current-import
dotnet run --project src\HtsQa.Cli\HtsQa.Cli.csproj -c Release --no-build -- validate-generated-scenarios --file artifacts\pending-resolution-20260822\current-import\generated-scenarios.json --dataset artifacts\pending-resolution-20260822\current-import\0101.dataset.json --out artifacts\pending-resolution-20260822\current-import\scenario-validation.json
dotnet run --project src\HtsQa.Cli\HtsQa.Cli.csproj -c Release --no-build -- create-scenario-approval --file artifacts\pending-resolution-20260822\current-import\generated-scenarios.json --out artifacts\pending-resolution-20260822\current-import\scenario-approval.template.json
dotnet run --project src\HtsQa.Cli\HtsQa.Cli.csproj -c Release --no-build -- compile-scenarios --file artifacts\pending-resolution-20260822\current-import\generated-scenarios.json --dataset artifacts\pending-resolution-20260822\current-import\0101.dataset.json --approval artifacts\pending-resolution-20260822\current-import\scenario-approval.json --max-cases 2000 --out artifacts\pending-resolution-20260822\current-import\compiled-plan.json
powershell -ExecutionPolicy Bypass -File .\scripts\plan-scenario-bindings.ps1 -CompiledPlanPath .\artifacts\pending-resolution-20260822\current-import\compiled-plan.json -TestPackPath .\artifacts\pending-resolution-20260822\approved-plan-only-test-pack.json -ReportDir .\artifacts\pending-resolution-20260822\current-binding -ScreensCsv 0101 -RuntimeControlPlanPath .\artifacts\pending-resolution-20260822\plan-only-reuse\control-plan.json -RuntimeSummaryPath .\artifacts\pending-resolution-20260822\plan-only-reuse\summary.json
```

결과: `StaticOnly` pipelineStatus=DONE, testStatus=PENDING, 실제 action=false. 원본 1,159개 ScenarioId는 전부 유지됐고 새 plan은 현재 fingerprint와 일치했다. 최종 binding command 종료 코드는 0이고 상태는 `PARTIAL`이다. `run-auto-scenario-pipeline.ps1` 내부의 `dotnet build HtsQaPoc.sln -c Release --no-restore`도 종료 코드 0으로 완료됐다. 단위 테스트와 Fake/Sample 테스트는 이번 현장 실행에서 다시 수행하지 않았다.

## 실제 실행·Fake·미실행 구분

| 구분 | 상태 | 내용 |
|---|---|---|
| 실제 HTS 실행 | 수행, TestStatus `PENDING` | 기존 0101 창 attach, MAP/runtime control discovery, binding plan 생성 |
| 실제 scenario action | 미실행 | action attempts=0, query/popup observation 없음 |
| Fake/Sample | 이번 단계 미실행 | 앞선 회귀 검증 결과를 재주장하지 않음 |
| 녹화/Reporter XLSX | 미실행/PENDING | recorded pipeline과 파생 XLSX를 실행하지 않음 |
| 실제 상태 변경 | 미실행/PENDING | 주문·매수·매도·정정·취소·이체·출금 전체 |

## 남은 PENDING

- 385개 required binding 중 365개 unbound와 15개 medium-confidence binding의 target-specific locator 보강.
- 물리적으로 실행 가능하다고 계산된 6 cases도 모두 `Click` 단계를 포함한다. 주문 화면에서 무해한 assertion-only 실행이라고 보장할 수 없어 실제 실행하지 않았다.
- popup/message/log evidence와 ResultEvaluator 입력 완전성은 observation 0건이므로 PENDING이다.
- 녹화·cursor audit·XLSX까지 포함한 recorded pipeline은 비거래 assertion-only TestPack이 별도로 승인될 때까지 PENDING이다.
