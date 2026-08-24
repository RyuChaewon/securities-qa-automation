# 승인 기반 Control Repository

Control Repository는 시나리오의 `screen | map | logicalName | stateContext` 논리 key와 실제 locator 증거를 분리한다. 시나리오에는 `controlRepositoryKey`만 저장하며 AutomationId, native identity, MAP/runtime binding, 상대좌표, 이미지 서명을 복제하지 않는다.

locator 우선순위는 고정되어 있다.

1. `StableIdentity`: AutomationId 또는 안정적인 native identity
2. `MapRuntimeBinding`: MAP + runtime binding
3. `ApprovedAnchoredRelative`: 사람이 승인한 client-relative 좌표
4. `VisualObservationOnly`: image/OCR/visual signature 기반 관찰 보조

높은 신뢰 locator가 구성되어 있는데 실행 직전 일치하지 않으면 낮은 tier로 자동 fallback하지 않는다. 자동 탐색의 변화는 `ReviewSuggestion`일 뿐 repository를 수정하거나 승인하지 않는다. FlaUI `controlRepositoryPreflight`는 승인 normalized 좌표를 현재 client rect/DPI로 다시 계산하고 같은 지점의 redacted UIA/host anchor, control kind, visual signature를 cursor 이동·click 없이 재관측한다. `ApprovedAnchoredRelative`는 이 증거를 포함해 active screen/MAP/state, process와 host fingerprint, client bounds, DPI, anchor, control kind, visual signature, approval payload hash, action risk, bounds 내부 여부, 금지 control 충돌을 Core resolver가 모두 확인해야 `Resolved`가 된다. `FinalSubmit`, `AmendSubmit`, `CancelSubmit`에는 상대좌표를 사용할 수 없고 visual-only locator는 physical action을 수행할 수 없다.

승인에는 TestPack과 같은 `TestPackApprovalInfo` 계약을 재사용한다. `approvalPayloadHash`와 `approval.approvedContentHash`는 locator·risk·action·근거의 canonical payload SHA-256과 모두 같아야 한다. `Draft`, `ReviewRequired`, `ConfigurationRequired`, `Unresolved`, 승인 해시 불일치는 실행 불가다.

## Hover + F8 캡처

`scripts/capture-control-candidate.ps1`은 사용자가 대상 위에 cursor를 둔 뒤 F8을 눌렀을 때 현재 cursor 점을 읽는다. 도구는 cursor를 이동하거나 click/input하지 않는다. FlaUI bridge는 process/window, adapter가 제공한 state/MAP, 현재 client rect, normalized client-relative point, DPI, redacted UIA identity hash, control-kind 후보, redacted visual signature를 수집한다. control name, 현재 값, 비밀번호 값, pixel crop은 결과에서 제외한다.

```powershell
scripts/capture-control-candidate.ps1 `
  -RootHwnd <검토 대상 HWND> `
  -StateContext <확인된 stateContext> `
  -MapScreenCode <확인된 MAP> `
  -CoordinateSpace ScreenClient `
  -OutPath <capture.json>
```

출력은 항상 `ReviewRequired` 후보이며 승인 repository entry가 아니다. 이후 사람이 `logicalName`, `stateContext`, risk class, allowed action, anchor와 source/evidence를 확인해 검토 payload를 만든다.

```powershell
dotnet run --project src/HtsQa.Cli -- create-control-repository-review `
  --capture <capture.json> --screen <screen> --map <map> `
  --logical-name <logicalName> --state-context <stateContext> `
  --risk-class LimitedNonTransactional --allowed-actions Assert `
  --anchor <approved-anchor> --evidence <evidence-ref> --out <review.json>

dotnet run --project src/HtsQa.Cli -- validate-control-repository `
  --file <control-repository.json>
```

검토 payload도 `ReviewRequired`다. `--anchor`는 캡처가 평문 없이 만든 redacted UIA/host 후보 중 하나를 사람이 선택해야 하며 임의 문자열은 거부된다. 실행 직전에도 다시 관측된 anchor 후보 안에 승인 anchor가 없으면 차단된다. 기존 TestPack approval overlay 형식을 재사용해 `PendingApproval` template을 만든 뒤, 사람이 `status`, `approvedBy`, `approvedAt`, `evidenceRefs`를 직접 검토·입력한다. 적용 명령은 canonical payload hash와 승인 metadata를 검증할 뿐 승인 결정을 대신하지 않는다.

```powershell
dotnet run --project src/HtsQa.Cli -- create-control-repository-approval `
  --review <review.json> --out <approval.json>

# 사람이 approval.json을 검토하고 status/approvedBy/approvedAt/evidenceRefs를 입력한다.
dotnet run --project src/HtsQa.Cli -- apply-control-repository-approval `
  --review <review.json> --approval <approval.json> --out <decision.json>
```

`ReviewRequired`가 아니거나 이미 승인 정보가 포함된 payload, hash가 바뀐 payload, 승인자·시각·승인 근거가 빠진 `Approved` overlay는 차단된다. CLI는 실제 UI action을 실행하지 않고 repository 파일에 자동 병합하지도 않는다.

실행 직전 resolution은 `resolve-control-repository`의 canonical 결과를 사용하고 PowerShell과 reporter는 상태를 재판정하지 않는다.

현재 `targets/1q-hts/0101/control-repository.json`은 `ConfigurationRequired`이고 entry가 0개다. 따라서 기존 State Graph의 후보 3개, transition, baseline, restore 상태는 그대로 미확정이다. 이 문서와 fake/sample 테스트는 실제 0101 locator 안정성이나 control 인식률의 증거가 아니다.

설계 개념은 상용 의존성 없이 [TestComplete Name Mapping](https://support.smartbear.com/testcomplete/docs/testing-with/object-identification/name-mapping/index.html)의 논리 이름 분리와 [UFT Smart Identification maintenance](https://admhelp.microfocus.com/uft/en/26.1/UFT_Help/Content/User_Guide/CS_Update_Object_Based_on_Smart_Identification_Screen.htm)의 명시적 검토 흐름만 참고했다. 패키지나 실행 의존성은 추가하지 않았다.
