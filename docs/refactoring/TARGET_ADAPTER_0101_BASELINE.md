# 0101 Target Adapter 분리 기준선

## 범위와 안전 경계

이 문서는 generic engine에 포함된 1Q HTS 0101 주문 화면 전용 지식의 이동 전 기준선이다. 이번 리팩터링의 검증 범위는 정적 검사, 순수 함수, checked-in import 산출물, Fake adapter와 dry-run으로 제한한다. 실제 HTS 주문·매수·매도·정정·취소 동작은 실행하지 않는다.

## 현재 책임과 중복 위치

| 책임 | 현재 generic 위치 | target 전용 내용 | 이동 목표 |
|---|---|---|---|
| 화면/창/MAP 식별 | 이동 전 `tools/import-0101-testcases.mjs`, 생성 dataset `targetProfile` | 화면 ID, 창 class/title, MAP family, 초기 MAP | `targets/1q-hts/0101/target-profile.json` |
| 상태형 탭 | importer, `hts-target-rule-discovery.ps1`, orchestration | `TAB_Ord`, 상태 context, option/verification control, `HT010115` | adapter의 `statefulControls` |
| 거래 확인 대화상자 | `hts-action.ps1` | 주문 버튼별 logical name, 확인 문구와 승인 버튼 matcher | adapter의 `transactionalDialogs` |
| 상태 저장/선행 검증 | target-rule context/discovery/orchestration | 주문 탭별 현재 상태와 Select/AssertSelected 선행 조건 | generic stateful-control 계약 |
| 0101 import | 이동 전 `tools/import-0101-testcases.mjs`, `scripts/import-0101-testcases.ps1` | workbook 시트/열, MAP remap, 주문 탭 step 생성 | `targets/1q-hts/0101/tools/import-testcases.mjs` |
| 0101 live wrapper | 이동 전 `scripts/run-0101-live-validation-v2.*` | 0101 고정 입력/출력 및 실행 편의 기능 | `targets/1q-hts/0101/scripts/run-live-validation-v2.*` |

## 이동 전 판정 행렬

`Test-HtsTransactionalConfirmationDialog`의 현재 동작은 다음과 같다. 이 단계에서는 안전성 개선을 섞지 않고 adapter로 그대로 이동한다.

| 입력 | 현재 결과 |
|---|---|
| 대상 버튼과 주문 확인 문구 및 승인 버튼 일치 | `true` |
| 다른 주문 verb지만 메시지에 일반 `주문` 토큰 존재 | `true` (기존 광범위 fallback) |
| 입력 오류/시스템 오류 신호 | `false` |
| 분류가 확인 요청이 아님 | `false` |

광범위 fallback은 알려진 위험이다. 의미 보존 리팩터링 이후 별도 안전성 변경으로만 좁힐 수 있다.

## Import 회귀 기준

체크인된 `outputs/0101_automation`의 기준값은 workbook 행 1,159건, MAP family 19개, scenario 1,159건, variable 457건, transactional 분류 26건, ManualReview 577건, 상태형 탭 context scenario 50건이다. 탭 값은 `0/매수`, `1/매도`, `2/정정/취소`다.

파일 경로나 생성기 표기처럼 adapter 이동으로 바뀌는 metadata는 회귀 기준에서 제외한다. 시나리오 의미, 순서, 변수, 안전 분류는 동일해야 한다.

## 계약 영향과 마이그레이션

- Dataset `targetProfile`에 optional `adapter` 계약을 추가한다. 기존 targetProfile은 계속 읽을 수 있지만 target 전용 상태/대화상자 기능은 adapter가 있을 때만 활성화한다.
- generic runner의 새 이름은 `TargetStateOverride`다. 기존 `OrderTabStateOverride` 호출은 PowerShell alias로 유지한다.
- 0101 import/live wrapper 경로는 `targets/1q-hts/0101/` 아래로 이동했다. 저장소 내부 문서와 호출 예시는 새 경로를 사용한다.
- Approved TestPack의 `datasetSnapshot.targetProfile.adapter`가 실행 계약의 단일 입력이다. Runner가 원본 dataset 또는 target 파일을 실행 중 다시 읽지 않는다.

## PENDING

- 실제 1Q HTS 창에서 adapter 기반 탐색·바인딩이 기존과 같은지는 이번 작업에서 실행하지 않는다.
- 확인 대화상자 실제 제출은 금지하며 PENDING으로 남긴다.
- 실제 주문 상태 변화가 필요한 모든 케이스는 실행하지 않으며 PASS로 기록하지 않는다.
