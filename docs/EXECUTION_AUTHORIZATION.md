# 컨트롤 승인과 환경 실행 승인

이 문서는 실제 HTS action 전에 재사용할 두 승인 계약을 정의한다. 정책 근거는 Core 계약, 승인된 Control Repository, TargetAdapter 정책과 실제 단말의 반복 관측 증거다. 비공식 체크리스트 PDF는 승인·해시·합격 기준의 근거가 아니다.

## 두 승인 책임

| 구분 | 승인 대상 | 재사용 단위 | 저장 위치 |
|---|---|---|---|
| Control approval | 하나의 논리 control과 안정 locator·업무 역할·risk·action 계약 | 계약이 바뀌지 않은 모든 run | 기존 `ControlRepositoryEntry.Approval`, `ApprovalPayloadHash`, `ControlContractHash` |
| Environment execution authorization | 분류된 비운영 환경과 허용 실행 scope | fingerprint·scope·만료가 유지되는 모든 scenario와 plan | `ExecutionAuthorizationDocument`와 기존 `TestPackApprovalOverlay` 형식의 사람 승인 provenance |

Control approval은 기존 TestPack approval overlay를 그대로 재사용한다. 신규 안정 계약 metadata가 모두 있는 entry에서는 `ApprovalPayloadHash`와 `ApprovedContentHash`가 `ControlContractHash`를 담는다. 구형 entry는 기존 locator payload hash로 계속 읽고 검증하지만, 안정 계약 metadata와 `ControlContractHash`가 없으므로 새 physical execution authorization에는 사용할 수 없다. 별도 control 승인 원장이나 자동 승격은 없다.

Environment authorization도 승인 입력 형식을 새로 발명하지 않는다. Core가 만든 pending overlay에 사람이 승인자, 승인 시각, 근거를 명시한 뒤 동일 hash를 검증해 적용한다. TestPack hash나 planHash는 이 승인 입력이 아니다.

## ControlContractHash

Canonical 입력:

- target profile ID
- `screen|map|logicalName|stateContext` canonical key
- expected control kind와 사람이 확인한 업무 역할
- locator trust tier
- stable UIA/native identity 또는 승인된 MAP/runtime binding
- anchored relative locator일 때 coordinate space, normalized rectangle, anchor와 visual signature 계약
- allowed/forbidden physical action
- risk classification과 transactional role
- locator tier별 실행 직전 preflight 요구사항

제외 입력:

- 세션 RuntimeId와 HWND
- 창의 현재 위치·크기와 변환된 desktop point
- 정상적인 DPI transform 결과
- capture/review/실행 시각
- source/evidence 경로와 실행 결과
- 현재 입력값·표시값
- 계좌번호, 비밀번호, 사용자 ID, token 등 민감정보

Anchor의 현재 관측값은 저장된 hash를 다시 만드는 입력이 아니다. 실행 직전 승인 anchor와 비교하며 normalized 좌표 차이가 `0.0025` 이하면 정상 transform으로 취급한다. coordinate space나 anchor ID가 다르거나 허용 오차를 넘으면 `AUTH.CONTROL_PREFLIGHT_DRIFT`로 차단한다.

## EnvironmentFingerprint와 ExecutionAuthorizationHash

`EnvironmentFingerprint` 입력:

- target ID
- HTS product classification
- redacted executable/install/version fingerprint
- host classification과 redacted machine fingerprint
- Test/Simulation/Production 환경 분류
- server/routing classification
- Test/Real account 분류
- automation adapter version
- 중요 execution policy version

로그인 세션, 재부팅 횟수, 테스트 데이터, scenario/CaseId, TestPack hash, planHash, endpoint 원문, 계좌번호, 사용자 ID, token, 비밀번호는 입력에 없다.

`ExecutionAuthorizationHash`는 `EnvironmentFingerprint.Hash`와 정규화한 scope만 포함한다. Scope에는 target/screen/MAP, allowed action/risk, transactional 허용 여부, order type, 선택적인 case/quantity/amount 제한, 만료 시각과 policy schema/version이 들어간다. 승인자·승인 시각·근거는 provenance이며 canonical hash 입력은 아니다.

## 재승인 truth table

| 변화 | Control 재승인 | Environment 재승인 | 결과 |
|---|---:|---:|---|
| HTS 재로그인, 새 session, RuntimeId/HWND 변화 | 아니요 | 아니요 | 실행 직전 관측은 다시 수행 |
| 창 이동·resize, 정상 DPI transform | 아니요 | 아니요 | bounds/DPI preflight만 재계산 |
| 테스트 데이터, scenario, CaseId, TestPack hash, planHash 변화 | 아니요 | 아니요 | 기존 scope 안인지 다시 판정 |
| AutomationId/native identity, MAP/runtime 계약 변화 | 해당 control만 필요 | 아니요 | `ControlContractDrift` |
| logicalName/state/control kind/business role 변화 | 해당 control만 필요 | 아니요 | `ControlContractDrift` |
| anchor 허용 오차 초과, risk/action/transactional role 변화 | 해당 control만 필요 | scope도 넓어지면 필요 | fail-closed |
| HTS executable/install/version fingerprint 변화 | 아니요 | 필요 | `EnvironmentDrift` |
| host, routing, Test/Production, Test/Real account 분류 변화 | 아니요 | 필요 | `EnvironmentDrift` |
| adapter·중요 policy version 변화 | 필요할 때 해당 control | 필요 | `EnvironmentDrift` 또는 contract drift |
| scope 확대·제한 상향·transaction 허용 추가 | 관련 control 변경 시 필요 | 필요 | 기존 승인 hash 불일치 |
| 승인 만료 | 아니요 | 필요 | `AuthorizationExpired` |

Test/Simulation 환경 승인은 Production 또는 Real account 환경에서 재사용할 수 없다. Production/Real account의 transactional automation은 일치하는 문서가 있어도 `AUTH.PRODUCTION_TRANSACTION_FORBIDDEN`으로 차단한다.

## Core 판정 순서

1. 현재 environment input을 정규화하고 fingerprint를 계산한다.
2. 승인 문서 schema, canonical hash, 사람 승인 provenance와 만료를 검증한다.
3. 현재 fingerprint와 승인 fingerprint를 비교한다.
4. target/screen/MAP/action/risk/order type과 선택 limit을 scope와 비교한다.
5. 각 repository key가 유일하고 신규 stable `ControlContractHash`로 승인됐는지 검증한다.
6. physical action이면 read-only current control observation을 승인 계약과 비교한다.
7. transactional action이면 stable UIA/native identity, control approval, environment authorization, non-production/test-account 정책을 모두 검증한다.
8. 모든 조건이 맞을 때만 `Authorized`를 반환한다.

판정 결과는 TestResult가 아니다. Action 전 승인 실패는 pipeline/configuration blocker로 남고 ResultEvaluator의 PASS/FAIL을 만들거나 변경하지 않는다. Reporter와 PowerShell은 canonical decision을 표시·전달할 뿐 다시 판정하지 않는다.

| 상태 | 대표 code | 의미 |
|---|---|---|
| `Authorized` | 없음 | 모든 승인·scope·preflight 조건 일치, action은 아직 0회 |
| `ControlApprovalRequired` | `AUTH.CONTROL_APPROVAL_REQUIRED`, `AUTH.CONTROL_CONTRACT_HASH_REQUIRED` | 등록·승인 또는 run plan의 안정 contract hash 고정 누락 |
| `EnvironmentApprovalRequired` | `AUTH.ENVIRONMENT_APPROVAL_REQUIRED` | 환경 승인 누락 |
| `AuthorizationExpired` | `AUTH.AUTHORIZATION_EXPIRED` | scope 만료 |
| `ScopeViolation` | `AUTH.SCOPE_*`, `AUTH.TRANSACTION_*` | target/action/risk/limit/거래 정책 범위 초과 |
| `EnvironmentDrift` | `AUTH.ENVIRONMENT_DRIFT` | 환경 fingerprint 변화 |
| `ControlContractDrift` | `AUTH.CONTROL_CONTRACT_DRIFT`, `AUTH.REPOSITORY_TARGET_MISMATCH`, `AUTH.CONTROL_PREFLIGHT_DRIFT` | 승인 contract, repository target 또는 current observation 변화 |
| `ConfigurationRequired` | `AUTH.CONFIGURATION_REQUIRED`, `AUTH.CONTROL_PREFLIGHT_REQUIRED` | 분류·관측 입력 부족 |
| `InvalidAuthorization` | `AUTH.HASH_MISMATCH`, `AUTH.INVALID_AUTHORIZATION` | schema/hash/provenance 위·변조 또는 구조 오류 |

## CLI와 PowerShell

```text
create-execution-authorization-approval --request <draft.json> [--out <approval.json>]
apply-execution-authorization-approval --request <draft.json> --approval <approval.json> [--out <authorization.json>]
check-execution-authorization --request <check.json> --checked-at <ISO8601> [--out <decision.json>]
```

`scripts/modules/hts-order-scenario-authoring.ps1`의 대응 함수는 위 인수를 그대로 전달한다. CLI와 PowerShell은 hash, scope, risk 또는 verdict를 계산하지 않는다.

Order scenario validator는 Core authorization decision을 validation report에 포함한다. 정적 검증과 승인 검증을 모두 통과한 immutable DryRun plan만 `AuthorizationStatus=Authorized`, environment hash, authorization hash와 step별 `ControlContractHash`를 고정한다. DryRun은 이 값을 검증해도 UI/transactional action count를 항상 0으로 유지하고 상태는 `PENDING`이다.

향후 실제 executor는 physical action 직전에 `IExecutionAuthorizationService`를 호출해야 한다. 이번 단계에서는 executor와 연결하거나 HTS/FlaUI를 실행하지 않는다.

## 현재 0101 경계

`targets/1q-hts/0101/control-repository.json`은 승인 entry가 0개이고 State Graph 후보는 `ConfigurationRequired`다. 승인 transition, baseline, restore, locator와 product Checkpoint가 실제 단말 증거로 확정되지 않았다. 따라서 현재 0101 scenario는 이 계약을 추가해도 `ConfigurationRequired` 또는 `PENDING`이며 실제 실행 가능 상태가 아니다.

7A 현장 캘리브레이션 진입 전 다음 증거가 필요하다.

- 동일 state에서 반복 관측한 stable UIA/native 또는 MAP/runtime identity
- 사람이 확인한 logicalName, control kind, 업무 역할, risk, allowed/forbidden action
- 승인 stateContext와 State Graph arrival/restore Checkpoint
- redacted executable/install/version, host, routing, Test/Simulation, Test account 분류
- target별 adapter version과 중요 execution policy version
- 비거래 action부터 시작하는 제한 scope와 만료·근거

위 항목을 실제 Windows 단말에서 확보하기 전까지 현장 검증은 `PENDING`이다.
