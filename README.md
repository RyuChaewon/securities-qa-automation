# 범용 HTS 화면 룰 기반 QA

LLM 없이 데이터셋, 설치 MAP, **FlaUI UIA3**, Windows HWND와 실제 탭 순서를 결합해 지정한 HTS 화면군을 테스트한다. 저장소에 포함된 계좌정보 화면군은 대상 데이터셋의 한 예일 뿐 엔진의 고정 범위가 아니다.

현재 제공하는 설치 카탈로그·MAP 어댑터는 1Q HTS의 숫자 4자리 화면 및 `HTnnnnss` 규약을 해석한다. 같은 규약의 다른 화면군은 데이터셋만 추가하면 되고, 다른 벤더나 비숫자 화면 체계는 Core/실행기를 재사용한 별도 정적 모델 어댑터를 연결한다.

## 빠른 실행

기본 예시 데이터셋으로 전체 파이프라인을 실행한다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run-auto-scenario-pipeline.ps1 `
  -DatasetPath .\data\rule-tests\1q-hts-account-inquiry.dataset.json `
  -TestPackPath <approved-test-pack.json> `
  -AllowElevatedActionPrompt
```

실제 HTS를 조작하지 않는 정적 검증은 `-StaticOnly`, 화면을 열어 바인딩까지만 수행하는 검증은 `-PrepareOnly`를 사용한다. 두 모드는 실제 테스트 PASS가 아니라 `PENDING`이다.

```powershell
.\scripts\run-auto-scenario-pipeline.ps1 -DatasetPath <dataset.json> -TestPackPath <approved-test-pack.json> -StaticOnly
.\scripts\run-auto-scenario-pipeline.ps1 -DatasetPath <dataset.json> -TestPackPath <approved-test-pack.json> -PrepareOnly
```

## 새 대상 설정

[target-template.dataset.json](data/rule-tests/target-template.dataset.json)을 복제한 뒤 다음만 대상 환경에 맞게 수정한다.

- `targetProfile.id`, `displayName`, `runLabel`
- `targetProfile.screenIdPattern`
- `targetProfile.window.className`, `titlePrefix`
- `targetProfile.map.installationRoot`, `screenDirectory`, `families[]`
- `screens[]`
- 필요한 `variables[]`, 선택적 `accounts[]`

계좌 입력이 없는 화면군은 `accounts`를 비워 둘 수 있다. 실행기는 `default` 실행 컨텍스트 한 건을 자동 생성한다. 날짜는 `yyyyMMdd`, 체크 상태는 문자열 `true`/`false`, 콤보는 표시문자 또는 인덱스를 사용한다.

`data/rule-tests/1q-hts-non07-static-smoke.dataset.json`은 기본 화면군 밖의 한 화면과 빈 계좌 목록으로 범용화를 검증하는 읽기 전용 `-StaticOnly` 회귀 예시다.

```powershell
dotnet run --project .\src\HtsQa.Cli -c Release --no-build -- `
  validate-rule-dataset --file <dataset.json>
```

## 실행 구조

[pipeline.manifest.json](config/pipeline.manifest.json)이 실행 파일과 단계 연결을 기계 판독 가능한 형태로 정의한다.

```text
run-auto-scenario-pipeline.ps1
  -> HtsQa.Cli: Dataset 검증 + Approved TestPack 검증
  -> HtsQa.Cli: MAP 추출
  -> run-target-rule-suite.ps1 -TestPackPath ... -PlanOnly
       -> HtsQa.FlaUi --stdio (FlaUI.UIA3 탐색)
  -> HtsQa.Cli: 생성·검증·승인·컴파일·바인딩
  -> run-target-rule-suite-recorded.ps1
       -> record-desktop-frames.ps1
       -> run-target-rule-suite.ps1
            -> HtsQa.FlaUi --stdio (FlaUI.UIA3 조작)
       -> export-rule-results-xlsx.ps1
            -> build-rule-results-workbook.mjs
```

- `run-auto-scenario-pipeline.ps1`: 전체 단계를 연결하는 기본 오케스트레이터
- `run-target-rule-suite.ps1`: Approved TestPack만 받아 DryRun, PlanOnly, 실제 실행을 수행하는 핵심 실행기
- `HtsQa.FlaUi`: FlaUI UIA3의 요소 탐색과 Value/Invoke/Toggle/Selection/Range 패턴 호출을 제공하는 .NET 8 상주 브리지
- `run-target-rule-suite-recorded.ps1`: 녹화와 실행기를 동시에 구동하는 독립 래퍼
- `record-desktop-frames.ps1`: 대상 프로필의 전체 메인 창만 녹화하는 독립 도구
- `export-rule-results-xlsx.ps1`: 기존 JSON 결과를 Excel로 변환하는 독립 도구
- `scripts/modules/*`: 직접 실행하지 않고 공개 명령이 dot-source하는 경로·컨트롤·마스킹 공통 라이브러리

자세한 연결과 독립 실행 계약은 [ARCHITECTURE.md](docs/ARCHITECTURE.md), 책임별 파일 위치와 수정 경계는 [PROJECT_STRUCTURE.md](docs/PROJECT_STRUCTURE.md)에 있다.

## 0101 주문 화면 자동화

`targets/1q-hts/0101/tools/import-testcases.mjs`는 target profile과 `0101_TC` 시트를 읽어 `TC_ID`를 유지한 실행 시나리오로 변환한다. 0101에 속한 19개 MAP family를 모두 카탈로그화하며, 바인딩은 `내부화면코드|컨트롤ID|상태컨텍스트`를 사용한다. 화면·MAP·탭·버튼·확인 문구는 `targets/1q-hts/0101/target-profile.json`이 단일 소스다.

현재 공개 산출물에는 승인된 1,239개 케이스와 6,730개 단계, MAP 모델, 정적 검증 및 대표 계획이 포함된다. 실제 화면 검증 상태와 공개 범위는 [0101_VALIDATION_STATUS.md](docs/0101_VALIDATION_STATUS.md), 실행 절차와 거래 안전 조건은 [0101_AUTOMATION.md](docs/0101_AUTOMATION.md)에 정리되어 있다.

## FlaUI UIA3 실행기

`src/HtsQa.FlaUi`는 `FlaUI.Core`와 `FlaUI.UIA3` 5.0.0을 사용한다. 핵심 실행기는 브리지를 한 번 시작하고 NDJSON 요청을 순차 전송한다.

1. 화면 HWND를 UIA3 루트로 제한한다.
2. RuntimeId, AutomationId, Name, ClassName, ControlType, 절대 좌표와 지원 패턴을 수집한다.
3. 동작 직전에 RuntimeId를 우선으로 요소를 다시 찾고 HWND·속성·좌표를 보완 선택자로 사용한다.
4. 텍스트는 ValuePattern, 버튼은 InvokePattern, 체크는 TogglePattern, 라디오·목록은 SelectionItemPattern, 탭·범위는 FlaUI 래퍼/RangeValuePattern으로 실행한다.
5. UIA 공급자가 패턴이나 항목을 노출하지 않을 때만 기존 Win32 경로로 내려가며, `summary.json`과 Excel에 fallback 횟수와 이유를 기록한다.

브리지 프로토콜만 확인하는 명령은 다음과 같다.

```powershell
'{"requestId":"smoke","operation":"ping","rootHwnd":0}' | `
  dotnet .\src\HtsQa.FlaUi\bin\Release\net8.0-windows7.0\HtsQa.FlaUi.dll --stdio
```

## 안전·판정 원칙

- 모든 마우스·키보드 입력은 대상 메인 창과 현재 화면 콘텐츠 경계 안에서만 허용한다.
- 한 화면의 조작과 팝업·연계 화면 정리가 끝난 뒤 다음 화면을 연다.
- MAP 정의를 기준 모델로 사용하고 FlaUI UIA3를 기본 탐색·조작 수단, HWND/탭 순회를 수명주기 확인과 비지원 컨트롤 보완 수단으로 사용한다.
- 의도한 잘못된 입력의 정상 거부는 제품 결함으로 보지 않는다.
- 시스템·통신·인증·프로그램 실패와 기대 결과 위반만 결함 후보로 판정한다.
- 실행하거나 관찰하지 않은 결과는 PASS가 아니라 `PENDING`이다.
- 비밀번호 원문은 JSON, 로그, Excel에 저장하지 않는다.

상세 정책은 [ERROR_JUDGMENT_POLICY.md](docs/ERROR_JUDGMENT_POLICY.md)를 따른다.

## 빌드와 검증

```powershell
$env:DOTNET_CLI_HOME=(Join-Path (Get-Location) '.dotnet-home')
dotnet restore .\HtsQaPoc.sln
dotnet build .\HtsQaPoc.sln -c Release --no-restore
dotnet test .\HtsQaPoc.sln -c Release --no-build --no-restore
```

통합 테스트는 실제 WinForms 창을 STA 스레드에 표시하고 FlaUI UIA3가 텍스트, 목록, 체크, 라디오, 탭, 버튼 상태를 바꾸는지 확인한다. UIA 공급자가 콤보 항목을 숨기는 경우에는 성공으로 가장하지 않고 `fallbackRequired` 계약을 검증한다.

## 산출물

기본 전체 실행은 `reports\{targetProfile.runLabel}-자동시나리오-{기준일}-{시각}` 아래에 생성된다.

```text
map-catalog.json
runtime-discovery/control-plan.json
generated-rule-scenarios.json
scenario-validation.json
automatic-approval.json
compiled-plan.json
binding-catalog.json
physical-plan.json
recorded-run/full-run.mp4
recorded-run/results/summary.json
recorded-run/results/case-results.json
recorded-run/results/테스트결과-*.xlsx
```

0101의 매도 탭 및 정정/취소 탭 대표 케이스는 로그인 HTS에서 실제 좌표 클릭, 상태별 버튼 재바인딩, 커서 감사까지 통과했다. 주문 확인창을 최종 제출하는 거래 검증은 아직 수행하지 않았으며 상태는 `PENDING`이다. 원시 영상·스크린샷·실행 로그는 계좌 정보와 로컬 환경 정보가 포함될 수 있어 공개 저장소에서 제외한다.

## 관련 문서

- [ARCHITECTURE.md](docs/ARCHITECTURE.md): 실행 파일 연결과 데이터 흐름
- [CODE_GUIDE.md](docs/CODE_GUIDE.md): 코드 수정 위치와 확장 규칙
- [USER_GUIDE.md](docs/USER_GUIDE.md): 새 대상 데이터셋 작성과 실행 방법
- [SCENARIO_PIPELINE.md](docs/SCENARIO_PIPELINE.md): 자동·외부 시나리오 경로
- [0101_AUTOMATION.md](docs/0101_AUTOMATION.md): 0101 Importer, 바인딩, 실제 실행 계약
- [0101_VALIDATION_STATUS.md](docs/0101_VALIDATION_STATUS.md): 현재 계획·실화면 검증 상태와 공개 범위
- [ARTIFACT_RETENTION_POLICY.md](docs/ARTIFACT_RETENTION_POLICY.md): 로컬 JSON·XLSX·영상·로그의 보존 및 삭제 승인 경계
- [CLEANUP_CANDIDATES.md](docs/CLEANUP_CANDIDATES.md): 미사용 대용량 생성물과 보존 항목
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): 실행 오류 대응
