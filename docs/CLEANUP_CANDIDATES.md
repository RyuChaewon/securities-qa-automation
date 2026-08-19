# 정리 후보

다음 경로는 현재 `config/pipeline.manifest.json`, 솔루션 또는 활성 스크립트가 참조하지 않는 과거 생성물이다. 대용량 재귀 삭제는 복구가 어려우므로 별도 승인 후 수행한다.

| 경로 | 점검 시 크기 | 분류 | 처리 제안 |
|---|---:|---|---|
| `.venv` | 약 800MB | 제거된 Kanana 경로의 구형 Python 환경 | 삭제 |
| `reports` | 약 775MB | 범용화 이전 실행 결과와 중복 영상 | 전체 삭제 후 빈 출력 폴더 재생성 |
| `artifacts`의 구형 하위 폴더 | 약 52MB 이상 | 이전 정적·드라이런 중간 산출물 | 아래 최신 검증 3개를 제외하고 삭제 |
| `exports` | 약 0.4MB | 이전 외부 시나리오 패키지 | 전체 삭제 후 빈 출력 폴더 재생성 |
| `data/scenarios/inbox/GEN-449dd01c8d6e` | 약 0.5MB | 현재 프로필·계획 해시와 연결되지 않은 외부 생성 결과 | 삭제 |
| `tools/HtsQa.SampleTarget` | 약 0.4MB | 프로젝트 원본 없이 남은 `bin/obj` | 삭제 |
| `models`, `prompts`, `services` | 비어 있음 | 제거된 LLM 구조의 빈 폴더 | 삭제 |

`archive/대표동영상`의 대표 영상 3개, `.dotnet-home`, `node_modules`는 각각 보존 기록, .NET 빌드, Excel 생성에 사용하므로 정리 대상이 아니다.

이번 변경의 인수 증적인 `artifacts/generic-target-static-20260811`, `artifacts/non07-static-smoke-20260811-v2`, `artifacts/non07-dryrun-report-20260811`도 보존한다.

정리 전에는 각 절대 경로가 현재 저장소 루트 아래인지 다시 검증한다. 정리 후 빌드·단위 테스트·정적 자동 파이프라인을 재실행해 누락 참조가 없는지 확인한다.
