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
| 컨트롤 라이브러리 | `scripts/modules/rule-control-exploration.ps1` | 아니요 | 발견, 탭 순서, MAP 결합, 실제 조작 |
| 마스킹 라이브러리 | `scripts/modules/report-sanitization.ps1` | 아니요 | 민감정보 제거 |

독립 실행 가능하다는 것은 필요한 입력 파일을 명시하면 상위 오케스트레이터 없이 해당 기능만 실행할 수 있다는 뜻이다. 라이브러리 파일은 `.` 연산자로 현재 PowerShell 스코프에 함수를 등록한다.

## 연결을 구성하는 파일

`config/pipeline.manifest.json`이 실행 파일의 논리 이름과 단계 순서를 정의한다. `scripts/modules/pipeline-common.ps1`의 다음 함수가 이 명세를 읽는다.

- `Get-RulePipelineManifest`: manifest와 필수 파일 존재 검증
- `Get-RulePipelineEntryPoint`: `targetRunner` 같은 논리 이름을 절대 경로로 변환
- `Get-RuleTargetContext`: 데이터셋의 대상 창·설치·화면 범위를 단일 객체로 정규화
- `Get-RuleTestPackContext`: 승인 TestPack의 내장 datasetSnapshot을 Runner 대상 컨텍스트로 정규화

각 실행 파일이 서로의 경로를 직접 반복해서 적지 않으므로 파일명이나 연결이 바뀌면 manifest 한 곳을 수정할 수 있다.

## 전체 호출 순서

```text
사용자
  |
  v
run-auto-scenario-pipeline.ps1
  |-- modules/pipeline-common.ps1
  |-- config/pipeline.manifest.json
  |-- HtsQa.Cli extract-map-models
  |     `-- Core/Maps/HtsMap.cs + Core/Installation/HtsInstallation.cs
  |-- HtsQa.Cli validate-test-pack
  |-- run-target-rule-suite.ps1 -TestPackPath ... -PlanOnly
  |     |-- modules/rule-control-exploration.ps1
  |     |-- HtsQa.FlaUi --stdio
  |     |     `-- FlaUI.Core + FlaUI.UIA3
  |     `-- modules/report-sanitization.ps1
  |-- HtsQa.Cli generate/validate/approve/compile
  |     `-- Core/Scenarios/RuleScenarioGeneration.cs + ScenarioPlanning.cs
  |-- HtsQa.Cli materialize/build-physical
  |     `-- Core/Scenarios/ScenarioPlanning.cs
  `-- run-target-rule-suite-recorded.ps1
        |-- record-desktop-frames.ps1
        |     `-- encode_frames_video.py
        |-- run-target-rule-suite.ps1
        |     `-- HtsQa.FlaUi --stdio
        `-- export-rule-results-xlsx.ps1
              `-- build-rule-results-workbook.mjs
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
| 실제 실행 | `case-results.json`, `summary.json`, 스크린샷 | Excel 생성기 |
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

엔진은 등록된 화면 ID만 열며, 요청한 ID가 데이터셋에 없으면 조작 전에 중단한다.
