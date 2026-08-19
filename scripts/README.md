# PowerShell 명령 지도

대상에 연결되는 모든 명령은 `-DatasetPath <dataset.json>`을 필수로 받는다. 화면번호·설치 경로·창 클래스는 스크립트 기본값이 아니라 해당 데이터셋의 `targetProfile`과 `screens[]`에서 읽는다.

## 기본 실행

| 파일 | 용도 |
|---|---|
| `run-auto-scenario-pipeline.ps1` | MAP 추출부터 실제 실행·녹화·Excel까지 전체 자동 흐름 |
| `run-target-rule-suite.ps1` | DryRun, PlanOnly 또는 실제 화면 실행 |
| `run-target-rule-suite-recorded.ps1` | 실제 실행과 전체 HTS 창 녹화 병행 |
| `invoke-scenario-pipeline.ps1` | 외부 시나리오 요청·반입·승인·바인딩 단계 실행 |

## 계획·보고서

| 파일 | 용도 |
|---|---|
| `plan-scenario-bindings.ps1` | 논리 시나리오를 현재 런타임 컨트롤에 PlanOnly 결합 |
| `export-rule-results-xlsx.ps1` | JSON 결과를 한국어 Excel로 변환 |
| `merge-target-rule-runs.ps1` | 여러 실행 결과와 영상을 인수 폴더로 병합 |
| `sanitize-rule-report.ps1` | 기존 결과의 민감정보를 제거한 사본 생성 |
| `export-chatgpt-scenario-package.ps1` | 선택적 외부 시나리오 요청 묶음 생성 |

## 진단·개발

| 파일 | 용도 |
|---|---|
| `diagnose-target-windows.ps1` | 표시 중인 대상 창 후보 읽기 |
| `inspect-hts-controls.ps1` | 자식 HWND 구조 읽기 |
| `inspect-hts-tab-order.ps1` | 실제 탭 순서와 포커스 변화 수집 |
| `restore-hts-main-window.ps1` | 테스트 전 메인 창 복구 |
| `record-desktop-frames.ps1` | 대상 전체 창 프레임과 MP4 생성 |
| `dev/verify-source-layout.ps1` | 폴더·manifest·주석 헤더·PowerShell 구문 검증 |

진단 명령도 동일한 대상 계약을 사용한다.

```powershell
.\scripts\diagnose-target-windows.ps1 `
  -DatasetPath <dataset.json> `
  -OutputPath .\reports\window-diagnostic.json

.\scripts\inspect-hts-tab-order.ps1 `
  -DatasetPath <dataset.json> `
  -ScreenNumber <화면ID> `
  -OutputDir .\reports\tab-order
```

## 내부 모듈

`modules`의 파일은 직접 실행하지 않는다. 공개 명령이 dot-source하며 경로는 `config/pipeline.manifest.json`에 기록한다.

- `modules/pipeline-common.ps1`
- `modules/rule-control-exploration.ps1`
- `modules/report-sanitization.ps1`

공개 명령을 추가할 때는 파일 헤더에 역할·입출력·부작용을 적고 manifest에 논리 진입점이 필요한지 먼저 판단한다. 공통 함수가 두 명령 이상에서 사용될 때만 `modules`로 이동한다.
