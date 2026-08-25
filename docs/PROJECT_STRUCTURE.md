# 프로젝트 구조와 수정 경계

이 문서는 폴더 위치를 암기하지 않고 책임과 데이터 흐름을 기준으로 수정할 수 있게 하는 구조 지도다. 실제 실행 파일 연결의 단일 기준은 `config/pipeline.manifest.json`이다.

## 최상위 구조

```text
1QHTS_TEST/
|-- HtsQaPoc.sln            .NET 프로젝트와 테스트의 빌드 단위
|-- config/                 실행 파일 연결과 단계 계약
|-- data/
|   |-- rule-tests/         대상 프로필, 화면 목록, 계정·입력 조합
|   |-- realhts/            대상별 런타임 콘텐츠 영역 보정값
|   `-- scenarios/inbox/    외부에서 반입한 선택적 시나리오 원본
|-- docs/                   구조, 정책, 사용 및 수정 문서
|-- scripts/                사용자가 직접 실행하는 PowerShell 명령
|   |-- modules/            명령이 dot-source하는 내부 라이브러리
|   `-- dev/                실제 HTS를 건드리지 않는 개발 검증
|-- src/
|   |-- HtsQa.Cli/          정적 생성·검증·컴파일 명령 호스트
|   |   |-- Program.cs      `CliApplication.Run(args)`만 호출하는 process entrypoint
|   |   |-- CliApplication.cs  command routing과 최상위 오류·exit code
|   |   |-- CliCommandContext.cs  repository root와 경로 정규화
|   |   |-- CliArguments.cs  공통 option parsing과 optional JSON output
|   |   |-- CliHelp.cs      기존 help stdout 계약
|   |   `-- Commands/       기능군별 Core CLI adapter
|   |-- HtsQa.Core/         UI와 무관한 도메인·파서·정책
|   `-- HtsQa.FlaUi/        FlaUI UIA3 브리지와 자동화 엔진
|-- targets/                화면별 Target Adapter, profile, importer와 호환 명령
|-- tests/HtsQa.Tests/      책임별 단위·통합 회귀 테스트
|-- tools/                  보고서·영상·시나리오 패키지 변환 진입점
|   `-- reporting/          JSON loader, view model, XLSX renderer, output manager
|-- reports/                실제 실행 결과와 Excel·영상
|-- artifacts/              정적 검증과 계획 산출물
|-- exports/                외부 전달용 시나리오 요청 패키지
`-- archive/                명시적으로 보존한 대표 증적
```

`reports`, `artifacts`, `exports`, `TestResults`, `bin`, `obj`는 생성물이다. `.dotnet-home`, `.venv`, `node_modules`는 로컬 도구 캐시다. 제품 코드를 찾거나 수정할 때 이 폴더들을 검색 대상에서 제외한다.

현재 비어 있는 `data/checklists`, `data/locators`, `data/plans`, `data/screen-models`, `data/screen-profiles`, `prompts`, `services`와 LLM 시절의 `models`는 활성 파이프라인에서 참조하지 않는 예약·정리 대상이다. 새 기능은 이 이름만 보고 넣지 말고 먼저 manifest와 이 문서에 책임을 등록한다.

## 폴더 간 관계

| 생산자 | 산출물 또는 호출 | 소비자 |
|---|---|---|
| `data/rule-tests` | `targetProfile`, `screens`, 입력 조합 | `scripts/modules/pipeline-common.ps1`, `HtsQa.Core` |
| `config` | 논리 진입점과 단계 순서 | 모든 오케스트레이션 스크립트, 구조 검증기 |
| `scripts` | 단계 실행과 프로세스 연결 | `HtsQa.Cli`, `HtsQa.FlaUi`, `tools` |
| `HtsQa.Cli` | TestPack, MAP 모델, 시나리오, 승인·컴파일·바인딩 JSON | PowerShell 실행기와 다음 CLI 단계 |
| `HtsQa.FlaUi` | UIA3 발견·조작 결과 NDJSON | `run-target-rule-suite.ps1` |
| `HtsQa.Core` | 데이터 검증, 조합·CaseId·TestPack, MAP·설치 해석, 판정 정책 | `HtsQa.Cli`, 단위 테스트 |
| `targets` | 대상별 화면·control·업무 의미와 import 도구 | generic Target Adapter 계약 |
| `tools/reporting` | canonical TestResult 로드, 표시 모델, Excel 렌더링 | `reports`; TestResult 상태는 읽기 전용 |
| `tools` | 영상, 요청 패키지, Reporter 진입점 | `reports`, `exports` |
| `tests`와 `scripts/dev` | 회귀 결과 | 개발자와 CI |

핵심 실행 흐름은 다음과 같다.

```text
compile lane
  Dataset -> RuleDatasetValidator -> CombinationGenerator/CaseIdFactory
          -> ExpectationResolver -> TestPackCompiler -> Approved TestPack

execution lane
  Approved TestPack -> TestPackRunnerContract -> PowerShell orchestration
                    -> HtsQa.FlaUi + Target Adapter
                    -> Discovery/TargetSnapshot -> Binding/Action -> Observation
                    -> ResultEvaluator -> TestResult -> Reporter
                    -> reports / artifacts / exports
```

Runner는 `RuleTestPack.cases`만 소비한다. `datasetSnapshot`은 대상 profile과 표시 문맥을 제공하지만 실행 중 조합을 다시 만들지 않는다. UI Discovery가 만든 `RuntimeControlPlanRow[]`는 scenario/binding용 runtime evidence이며 DatasetValidator 입력이 아니다.

## 대상별 데이터 경계

실제 화면번호는 다음 위치에서만 선언한다.

| 허용 위치 | 이유 |
|---|---|
| `data/rule-tests/*.dataset.json`의 `screens[]`, `variables[].appliesToScreens` | 실행 대상을 선택하는 단일 입력 계약 |
| `data/scenarios/inbox` | 특정 데이터셋에 대해 외부에서 생성한 원본 시나리오 |
| `targets/<vendor>/<screen>` | 화면·메뉴·AutomationId·문구 matcher와 target 전용 importer |
| `reports`, `artifacts`, `exports`, `archive` | 실행 당시 대상을 보존하는 생성 증적 |
| `tests/HtsQa.Tests/Fixtures` | 실제 제품과 무관한 합성 화면 규약 |

`src`, generic `scripts`, generic `tools`, `config`에는 실제 화면번호, 제품 설치 경로, 특정 제품 데이터셋 기본값을 두지 않는다. Runner와 바인딩 명령은 `-TestPackPath`를 필수로 받고 선택 화면은 해시 고정된 `datasetSnapshot` 또는 `-ScreensCsv`에서 읽는다. 진단·시나리오 원본 도구만 `-DatasetPath`를 받는다. `verify-source-layout.ps1`과 `target-literal-boundary.tests.ps1`가 이 경계를 정적으로 검사한다.

## Core 책임

| 폴더 | 책임 | 주요 파일 |
|---|---|---|
| `Contracts` | 공통 상태와 JSON 계약 | `RuleCommon.cs` |
| `Datasets` | 데이터셋 모델·검증과 legacy sanitize/secret 호환 helper | `RuleBased.cs` |
| `Calibration` | 반복 read-only 관측, drift, human review, 승인 repository 적용 provenance | `OrderCalibration.cs`, `OrderCalibrationWorkflow.cs`, `OrderCalibrationLifecycle.cs` |
| `Authorization` | stable ControlContractHash, redacted EnvironmentFingerprint, execution scope 승인·drift·만료·preflight 판정 | `ExecutionAuthorization.cs` |
| `Controls` | Control Repository schema, logical key, 승인 hash, locator trust/risk와 canonical resolution | `ControlRepository.cs` |
| `Evaluation` | Observation + ExpectedResult + EvaluationPolicy를 완성 TestResult로 변환 | `ResultEvaluator.cs` |
| `Installation` | HTS 설치 자료 카탈로그 | `HtsInstallation.cs` |
| `Maps` | MAP 파싱·화면 모델·동작/오류 오라클 | `HtsMap.cs` |
| `Outcomes` | legacy signal 계약을 ResultEvaluator에 연결하는 호환 adapter | `RuleOutcomePolicy.cs` |
| `Scenarios` | 자동 생성·승인·컴파일·물리 계획과 승인 key 기반 주문 authoring/validator/DryRun 계획 | `RuleScenarioGeneration.cs`, `Contracts/*`, `Validation/GeneratedScenarioValidator.cs`, `Compilation/ScenarioPlanCompiler.cs`, `Binding/ScenarioBindingMaterializer.cs`, `ScenarioIds.cs`, `OrderScenarioAuthoring.cs` |
| `Serialization` | JSON 입출력과 해시 | `JsonFile.cs` |
| `Targets` | generic TargetProfile/TargetAdapter schema 검증 | `TargetAdapter.cs` |
| `TestPacks` | CombinationPolicy, 조합, CaseId, 기대 해석, compile/approval/runner gate | `TestPack.cs` |

폴더는 책임을 구분하지만 namespace는 기존 JSON·CLI 소비 코드와의 호환성을 위해 `HtsQa.Core`로 유지한다. 새 타입은 가장 가까운 책임 폴더에 추가하고 두 책임을 직접 결합해야 한다면 상위 오케스트레이터에서 조합한다.

### Scenario planning 파일 책임

| 파일 | 입력 | 출력 | 금지 책임 |
|---|---|---|---|
| `Contracts/GeneratedScenarioContracts.cs` | JSON source와 approval 입력 형태 | generated/review/validation 계약 | 검증·컴파일·binding |
| `Contracts/CompiledScenarioContracts.cs` | compiler 출력 형태 | logical plan/case/step 계약 | runtime resolution |
| `Contracts/ScenarioBindingContracts.cs` | runtime snapshot과 binding 출력 형태 | catalog/physical plan 계약 | source validation·verdict |
| `Validation/GeneratedScenarioValidator.cs` | generated source, Dataset, source hash | 기존 issue code·target·message의 validation report | case·physical plan 생성 |
| `Compilation/ScenarioPlanCompiler.cs` | 검증된 source, Dataset, approval hash | 동일 ScenarioId·CaseId·planHash의 logical plan | runtime UI binding |
| `Binding/ScenarioBindingMaterializer.cs` | compiled requirement, runtime control 후보 | binding catalog와 physical disposition | scenario validation·TestResult 판정 |
| `ScenarioIds.cs` | canonical 문자열 | 기존 fingerprint 기반 ID hash | 정책·I/O |

`RuleScenarioGeneration.cs`와 `OrderScenarioAuthoring.cs`는 이 분리에서 변경하지 않는다. compiler와 binding은 `ResultEvaluator`를 호출하지 않으며, PowerShell과 reporter는 기존 JSON을 그대로 소비한다.

## HtsQa.Cli 책임

`Program.cs`는 인수를 바꾸지 않고 `CliApplication.Run(args)`에 위임한다. 실제 command 문자열, unknown command, 최상위 예외와 exit code는 `CliApplication` 한 곳에서 소유한다. command handler는 Core API와 JSON I/O를 연결하지만 HTS, FlaUI, verdict 정책을 실행하지 않는다.

| 파일 | 소유 command 또는 공통 책임 | 담당하지 않는 책임 |
|---|---|---|
| `CliApplication.cs` | root context 생성, 명시적 switch routing, top-level stderr·exit code | 업무 JSON·hash·verdict |
| `CliCommandContext.cs` | `FindRoot`, 상대·절대 경로 정규화 | option·업무 validation |
| `CliArguments.cs` | `Required`, `GetOpt`, enum list, optional JSON output | command routing·업무 정책 |
| `CliHelp.cs` | 기존 help command·사용법과 stdout 바이트 계약 | routing |
| `Commands/DatasetCommands.cs` | `validate-rule-dataset`, `expand-rule-cases`, `run-rule-dataset` | TestPack 승인 |
| `Commands/TestPackCommands.cs` | TestPack compile·approval template·validate·offline dry-run | 실제 HTS 실행 |
| `Commands/MapCommands.cs` | `extract-map-models` | runtime discovery |
| `Commands/ScenarioCommands.cs` | generated scenario, approval, logical/physical plan·binding command | Core compiler 정책 재구현 |
| `Commands/ControlRepositoryCommands.cs` | repository review·approval·validation·resolution adapter | locator 자동 승인 |
| `Commands/AuthorizationCommands.cs` | environment approval template·apply와 canonical authorization status adapter | hash·scope·risk 재판정 |
| `Commands/CalibrationCommands.cs` | read-only calibration session·review·registration adapter | UI capture 실행·자동 병합 |
| `Commands/OrderScenarioCommands.cs` | order scenario validation·compile·DryRun adapter | UI action·risk verdict 재구현 |
| `Commands/EvaluationCommands.cs` | Observation을 canonical `ResultEvaluator`에 전달 | 독자 verdict |
| `Commands/RunAnalysisCommands.cs` | 기존 `summary.json` 표시 | 결과 재판정 |

새 command는 가장 가까운 `Commands/*Commands.cs`에 handler를 두고 `CliApplication` switch와 `CliHelp` 사용법을 함께 갱신한다. 공통 helper를 handler에 복제하지 않으며, 새 기능군이 기존 책임과 겹치지 않을 때만 새 handler 파일을 만든다.

## FlaUI 책임

| 폴더 | 책임 |
|---|---|
| `Contracts` | PowerShell과 교환하는 NDJSON 요청·응답 |
| `Automation` | UIA3 요소 탐색·재식별·패턴 조작·상태 검증, client-relative 좌표·DPI 변환과 read-only capture |
| 프로젝트 루트 `Program.cs` | stdin/stdout 프로토콜 호스팅 |

FlaUI 객체는 `Automation` 밖으로 내보내지 않는다. PowerShell에는 `Contracts`의 직렬화 가능한 snapshot과 오류 코드만 반환한다.

## PowerShell 책임

`scripts` 루트의 파일은 사용자가 직접 실행할 수 있는 안정적인 명령 경로다. 파일 이동이 필요해도 기존 명령을 제거하지 말고 호환 래퍼 또는 manifest 마이그레이션을 먼저 제공한다.

`scripts/modules`는 직접 실행하지 않는다.

| 모듈 | 책임 |
|---|---|
| `pipeline-common.ps1` | 저장소 경로, manifest, 대상 프로필 정규화 |
| `pipeline-status.ps1` | PipelineStatus/TestStatus 분리와 호환 상태 변환 |
| `result-evaluator.ps1` | 원시 Observation JSON을 CLI에 전달하고 완성 TestResult를 반환하는 무판정 어댑터 |
| `hts-session.ps1` | 프로세스 연결, 창 수명과 종료 |
| `hts-navigation.ps1` | 화면 이동, 재개방과 현재 화면 복구 |
| `hts-discovery.ps1` | UIA/MAP raw control snapshot |
| `hts-binding.ps1` | 논리 control과 현재 UIA element 연결 |
| `hts-action.ps1` | 입력·클릭·선택; 판정·report 금지 |
| `hts-observation.ps1` | message·상태·값·evidence 수집; 최종 판정 금지 |
| `hts-safety.ps1` | 금지 동작, allowlist, 실행 전 안전 검증 |
| `hts-control-repository.ps1` | hover capture와 Core canonical resolution의 무판정 adapter; 승인·risk 판정 금지 |
| `hts-order-scenario-authoring.ps1` | 캘리브레이션·검증·compile·DryRun Core CLI 연결; UI·risk·verdict 금지 |
| `hts-reporting.ps1` | 완성된 TestResult와 raw evidence 직렬화 보조 |
| `hts-rule-suite-orchestration.ps1` | 공개 인자와 lifecycle 모듈 조립만 담당하는 composition root |
| `hts-target-adapter.ps1` | TestPack target profile을 generic context로 정규화 |
| `hts-target-rule-*.ps1` | target profile이 제공한 규칙의 discovery/binding/action adapter |
| `rule-control-exploration.ps1` | 이전 import 경로를 보존하는 얇은 호환 wrapper |
| `report-sanitization.ps1` | 저장 전 민감정보 마스킹 |

### Rule Suite lifecycle 모듈

| 모듈 | 명시 입력 | 출력 | 담당하지 않는 책임 |
|---|---|---|---|
| `hts-rule-suite-bootstrap.ps1` | 공개 인자, 저장소 root | 승인된 TestPack·target context가 포함된 `RunSpec`, 출력 경로 | UI 초기화, 판정, report 렌더링 |
| `hts-rule-suite-plan-loader.ps1` | `RunSpec`, compiled/physical plan, binding catalog | schema·planHash·file hash·실행 범위가 검증된 plan 속성 | plan 실행, fallback, binding 자동 수정 |
| `hts-rule-suite-context-factory.ps1` | 검증 완료 `RunSpec` | `RunServices`, 초기 `RunState` | mode routing, 화면·case 루프, verdict |
| `hts-rule-suite-mode-router.ps1` | `RunSpec`, 주입 coordinator | DryRun·PlanOnly·Execute 중 하나의 호출 결과 | 세부 UI 동작, TestStatus 계산 |
| `hts-screen-runner.ps1` | 승인 case 순서, `RunServices`, `RunState` | 화면 사전점검·순서·종료 사실과 case 호출 결과 | 개별 값 판정, canonical verdict |
| `hts-case-runner.ps1` | 단일 case와 세 lifecycle 객체 | action/checkpoint raw evidence를 담은 case frame | PASS/FAIL 할당, run summary |
| `hts-case-action-runner.ps1`, `hts-case-legacy-runner.ps1` | 승인 physical step 또는 legacy query와 case frame | 기존 action·observation 사실 | screen 순서, self-healing, verdict |
| `hts-run-result-finalizer.ps1` | raw Observation, evaluator adapter, 기존 result schema | canonical `case-results.json`, `test-results.json`, `summary.json` | 독자 판정, reporter 재판정 |
| `hts-run-cleanup.ps1` | 주입 cleanup dependency, `RunState` | cleanup 성공·오류 사실 | evidence 삭제, 업무 성공·실패 변경 |

상태 전달은 세 객체로 제한한다.

| 객체 | 수명 | 대표 값 |
|---|---|---|
| `RunSpec` | run 동안 불변 | target context, TestPack/Dataset, mode, plan·approval/hash, 선택 범위, 출력 경로, risk 정책 |
| `RunServices` | bootstrap 이후 주입 | Session, Navigation, Discovery, Binding, Action, Observation, Safety, Evaluation, Reporting, TargetAdapter |
| `RunState` | run 동안 변경 | 현재 화면·case, action/checkpoint evidence, UI·transactional action 수, 오류/PENDING, cleanup와 산출물 경로 |

UI 모듈은 ResultEvaluator나 XLSX renderer를 호출하지 않는다. orchestration은 raw Observation을 `result-evaluator.ps1`에 넘긴 뒤 반환된 TestResult 상태를 복사한다.

## Reporting 책임

| 파일 | 책임 |
|---|---|
| `tools/build-rule-results-workbook.mjs` | 인자 처리와 네 reporting component 조립 |
| `rule-results-loader.mjs` | canonical JSON 로드·schema·상태 불변 검증·deep freeze |
| `rule-results-view-model.mjs` | TestResult를 한국어 workbook 표시 모델로 변환 |
| `rule-results-xlsx-renderer.mjs` | view model을 XLSX로 렌더링 |
| `rule-report-output-manager.mjs` | report directory 밖 쓰기·읽기 차단과 preview 옵션 관리 |

선택적인 `control-repository-resolutions.json`은 locator source, trust tier, fallback 사유와 승인 상태를 표시하는 canonical resolution 입력이다. 선택적인 `calibration-session.json`, `order-scenario-validation.json`, `order-run-plan.json`, `order-scenario-dry-run.json`은 `주문작성` sheet의 canonical 표시 입력이다. Reporter는 이 상태나 TestResult verdict를 다시 계산하지 않는다.

`test-results.json`이 canonical source다. loader는 `case-results.json`/`summary.json`이 canonical 상태와 다르면 실패하고, PASS에 실행·증거가 없으면 실패한다. XLSX와 preview는 파생 산출물이라 TestStatus를 갱신하지 않는다.

## 의존 방향

```text
PowerShell commands
  -> scripts/modules
  -> HtsQa.Cli / HtsQa.FlaUi

targets
  -> generic Target Adapter contract

HtsQa.Cli
  -> HtsQa.Core

HtsQa.FlaUi
  -> FlaUI packages

HtsQa.Core
  -> .NET 표준 라이브러리

Reporter
  -> canonical TestResult JSON
  -> artifact-tool renderer
```

`HtsQa.Core`가 PowerShell, FlaUI 또는 특정 보고서 도구를 참조하게 만들지 않는다. 대상별 화면번호·창 클래스·설치 경로는 코드가 아니라 데이터셋 `targetProfile`에 둔다.

## 주석 원칙

모든 유지 코드 파일 시작에는 다음 내용이 있어야 한다.

1. 역할: 이 파일이 책임지는 한 가지 이유
2. 입력·출력: 앞뒤 단계와 교환하는 계약
3. 경계: 하지 않는 일과 안전 조건
4. 수정 지점: 함께 변경하거나 검증해야 할 위치

함수 주석은 반환값, 부작용, 실패 상태 또는 안전 조건이 있을 때 작성한다. 변수 대입이나 반복문을 그대로 읽어 주는 주석은 작성하지 않는다. 복잡한 분기에는 구현 내용보다 그 분기가 필요한 이유를 기록한다.

## 구조 검증

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\dev\verify-source-layout.ps1
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\dev\verify-refactoring-completion.ps1
```

첫 검사는 manifest 경로, 내부 모듈 위치, 파일 헤더와 모든 PowerShell 파일의 구문을 확인한다. 두 번째 검사는 15개 핵심 계약의 단일 선언, Scenario planning 책임 경계, Runner 승인 경계, 중복 제거, Reporter 상태 불변과 미실행 PASS 차단을 확인한다.

## 실제 HTS PENDING 경계

정적·단위·dry-run·Sample/Fake 검증으로 다음 항목을 PASS 처리하지 않는다.

- 설치별 UIA runtime snapshot과 binding drift
- 실제 popup/message/log/screenshot evidence의 누락 여부
- recorded run의 영상·cursor audit·report 완료 계약
- 주문·매수·매도·정정·취소·이체·출금 상태 변경

마지막 항목은 검증 명령에 포함하지 않는다. 현재 결과와 최초 기준선 비교는 `docs/refactoring/FINAL_VALIDATION_RESULTS.md`에 있다.
