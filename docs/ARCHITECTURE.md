# 실행 구조와 연결성

## 실행 파일은 독립적인가

일부는 독립 실행 파일이고 일부는 다른 파일이 불러 쓰는 라이브러리다.

| 구분 | 파일 | 독립 실행 | 역할 |
|---|---|---:|---|
| 오케스트레이터 | `run-auto-scenario-pipeline.ps1` | 예 | 전체 파이프라인 순서·중단 조건 관리 |
| 핵심 실행기 | `run-target-rule-suite.ps1` | 예 | Approved TestPack 기반 DryRun, PlanOnly, 실제 화면 조작 |
| UIA3 브리지 | `src/HtsQa.FlaUi` | 예(일반적으로 자식 실행) | FlaUI UIA3 요소 탐색·패턴 조작·검증 |
| 녹화 래퍼 | `run-target-rule-suite-recorded.ps1` | 예 | 녹화기와 핵심 실행기를 같은 시간축으로 구동 |
| 바인딩 계획 | `plan-scenario-bindings.ps1` | 예 | PlanOnly 관찰과 물리 계획 생성 |
| 외부 시나리오 | `invoke-scenario-pipeline.ps1` | 예 | 요청·반입·승인·바인딩·실행 단계별 수행 |
| 녹화기 | `record-desktop-frames.ps1` | 예 | 지정 창의 전체 물리 픽셀 캡처 |
| Excel 변환기 | `export-rule-results-xlsx.ps1` | 예 | 기존 실행 JSON을 Excel로 변환 |
| 공통 라이브러리 | `scripts/modules/pipeline-common.ps1` | 아니요 | 대상 프로필, 경로, manifest 로드 |
| UI 수명주기 모듈 | `hts-session.ps1`, `hts-navigation.ps1` | 아니요 | 프로세스·창 수명과 화면 이동 |
| UI 계약 모듈 | `hts-discovery.ps1`, `hts-binding.ps1` | 아니요 | raw snapshot과 논리/물리 control 연결 |
| UI 동작 모듈 | `hts-action.ps1`, `hts-observation.ps1`, `hts-safety.ps1` | 아니요 | 경계 검증된 동작과 원시 증거 수집 |
| 평가 adapter | `scripts/modules/result-evaluator.ps1` | 아니요 | 원시 Observation을 Core CLI로 전달 |
| target adapter | `scripts/modules/hts-target-adapter.ps1` + `targets/*` | 아니요 | 대상별 화면·control·문구 의미 제공 |
| 마스킹 라이브러리 | `scripts/modules/report-sanitization.ps1` | 아니요 | 민감정보 제거 |

독립 실행 가능하다는 것은 필요한 입력 파일을 명시하면 상위 오케스트레이터 없이 해당 기능만 실행할 수 있다는 뜻이다. 라이브러리 파일은 `.` 연산자로 현재 PowerShell 스코프에 함수를 등록한다.

## 연결을 구성하는 파일

`config/pipeline.manifest.json`이 실행 파일의 논리 이름과 단계 순서를 정의한다. `scripts/modules/pipeline-common.ps1`의 다음 함수가 이 명세를 읽는다.

- `Get-RulePipelineManifest`: manifest와 필수 파일 존재 검증
- `Get-RulePipelineEntryPoint`: `targetRunner` 같은 논리 이름을 절대 경로로 변환
- `Get-RuleTargetContext`: 데이터셋의 대상 창·설치·화면 범위를 단일 객체로 정규화
- `Get-RuleTestPackContext`: 승인 TestPack의 내장 datasetSnapshot을 Runner 대상 컨텍스트로 정규화

각 실행 파일이 서로의 경로를 직접 반복해서 적지 않으므로 파일명이나 연결이 바뀌면 manifest 한 곳을 수정할 수 있다.

## 최종 계약과 소유자

| 계약 | 입력 | 출력 | 소유 모듈 |
|---|---|---|---|
| Dataset validation | `RuleTestDataset` | `ValidationResult` | `RuleDatasetValidator` |
| Combination generation | 검증된 Dataset, policy, maxCases | 결정론적 `RuleTestCase[]` | `CombinationGenerator` |
| CaseId | dataset/screen/account/canonical variables | SHA-256 기반 CaseId | `CaseIdFactory` |
| TestPack compile/approval | Dataset hash, cases, approval overlay | 불변 `RuleTestPack` | `TestPackCompiler`, `TestPackValidator` |
| Discovery | target window와 adapter | `RuleDiscoveredControl[]` | `hts-discovery.ps1` |
| TargetSnapshot | 화면별 발견 control | `RuntimeControlPlanRow[]`/`control-plan.json` | `ScenarioPlanning.cs` 계약, Runner writer |
| Observation | 실제 action과 수집 증거 | `Observation[]` | `hts-observation.ps1`, `ResultEvaluator.cs` 계약 |
| Result evaluation | Observation + ExpectedResult + EvaluationPolicy | 완성 `TestResult` | `ResultEvaluator` |
| Reporting | canonical `TestResultDocument` | XLSX/preview | `tools/reporting/*` |

`RuleCaseExpander`와 `RuleOutcomePolicy`는 각각 `CombinationGenerator`와 `ResultEvaluator`로 위임하는 호환 adapter다. PowerShell에 조합·CaseId·판정 분기는 없다.

## 전체 호출 순서

```text
compile lane
  Dataset
    -> DatasetValidator
    -> CombinationGenerator
    -> ExpectationResolver
    -> TestPackCompiler
    -> Approved TestPack

execution lane
  Approved TestPack
    -> run-target-rule-suite.ps1
    -> session/navigation/discovery/binding/safety/action
    -> TargetSnapshot(control-plan.json) + Observation
    -> HtsQa.Cli evaluate-results -> ResultEvaluator -> TestResult
    -> JSON canonical report -> XLSX/preview renderer

  recorded wrapper -> video/cursor audit 증거
```

`run-auto-scenario-pipeline.ps1`은 두 lane과 MAP·시나리오 계획을 연결한다. 먼저 Dataset hash와 Approved TestPack을 검증하고, 그 뒤에만 PlanOnly Discovery 또는 실제 runner를 시작한다. 따라서 사용자가 제시한 `Discovery -> TargetSnapshot -> DatasetValidator` 표기는 산출물 이름을 나열한 개념도이며 실제 호출 순서가 아니다. `TargetSnapshot`은 DatasetValidator가 아니라 scenario generation과 binding이 소비한다.

실제 전체 오케스트레이션은 다음 구성요소를 추가로 조합한다.

```text
run-auto-scenario-pipeline.ps1
  -> validate-test-pack --dataset ...
  -> extract-map-models
  -> (StaticOnly가 아니면) run-target-rule-suite.ps1 -PlanOnly
  -> generate/validate/approve/compile scenarios
  -> materialize/build-physical
  -> (PrepareOnly가 아니면) run-target-rule-suite-recorded.ps1
       -> recorder + Approved TestPack runner + Reporter
```

## 파일 사이의 데이터 연결

각 단계는 메모리 상태가 아니라 JSON 파일과 해시를 다음 단계에 넘긴다.

| 생산 단계 | 산출물 | 소비 단계 |
|---|---|---|
| TestPack 컴파일·승인 | `test-pack.json`, `contentHash`, approval 정보 | PlanOnly·바인딩·실제 실행기 |
| MAP 추출 | `map-catalog.json` | 시나리오 생성·오라클·바인딩 |
| PlanOnly | `control-plan.json`, `summary.json` | 생성기·동적 바인더 |
| 시나리오 생성 | `generated-rule-scenarios.json` | 검증·승인 |
| 컴파일 | `compiled-plan.json`, `planHash` | 물리 바인딩·실행기 |
| 바인딩 | `binding-catalog.json`, `physical-plan.json` | 실제 실행기 |
| 실제 실행 | raw observations, `case-results.json`, `summary.json` | ResultEvaluator adapter |
| 평가 | canonical `test-results.json` | Reporter loader |
| Reporter | XLSX와 preview | 사용자; canonical JSON은 수정하지 않음 |
| 녹화 | `full-run.mp4`, `recording.done.json` | 영상 검사·오류 프레임 추출 |

`datasetId`, 설치 fingerprint, 원본 SHA-256, `planHash`가 서로 다른 실행의 파일이 섞이는 것을 차단한다.

## FlaUI UIA3와 Win32의 경계

`run-target-rule-suite.ps1`은 `HtsQa.FlaUi` 프로세스를 실행당 한 번 시작한다. 화면 탐색과 의미 조작은 다음 우선순위를 따른다.

1. FlaUI UIA3 `RuntimeId`로 현재 요소 재식별
2. 네이티브 HWND, AutomationId, 이름·클래스·ControlType 복합 조건
3. 같은 ControlType의 가장 가까운 절대 좌표
4. UIA3 Value/Invoke/Toggle/SelectionItem/RangeValue 또는 FlaUI 컨트롤 래퍼 실행
5. UIA 공급자 비지원이 명시된 경우에만 입력 경계 검증 후 Win32 fallback

`input-boundary-audit.ndjson`에는 `FlaUIAction` 허용/fallback이 남고, `summary.json`에는 탐색 호출 수, 발견 요소 수, 조작 시도·성공 수, fallback 수와 사유가 남는다. 따라서 Win32 동작을 FlaUI 성공으로 집계할 수 없다.

## 승인과 상태 계약

TestPack compile 결과는 기본적으로 `PendingApproval`이다. approval overlay는 `testPackContentHash`와 결합되며 `Approved`, 승인자, 승인 시각, evidence reference가 모두 유효해야 Runner가 cases를 반환한다. 현재 Dataset hash가 달라지면 `validate-test-pack --dataset`이 거부한다.

`PipelineStatus`와 `TestStatus`는 서로 다른 계약이다.

| 필드 | 값 | 소유자 |
|---|---|---|
| `pipelineStatus` | `RUNNING`, `PENDING`, `DONE`, `ERROR` | `scripts/modules/pipeline-status.ps1` |
| 호환 `status` | 완료: `DONE`, `DONE_WITH_TEST_FAILURES`, `DONE_WITH_TEST_ERRORS`, `DONE_WITH_PENDING` | 같은 상태 adapter |
| `testStatus` | `PASS`, `FAIL`, `ERROR`, `PENDING` | Core `ResultEvaluator` |

네 완료 호환 값은 모두 `pipelineCompleted=true`다. 테스트 FAIL/ERROR/PENDING을 인프라 ERROR로 바꾸지 않는다. 프로세스 시작 실패, timeout, 손상된 파일, report/video/cursor 계약 위반 또는 예외만 pipeline ERROR가 된다. catch 이후에도 이전 action 시도 증거로 `actualScenarioActionsExecuted`를 복원한다.

## 두 번 화면을 여는 이유

전체 자동 경로는 화면을 두 번 순회한다.

1. PlanOnly 순회: 현재 탭 순서와 선택지를 관찰하고 화면을 닫는다.
2. 실제 실행 순회: 확정된 물리 계획으로 컨트롤을 조작하고 화면을 닫는다.

두 순회는 같은 동작의 중복 실행이 아니다. 첫 순회에서는 시나리오 액션을 실행하지 않으며 결과도 `PENDING`이다.

## 대상 변경 경계

대상별 값은 코드가 아니라 데이터셋 `targetProfile`에 둔다.

- 창 식별: `targetProfile.window`
- 화면 ID 형식: `targetProfile.screenIdPattern`
- 설치·MAP: `targetProfile.map`
- 화면 목록: `screens[]`
- 입력과 기대 결과: `variables[]`
- 선택적 계좌 조합: `accounts[]`

화면 내부 ID, AutomationId, 업무 탭·버튼 의미와 confirmation matcher는 `targets/<vendor>/<screen>/target-profile.json`이 소유한다. generic `src`, `scripts`, `tools`에는 target literal을 두지 않으며 `target-literal-boundary.tests.ps1`가 이를 검사한다.

엔진은 등록된 화면 ID만 열며, 요청한 ID가 데이터셋에 없으면 조작 전에 중단한다.

## 실제 HTS에서만 확인 가능한 항목

다음은 정적·Fake 검증으로 PASS 처리하지 않는다.

- 설치별 UIA provider의 RuntimeId와 지원 pattern, native fallback 안정성
- 실제 PlanOnly discovery의 `control-plan.json`과 runtime binding drift
- 실제 popup, window text, log, screenshot evidence의 완전성
- 녹화·cursor audit·XLSX까지 포함한 recorded pipeline 완료 증거
- 주문·매수·매도·정정·취소·이체·출금 등 상태 변경 결과

마지막 항목은 이 저장소 검증 절차에서 실행하지 않으며 상태는 `PENDING`이다.
