# 기존 실행 증거 Reporter 검증

## 검증 경계

2026-08-22에 로컬 `outputs`의 기존 결과를 읽기 전용으로 점검했다. 이 검증은 HTS, FlaUI bridge, 주문·매수·매도·정정·취소 동작을 새로 실행하지 않는다. 원본 JSON은 임시 폴더로 복사하고 Reporter가 만든 XLSX와 preview는 검증 뒤 임시 폴더와 함께 제거한다.

## 선택한 기존 run

`outputs/0101_automation/live-validation-v2-20260817-223514/results`를 사용했다. 이 run은 `dryRun=false`, FlaUI action attempt/success `2/2`, case 3개, Observation과 action 기록을 가진 과거 실행물이다. 기록된 legacy 상태는 FAIL 1개와 PASS 2개다.

다만 이 결과는 `actualScenarioActionsExecuted`와 canonical `test-results.json`이 도입되기 전 형식이다. 각 case에도 `testResult.executed`와 `testResult.evidencePresent`가 없다. 따라서 이번 검증은 기존 상태를 재평가하거나 새 계약의 PASS 증거로 승격하지 않고 `LEGACY_CASE_RESULTS_COMPATIBILITY`로만 표시한다.

## 대용량 호환 옵션

기본 Reporter는 XLSX와 함께 18개 시트 preview PNG를 만든다. 위 legacy run은 control 행 855개를 포함해 preview 동시 생성 경로에서 Windows 종료 코드 `-1073740791`로 종료됐다. `--skip-previews`는 XLSX와 상태 표현을 그대로 두고 파생 PNG만 생략하는 검증용 선택지다. 기본 동작은 바뀌지 않으며 기존 호출자는 수정할 필요가 없다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\dev\verify-existing-report-readonly.ps1 `
  -ReportDir .\outputs\0101_automation\live-validation-v2-20260817-223514\results
```

검증 결과:

- Reporter process exit: `0`
- 입력 JSON: 8개
- 원본 JSON SHA-256 변경: 0개
- 생성 XLSX: 약 386KB, ZIP signature `50-4B-03-04`
- preview PNG: 0개
- 실제 HTS/FlaUI 실행: 0회

## 남은 PENDING

현재 로컬 기존 실행물에는 새 계약의 `test-results.json`과 `actualScenarioActionsExecuted=true`를 함께 가진 run이 없다. 다음 안전한 조회 전용 실행이 생기면 같은 도구로 canonical TestResult 경로를 다시 검증해야 한다. 기존 legacy PASS는 이 문서만으로 새 PASS가 되지 않는다.
