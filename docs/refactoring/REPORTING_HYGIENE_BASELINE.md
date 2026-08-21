# Reporting 책임 분리 및 저장소 위생 기준선

## 안전 경계

Reporter는 `HtsQa.Core.ResultEvaluator`가 완성한 `TestResult`를 표시만 한다. 상태를 다시 계산하거나 `PASS`, `FAIL`, `ERROR`, `PENDING`을 다른 값으로 승격·강등하지 않는다. `test-results.json`을 canonical 판정 원본으로 사용하며, `case-results.json`은 화면·입력·증거를 표현하기 위한 보조 view source다. XLSX, PNG preview, video와 inspection log는 모두 JSON에서 파생되는 생성 산출물이다.

이번 작업에서는 실제 HTS를 실행하지 않는다. 주문·매수·매도·정정·취소 및 확인 대화상자 제출도 실행하지 않는다.

## 현재 Reporting 흐름

```text
ResultEvaluator
  -> test-results.json (canonical TestResultDocument)
  -> case-results.json + summary.json (표시 컨텍스트)
  -> scripts/modules/hts-reporting.ps1
  -> tools/build-rule-results-workbook.mjs
  -> 테스트결과.xlsx + preview PNG + inspection NDJSON
```

이동 전 `build-rule-results-workbook.mjs`는 1,252줄이며 JSON 읽기, optional source 처리, 상태 표시 변환, 시트별 행 생성, XLSX 렌더링, preview/inspection/output 경로 관리를 한 파일에서 수행한다.

## 삭제·추적 제외 후보

아래 파일은 모두 로컬에 보존한 채 Git 추적에서만 제외할 후보다. 원본 workbook과 실제 실행 증거 폴더는 삭제하지 않는다.

| 후보 | 크기 | 분류 | 처리 근거 |
|---|---:|---|---|
| `outputs/0101_automation/compiled-plan.json` | 6,684,791 B | 생성 가능 | scenario compiler 파생물 |
| `outputs/0101_automation/generated-scenarios.json` | 4,566,669 B | 생성 가능 | target importer 파생물 |
| `outputs/0101_automation/map-screen-models.json` | 5,730,903 B | 생성 가능/설치 종속 | MAP extractor 파생물이며 로컬 파일은 보존 |
| `outputs/0101_automation/scenario-validation.json` | 37,166 B | 생성 가능 | validator 파생물 |
| `outputs/0101_automation/import-summary.json` | 745 B | 생성 가능/경로 포함 | importer 파생물이며 로컬 절대 경로 포함 |
| `outputs/0101_automation/representative-plan/compiled-plan.json` | 7,788,549 B | 생성 가능 | representative compiler 파생물 |
| `outputs/0101_automation/representative-plan/scenario-review-items.json` | 13,370 B | 생성 가능 | compiler 검토 목록 |
| `outputs/0101_automation/representative-plan/representative-validation.json` | 5,111 B | 생성 가능 | validator 파생물 |
| `outputs/0101_automation/representative-plan/plan-summary.json` | 1,121 B | 생성 가능 | compiler 요약 |

합계는 24,828,425 B(약 23.68 MiB)다.

## 보존 및 PENDING

- `outputs/0101_automation/0101.dataset.json`: 최소 Dataset 기준이므로 유지한다.
- `outputs/0101_automation/scenario-approval.json`: 26개 review decision, 577개 scenario decision, 106개 coverage-gap decision의 수동 승인 증거이므로 유지한다.
- ignored 상태의 로컬 XLSX, MP4, screenshot, log, 실행 폴더: 생성물과 수동 증거가 섞여 있으므로 삭제하지 않는다. 별도 보존 정책 확정 전까지 PENDING이다.
- `outputs/0101_screen_testcases/*.xlsx`: importer 원본/수동 자료이므로 삭제하지 않는다.

## 공개 계약과 마이그레이션

- `node tools/build-rule-results-workbook.mjs <report-dir> [output-file]` 호출은 유지한다.
- 기존 `summary.json`과 `case-results.json`은 표시 컨텍스트로 계속 읽는다.
- 새 canonical 입력은 같은 report directory의 `test-results.json`이다. legacy report에 이 파일이 없으면 기존 `case-results[].testResult`를 검증 가능한 범위에서 사용하되 새 실행 경로는 `test-results.json`을 필수로 생성한다.
- `OrderTabStateOverride` 등 실행 계약과 TestPack 승인 계약은 변경하지 않는다.

## 적용 결과

- golden fixture는 `tests/fixtures/reporting/rule-results/`에 두고 대용량 실행 산출물을 회귀 입력으로 사용하지 않는다.
- `outputs/0101_automation/`에서 Dataset과 수동 승인 증거만 추적하며 나머지 생성 JSON은 로컬에 보존한 채 Git 추적에서 제외한다.
- `import-summary.json.sourceWorkbook`은 필드명을 유지하고 파일명만 기록한다. 전체 로컬 경로가 필요한 내부 작업은 importer 호출 인자를 별도로 보존한다.
