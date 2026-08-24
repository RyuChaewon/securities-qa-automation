# 주문화면 캘리브레이션 및 시나리오 작성

## 현재 기준선

이 워크플로우는 승인된 Control Repository key로만 주문화면 시나리오를 작성한다. 실제 locator, 좌표, 상태 전환, 업무 규칙을 생성하거나 추정하지 않는다. `targets/1q-hts/0101/control-repository.json`은 현재 `ConfigurationRequired`, 승인 entry 0개다. 0101 State Graph의 `buy`, `sell`, `modify-cancel` 후보도 모두 `ConfigurationRequired`이고 transition, baseline, restore 경로가 없다. 따라서 0101 템플릿 3종은 모두 실행 불가다.

`사내 단말 화면 테스트 체크리스트 정제본.pdf`는 `ReferenceOnly` 후보일 뿐 expected mode, RuleID, 합격 기준, locator 또는 실행 가능한 테스트의 근거가 될 수 없다.

## 기존 구조 재사용

- `ControlRepositoryKey`의 canonical 형식은 `screen|map|logicalName|stateContext`다. 시나리오에는 이 key만 있고 locator 상세정보는 없다.
- 기존 locator 우선순위와 canonical approval hash는 `ControlRepositoryResolver`와 `ControlRepositoryApprovalPayload`를 재사용한다.
- 기존 `StateGraph`, `StateTransition`, `ArrivalCheckpoint`, `RestorePolicy`가 상태/복구 계약을 소유한다.
- 기존 생성 시나리오 importer와 `TestPackCompiler`는 외부 testcase/dataset의 조합 및 승인 TestPack을 담당한다. 새 authoring validator는 이 기능을 복제하지 않는다.
- 기존 `ResultEvaluator`만 최종 verdict를 결정한다. Action 전달 결과는 독립 제품 증거가 아니며 required Checkpoint가 없는 결과는 PASS가 될 수 없다.
- PowerShell과 reporter는 Core 결과를 호출하거나 표시할 뿐 locator/risk/verdict를 다시 계산하지 않는다.

## 안전한 흐름

```text
read-only 상태 관측
  -> hover/hotkey 후보 캡처
  -> 반복 캡처를 calibration-session.json으로 구성
  -> drift/민감정보/read-only 검증
  -> 운영자가 logicalName/state/risk/action/anchor 검토
  -> ReviewRequired entry 생성
  -> 기존 TestPack approval overlay로 사람 승인
  -> 승인 entry를 새 repository 문서에 명시적으로 등록
  -> repository key 기반 시나리오 작성
  -> 정적 검증
  -> immutable DryRun run plan
  -> UI Action 0회 DryRun
  -> 실제 실행은 별도 사용자 승인 경계
```

캡처와 캘리브레이션은 cursor 이동, click, key input, 자동 승인, 자동 repository 병합을 수행하지 않는다. 현재 입력값, 계좌번호, 비밀번호, 민감 텍스트, pixel crop은 세션 스키마에 저장하지 않는다. 캡처는 redaction 여부와 redacted anchor 후보만 기록한다.

## 캘리브레이션 세션 계약

`OrderCalibrationSession` schema `1.0`은 다음을 기록한다.

- session/target/repository ID, screen/MAP/stateContext, capture 시각, reviewer, canonical 상태
- 각 관측의 process/host fingerprint, window/client 크기, DPI
- locator tier, UIA/native identity 또는 MAP/runtime binding 또는 normalized anchored-relative 후보
- expected control kind, redacted anchor 후보, 허용·금지 action 후보와 evidence reference
- observation 수와 identity/bounds/anchor/DPI/host fingerprint drift
- repository 반영 여부와 canonical approval hash
- `cursorMoved=false`, `clickSent=false`, `keyInputSent=false`, `automaticallyApproved=false`, `pixelCropStored=false`, `sensitiveDataRedacted=true`

한 번만 관측한 세션은 `ReviewRequired`다. 반복 관측의 identity, bounds, anchor, DPI 또는 host fingerprint가 다르면 `Unstable`이다. `Unstable` 세션에서는 review payload를 만들 수 없다. 안정된 반복 관측도 사람이 reviewer, logicalName, risk, allowed/forbidden action과 anchor를 확인해야 `ReviewRequired` entry가 만들어진다. 이 entry는 승인되지 않았고 approval hash도 비어 있다.

사람이 기존 approval overlay를 승인한 뒤 `register-control-repository-entry`를 호출해야만 새 repository 문서가 생성된다. 기존 입력 repository는 수정하지 않고, 중복 key와 승인/hash 오류는 차단한다.

## 주문 시나리오 계약

`OrderScenarioDocument` schema `1.0`은 `Precondition`, `Transition`, `Action`, `Checkpoint`, `Restore` 역할을 구분한다. 각 단계는 다음을 고정한다.

- Control Repository key
- current/target StateId와 stateContext
- operation과 repository action, physical action 여부
- input variable reference와 structured expected mode
- required/optional Checkpoint, timeout, failure evidence 방식
- restore policy, risk class, 실행 허용과 거래 allowlist 여부

민감 변수는 실제 값을 포함하지 않는다. `variableRef`만 기록하며 readback을 요구할 수 없다. optional Checkpoint 미실행은 비차단이지만, 실행된 optional Checkpoint 실패는 기존 evaluator 정책대로 PASS를 차단한다. required Checkpoint만 PASS의 필수 증거가 되며, 최종 verdict는 계속 `ResultEvaluator`가 결정한다.

## 정적 validator 차단 코드

validator는 최소 다음 오류를 구조화된 `code`, `stepId`, `message`, `remediation`으로 반환한다.

- `ORDER_SCENARIO.REPOSITORY_KEY_NOT_FOUND`, `REPOSITORY_ENTRY_NOT_APPROVED`, `APPROVAL_HASH_MISMATCH`
- `STATE_CONTEXT_MISMATCH`, `STATE_IDENTITY_MISMATCH`, `ACTIVE_CONTEXT_MISMATCH`
- `REQUIRED_CHECKPOINT_MISSING`, `ACTION_DELIVERY_ONLY_CHECKPOINT`, `NON_VERDICT_EXPECTATION`
- `ACTION_POLICY_CONFLICT`, `AMBIGUOUS_LOGICAL_KEY`, `RUNTIME_DRIFT`
- `COORDINATE_TRANSACTION_FORBIDDEN`, `IMAGE_ONLY_PHYSICAL_ACTION`, `TRANSACTION_STABLE_IDENTITY_REQUIRED`, `TRANSACTION_ALLOWLIST_REQUIRED`
- `SENSITIVE_READBACK_FORBIDDEN`
- `STATE_GRAPH_NOT_READY`, `PRECONDITION_MISSING`, `RESTORE_POLICY_MISSING`, `RESTORE_STEP_MISSING`, `RESTORE_TARGET_MISMATCH`, `RESTORE_ORDER`
- `CONFIGURATION_REQUIRED`, `STEP_EXECUTION_NOT_ALLOWED`

FinalSubmit, AmendSubmit, CancelSubmit, OpenConfirmation, 거래 위험으로 분류된 physical action, Enter 확정 키는 별도 사용자 승인과 scenario allowlist가 필요하다. 거래 action은 stable UIA/native identity만 허용한다. 상대좌표 거래 action과 image-only physical action은 별도 승인이 있어도 차단된다.

## Run plan과 DryRun

정적 검증이 완전히 통과해야 schema `1.0` run plan이 생성된다. plan hash는 scenario/case, 값이 없는 변수 선언, repository key, resolved locator tier, canonical approval hash, state, Action/Checkpoint 역할, expected mode, timeout, restore 순서와 risk를 고정한다.

현재 compiler가 만드는 plan은 항상 `executionMode=DryRun`, `actualExecutionAllowed=false`다. DryRun은 plan hash, repository resolution, step/state 순서, required Checkpoint, expected mode, 변수 binding, risk, restore, result/evidence schema를 읽기만 한다. 결과는 항상 `PENDING`이고 `actualUiActionCount=0`, `transactionalActionCount=0`이다. PASS 판정은 하지 않는다.

## CLI와 PowerShell

아래 명령은 모두 JSON 파일만 읽고 쓴다. `create-*`와 `compile-*` 출력 경로가 이미 있으면 덮어쓰지 않는다.

```powershell
dotnet run --project src/HtsQa.Cli -- create-calibration-session `
  --captures capture-1.json,capture-2.json `
  --session-id SESSION --target-profile-id TARGET --repository-id REPOSITORY `
  --screen SCREEN --map MAP --state-context STATE --reviewer REVIEWER `
  --out calibration-session.json

dotnet run --project src/HtsQa.Cli -- validate-calibration-session `
  --file calibration-session.json --out calibration-validation.json

dotnet run --project src/HtsQa.Cli -- create-calibration-review `
  --session calibration-session.json --logical-name CONFIRMED_NAME --anchor REDACTED_ANCHOR `
  --risk-class LimitedNonTransactional --allowed-actions Input,Assert `
  --forbidden-actions FinalSubmit,AmendSubmit,CancelSubmit `
  --source APPROVED_SOURCE --evidence EVIDENCE_1,EVIDENCE_2 --out control.review.json

dotnet run --project src/HtsQa.Cli -- create-control-repository-approval `
  --review control.review.json --out control.approval.json

# 사람이 approval overlay를 검토·승인한 뒤에만 실행한다.
dotnet run --project src/HtsQa.Cli -- apply-control-repository-approval `
  --review control.review.json --approval control.approval.json --out control.decision.json

dotnet run --project src/HtsQa.Cli -- register-control-repository-entry `
  --repository control-repository.json --entry control.decision.json --out control-repository.next.json
dotnet run --project src/HtsQa.Cli -- finalize-calibration-session `
  --session calibration-session.json --repository control-repository.next.json `
  --logical-name CONFIRMED_NAME --out calibration-session.applied.json


dotnet run --project src/HtsQa.Cli -- validate-order-scenario `
  --input order-scenario-validation-input.json --out order-scenario-validation.json

dotnet run --project src/HtsQa.Cli -- compile-order-scenario `
  --input order-scenario-validation-input.json --out order-run-plan.json

dotnet run --project src/HtsQa.Cli -- dry-run-order-scenario `
  --plan order-run-plan.json --out order-scenario-dry-run.json
```

`scripts/modules/hts-order-scenario-authoring.ps1`은 위 명령의 argument adapter다. UI, locator, risk 또는 verdict 로직을 포함하지 않는다. 기존 `capture-control-candidate.ps1`과 `hts-control-repository.ps1`의 read-only capture를 재사용한다.

## 0101 템플릿과 현장 PENDING

`targets/1q-hts/0101/scenario-templates`에는 매수, 매도, 정정·취소 후보 상태 템플릿만 있다. 각 템플릿은 필요한 control 역할, precondition, input, required/optional Checkpoint, ValidationRequired 작성 조건, restore, 미확정 항목과 현장 증거를 설명한다. logicalName과 repository key는 비어 있고 `executable=false`다.

실제 Windows 단말에서 다음 증거를 확보하기 전에는 0101 실행 시나리오를 만들 수 없다.

- 각 후보 상태의 반복 관측과 stable UIA/native 또는 MAP/runtime identity
- process/window/host fingerprint, client bounds, DPI와 redacted anchor 안정성
- 승인된 state arrival Checkpoint, transition allowlist, baseline과 deterministic restore
- 공식/승인 근거가 있는 입력 변수와 structured expected mode
- required product Checkpoint의 실제 관측 근거와 timeout
- 허용/금지 action 및 거래 위험 분류의 승인 metadata

이 단계에서 실제 0101 locator 안정성, control 인식률, transition, restore 또는 업무 결과는 검증하지 않았다. 모두 `ConfigurationRequired` 또는 `PENDING`이다.
