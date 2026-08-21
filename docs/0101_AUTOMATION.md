# 0101 TC 자동화 적용

## 생성

`0101_TC`만 구조화된 입력으로 사용하고 참고 시트의 문장은 실행 지시로 해석하지 않는다.

```powershell
pwsh -ExecutionPolicy Bypass -File targets/1q-hts/0101/scripts/import-testcases.ps1 `
  -WorkbookPath "<0101 테스트케이스.xlsx>" `
  -AccountId "0101-test-account"
```

기본 출력은 `outputs/0101_automation`이다.

- `0101.dataset.json`: 19개 MAP family와 주문 실행 정책
- `generated-scenarios.json`: 1행 1시나리오, `TC_ID` 보존
- `map-screen-models.json`: `HT010100`부터 `HT010199`까지 19개 MAP 카탈로그
- `scenario-approval.json`: 수동 검토와 주문 실행 승인 템플릿
- `scenario-validation.json`: Importer 정적 검증 결과

Importer 재실행 시 원본과 MAP 내용이 같으면 승인 파일을 보존한다. 원본이 바뀌면 기존 승인 파일을 `scenario-approval.stale.<시각>.json`으로 이동하고 새 템플릿을 만든다.

## 승인과 컴파일

주문/전송 단계는 `scenario-approval.json`에서 해당 시나리오를 명시적으로 `Approve`하고 전체 승인 문서의 `status`, `approvedBy`, `approvedAt`을 확정해야 한다. 실행하지 않을 수동 시나리오는 `Reject`, 필수 검토는 `Resolved` 또는 `Rejected`로 결정한다.

```powershell
dotnet run --project src/HtsQa.Cli/HtsQa.Cli.csproj -c Release --no-build -- compile-scenarios `
  --file outputs/0101_automation/generated-scenarios.json `
  --dataset outputs/0101_automation/0101.dataset.json `
  --approval outputs/0101_automation/scenario-approval.json `
  --out outputs/0101_automation/compiled-plan.json
```

## 실제 화면 바인딩

```powershell
pwsh -ExecutionPolicy Bypass -File scripts/plan-scenario-bindings.ps1 `
  -CompiledPlanPath outputs/0101_automation/compiled-plan.json `
  -TestPackPath outputs/0101_automation/approved-test-pack.json `
  -ReportDir outputs/0101_automation/binding-plan
```

이 단계는 화면을 열고 컨트롤을 발견하지만 시나리오의 입력, 선택, 클릭은 실행하지 않는다. 바인딩 키는 `내부화면코드|컨트롤ID|상태컨텍스트`다.

바인딩/물리계획 스키마 `1.1`에서는 다음 조건을 모두 만족하는 유일한 후보만 실행 가능하다.

1. `definitionSource=MAP+Runtime`, `mapMatched=true`
2. `MAP|` locator signature와 양수 크기의 런타임 사각형 존재
3. 현재 컨테이너에서 활성화된 내부 MAP이며, 설정된 MAP 전용 호스트가 실제 화면에서 확인됨
4. 전용 호스트 안에서 MAP 좌표와 HWND의 중심·너비·높이가 허용 오차 안에서 일치
5. MAP 종류와 실제 런타임 종류가 조작 수준에서 호환. 단, owner-drawn `AfxWnd`는 전용 호스트와 좌표·크기가 모두 정확히 일치할 때만 MAP 종류를 사용
6. 서로 다른 활성 MAP 논리 컨트롤이 같은 런타임 HWND를 공유하지 않음
7. 같은 논리 키에 실행 가능한 후보가 정확히 1개

`HT010100` 기본 구성에서 처음 활성화되는 MAP은 상단 `HT010115`와 하단 첫 탭 `HT010103`이다. `HT010101`, `HT010102` 및 나머지 탭 MAP도 19개 family 카탈로그와 테스트 계획에는 계속 포함되지만, 해당 컨테이너 또는 탭으로 명시적으로 전환하기 전에는 물리 실행 후보가 아니다.

물리계획은 이 후보의 `controlId`, `locatorSignature`, 내부화면코드, 상태 컨텍스트를 시나리오별 `resolvedBindings`로 고정한다. `1.0` 계획은 실행기에서 거부되므로 바인딩을 다시 생성해야 한다.

## 실행

```powershell
pwsh -ExecutionPolicy Bypass -File scripts/run-target-rule-suite-recorded.ps1 `
  -TestPackPath outputs/0101_automation/approved-test-pack.json `
  -ScenarioPlanPath outputs/0101_automation/compiled-plan.json `
  -PhysicalPlanPath outputs/0101_automation/binding-plan/physical-plan.json `
  -AllowPartialScenarioPlan `
  -CaseIdsCsv "<CaseId1>,<CaseId2>" `
  -AllowElevatedActionPrompt
```

`CaseIdsCsv`를 생략하면 물리 실행계획의 실행 가능 케이스를 순서대로 처리한다. HTS가 관리자 권한으로 실행 중이면 `AllowElevatedActionPrompt`가 숨김 실행기의 UAC 승인을 요청한다. 이 과정은 새 HTS를 실행하지 않는다.

사용자가 미리 열어둔 0101을 그대로 검증할 때는 0101 전용 래퍼를 사용한다.

```powershell
pwsh -ExecutionPolicy Bypass -File targets/1q-hts/0101/scripts/run-live-validation-v2.ps1 `
  -TestPackPath outputs/0101_automation/approved-test-pack.json `
  -SourceTestCaseIdsCsv "0101-CMD-0901,0101-CTL-0101" `
  -MaxCases 2
```

이 래퍼는 실행 중인 HTS 메인 창만 사용한다. 0101이 이미 있으면 해당 HWND를 재사용하고, 없으면 메인 화면번호 입력란으로 0101을 직접 연다. 새 HTS 프로세스는 시작하지 않으며 테스트 종료 후 0101을 닫지 않는다. 좌표 클릭은 입력 스레드만 Per-Monitor DPI 문맥으로 전환해 물리 좌표로 이동한 뒤, 실제 커서 아래 HWND가 고정 대상과 일치할 때만 수행한다. 포인터를 잠시 머물게 하고 녹화에는 위치 표식을 합성한다.

실행 때마다 같은 관리자 프로세스 안에서 `plan-only 재탐색 -> binding-catalog/physical-plan 재생성 -> 요청 케이스 실행`을 연속 수행한다. 따라서 과거 화면 좌표를 재사용하지 않는다. HTS가 관리자 권한이면 Windows UIPI 때문에 UAC 승인이 한 번 필요하며, 취소 시 상태는 `PENDING_ADMIN_APPROVAL_DECLINED`이고 실제 조작 수는 0건이다.

주문 클릭은 다음 조건을 모두 만족할 때 실제 실행된다.

1. 데이터셋의 `allowTransactionalActions=true`
2. 컴파일 계획의 승인 상태가 `Approved`
3. 화면과 계좌 ID가 실행 허용 목록에 포함
4. 데이터셋 계좌번호가 있으면 MAP Account 현재값과 일치
5. 데이터셋 계좌번호가 없으면 `allowObservedPrefilledTransactionalAccount=true`이고, 승인된 사전입력 계좌가 관찰됨
6. 주문 버튼 클릭 직전 계좌 지문이 최초 관찰값과 동일

기본 실행은 주문 버튼을 눌러 새 확인 팝업을 검증하되 최종 전송은 하지 않는다. 승인된 테스트 계좌에서 확인 팝업의 주문 제출까지 수행하려면 `-SubmitTransactionalDialogs`를 명시한다. 이 옵션은 승인된 시나리오 계획을 사용하는 실제 실행에서만 허용되며 입력 오류·시스템 오류·의미가 불명확한 팝업은 제출하지 않는다.

```powershell
pwsh -ExecutionPolicy Bypass -File targets/1q-hts/0101/scripts/run-live-validation-v2.ps1 `
  -SourceTestCaseIdsCsv "<승인된 거래 TC_ID>" `
  -SubmitTransactionalDialogs
```

연결 해제·재접속·프로그램 종료 선택을 포함한 팝업은 자동으로 닫거나 선택하지 않는다. 실행기는 이를 증거로 남기고 후속 조작을 중단한다.

`AssertPopup`은 조작 직전에 없었고 조작 직후 새로 표시된 HTS 팝업 HWND가 Assert 시점에도 활성 상태인 경우에만 통과한다. Assert 단계의 재탐지는 같은 팝업을 중복 관찰로 추가하지 않으며, 팝업 증거 PNG는 HTS 메인 창의 물리 화면 영역을 캡처해 별도 소유 창까지 실제 표시 상태로 포함한다.

각 조작과 Assert 직전에는 현재 화면에서 컨트롤을 다시 발견한다. 고정한 후보가 0개면 `CONTROL_STALE`, 둘 이상이면 `CONTROL_AMBIGUOUS`, identity가 달라지면 `PHYSICAL_BINDING_DRIFT`로 조작하지 않고 케이스를 `ERROR` 처리한다. 체크 상태를 읽을 수 없는 owner-drawn 컨트롤도 성공으로 간주하지 않고 `CHECK_STATE_UNVERIFIABLE`로 차단한다.

녹화 래퍼의 완료 상태는 파이프라인 완료와 테스트 판정을 분리한다.

- `DONE`: 결과·영상·Excel 생성 완료, 테스트 PASS
- `DONE_WITH_TEST_FAILURES`: 산출물 생성 완료, 제품 동작 FAIL
- `DONE_WITH_TEST_ERRORS`: 산출물 생성 완료, 자동화 계약 또는 외부 중단 ERROR
- `DONE_WITH_PENDING`: 산출물 생성 완료, 판정 보류
- `CURSOR_AUDIT_ERROR`: 실행기 감사 좌표와 DPI-aware 녹화기의 실제 커서 좌표가 불일치해 테스트 판정을 무효화

`cursor-trace.ndjson`은 녹화 프레임별 물리 커서 좌표를 보존하고, `cursor-audit-verification.json`은 각 허용 클릭과 가장 가까운 프레임의 시간·거리 오차를 검증한다. 클릭이 하나라도 불일치하면 결과 JSON이나 TC 판정이 PASS여도 파이프라인 완료로 인정하지 않는다.
- `-FailOnTestFailure`: PASS가 아니면 종료 코드 2 반환

실행 폴더에는 일반 통합 보고서와 별도로 `TC-results-*.xlsx`가 생성된다. 이 보고서는 `요약`, `TC실행결과`, `TC단계결과`, `미실행TC`, `결과분석`, `시각화` 시트로 구성되며 `TC_ID`별 결과와 Assert 단계, 미실행 사유, MAP별 실행률, 오류코드 및 차트를 분리한다.

## 검증 결과

현재 대표 계획은 1,239개 케이스와 6,730개 단계를 포함한다. 매도 탭과 정정/취소 탭 대표 케이스는 실제 0101 화면에서 좌표 클릭, 상태별 주문 버튼 재바인딩, 커서 감사를 통과했다.

물리 바인딩 스키마 `1.1` 강화 당시 저장 증거 1,159개 시나리오의 재처리 결과는 다음과 같다.

- 실행 가능: 기존 412건 -> 209건
- 고신뢰 바인딩: 기존 80건 -> 실행 조건을 모두 통과한 26건
- `BTN_Qty4`: 44.84px로 차단
- `CHK_Remain`: 43.53px 및 `CheckBox`/`RadioGroup` 종류 불일치로 차단
- `BTN_EnvSet`: 10.03px, `Button` 일치로 실행 가능

최종 주문 제출은 아직 수행하지 않았으며 `PENDING`이다. 공개 저장소에는 계좌 정보가 포함될 수 있는 원시 동영상·스크린샷·로그를 싣지 않고 재현 가능한 계획 JSON과 검증 상태 문서만 보존한다.
