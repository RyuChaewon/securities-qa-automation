# 기존 영상·스크린샷 읽기 전용 검증

## 범위

기존 `outputs/0101_automation/live-validation-v2-20260817-223514` run만 사용했다. 검증 중 HTS, FlaUI bridge, 화면 입력, 녹화 프로세스는 시작하지 않았다. JSON과 참조 스크린샷은 시스템 임시 폴더로 복사했고 검증 후 임시 산출물을 제거했다. 원본 MP4는 복사·변환하지 않고 header와 SHA-256만 읽었다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\dev\verify-existing-report-readonly.ps1 `
  -ReportDir .\outputs\0101_automation\live-validation-v2-20260817-223514\results `
  -IncludeEvidenceMedia `
  -VideoPath .\outputs\0101_automation\live-validation-v2-20260817-223514\full-run.mp4
```

## 검증 결과

- case 결과가 참조한 screenshot: 1개
- 실제 복사 가능한 screenshot: 1개, 85,461 bytes
- 생성 XLSX의 `xl/media` entry: 1개
- JSON과 screenshot 원본 SHA-256 변경: 0개
- 기존 MP4: 1개, 8,644,507 bytes
- MP4 `ftyp` signature: 유효
- MP4 SHA-256 변경: 0개
- Reporter/Node exit: 0
- 새 녹화·실제 HTS 동작: 0회

Reporter의 영상 계약은 MP4를 XLSX 안에 넣는 것이 아니다. XLSX에는 case가 참조한 오류 screenshot만 포함하고, MP4는 같은 run의 별도 민감 증거로 보존한다. 영상과 screenshot 원본은 Git에 추가하지 않았다.

## 상태 해석

이 검증은 파일 무결성과 Reporter 첨부 경로만 확인한다. 선택한 run은 legacy 결과이므로 기존 PASS/FAIL을 새 ResultEvaluator 결과로 재판정하지 않는다. 새 canonical `test-results.json`과 함께 생성된 실제 조회 전용 media 검증은 계속 `PENDING`이다.
