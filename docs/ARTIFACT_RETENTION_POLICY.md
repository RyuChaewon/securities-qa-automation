# 로컬 실행 산출물 보존 정책

이 정책은 실제 HTS 실행 증거를 공개 저장소에서 분리하면서도 결과를 재현할 수 있게 한다. 삭제보다 보존 경계를 먼저 결정하며, 분류가 불확실한 파일은 `PENDING_REVIEW`로 남긴다.

## 단일 결과 원본

`test-results.json`을 포함한 완성 TestResult JSON이 리포팅의 canonical source다. `summary.json`, `case-results.json`, Observation, 승인·계획 hash는 그 결과의 실행 맥락과 추적 근거다. XLSX는 이 JSON을 표현한 파생 산출물이며 JSON의 상태를 변경하거나 대신할 수 없다.

## 분류와 처리

| 분류 | 예 | 기본 처리 |
|---|---|---|
| `TRACKED_SOURCE` | 추적 중인 Dataset, 승인 파일 | `KEEP`; 자동 삭제 금지 |
| `PROTECTED_SOURCE_OR_APPROVAL` | 미추적 Dataset, 승인 JSON, 수동 원본 | `KEEP`; 자동 삭제 금지 |
| `CANONICAL_RUN_JSON` | `test-results.json`, `summary.json`, `case-results.json` | `KEEP_UNTIL_REVIEW`; 결과 검토와 hash 확인 전 삭제 금지 |
| `SENSITIVE_MEDIA_EVIDENCE` | PNG, MP4 | `REVIEW_BEFORE_DELETE`; 공개 Git 추적 금지 |
| `RAW_EXECUTION_EVIDENCE` | NDJSON, 로그, 텍스트 추적 | `REVIEW_BEFORE_DELETE`; 민감정보 검토 전 공유·삭제 금지 |
| `DERIVED_REPORT` | XLSX, XLSM | canonical JSON과 재생성 검증 뒤에만 삭제 후보 |
| `RUNTIME_MARKER` | `.start`, `.stop`, `.pid` | 관련 프로세스 종료 확인 뒤에만 삭제 후보 |
| `OTHER_JSON`, `UNKNOWN` | 자동 분류 불가 파일 | `PENDING_REVIEW`; 삭제 금지 |

영상·스크린샷·원시 로그에는 계좌, 창 제목, 사용자 로컬 환경이 포함될 수 있다. 이 파일은 회귀 fixture로 축소·비식별화하지 않는 한 Git에 추가하지 않는다.

## 삭제 승인 순서

1. `audit-local-artifacts.ps1`로 상대 경로, 분류, 크기를 읽기 전용으로 출력한다.
2. 삭제 후보보다 먼저 Dataset·승인·canonical JSON과 수동 증거를 `KEEP`으로 분리한다.
3. XLSX는 동일 JSON에서 다시 생성되는지, runtime marker는 관련 프로세스가 종료됐는지 확인한다.
4. 삭제할 정확한 상대 경로 목록을 검토하고 사용자 승인을 받는다.
5. 승인된 경로만 저장소 루트 안의 절대 경로로 다시 검증한 뒤 삭제한다.

이 저장소는 자동 보존기간 만료나 일괄 삭제 명령을 제공하지 않는다. 재생성 가능성이나 증거 가치가 불명확하면 삭제하지 않는다.

## 읽기 전용 감사

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\dev\audit-local-artifacts.ps1 `
  -IncludeFiles -AsJson
```

명령은 파일을 이동·수정·삭제하지 않으며 저장소 기준 상대 경로만 출력한다. 2026-08-22 점검 시 `outputs`에는 2,033개 파일, 약 2.70GB가 있었고 Git 추적 파일은 Dataset/승인 2개뿐이었다. 수동 testcase·report template 55개를 보호한 뒤 삭제 검토 후보는 파생 XLSX 59개와 runtime marker 85개였다. 이 점검에서는 로컬 증거 파일을 삭제하지 않았다.
