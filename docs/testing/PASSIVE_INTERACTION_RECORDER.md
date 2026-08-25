# Passive Interaction Recorder

Passive Interaction Recorder는 이미 열린 대상 화면에서 사용자가 직접 수행한 mouse interaction을 관찰한다. Recorder는 pointer를 이동하거나 click/key를 보내지 않으며 keyboard 문자열을 저장하지 않는다. F10은 전역 종료 신호로만 확인하고, console Enter는 fallback 종료 방식이다.

## 책임 분리

- `PassiveInputObserver`: low-level left/right down/up과 대상 process WinEvent를 작은 thread-safe queue에 넣는다. callback 안에서 UIA traversal이나 파일 저장을 하지 않는다.
- `PassiveInteractionObservation`: `WindowFromPoint`, `ChildWindowFromPointEx`, `RealChildWindowFromPoint`, descendant/owned popup inventory, focus/foreground, client/DPI 좌표와 raw pixel을 남기지 않는 visual block hash를 읽는다.
- `PassiveInteractionAnalysis`: pre frame과 약 0/100/300/750ms post frame, WinEvent를 하나의 `ObservedManualInteraction`으로 묶고 변화·hit-zone·역할을 제안한다.
- `hts-passive-interaction-recorder.ps1`: observer와 bridge를 조정하고 local Discovery JSON만 쓴다.
- 대상별 얇은 entrypoint: 정확한 메인 창과 화면 HWND 선택, profile 연결만 담당한다.

## 안전 불변식

모든 결과는 다음 값으로 고정된다.

```text
artifactRole=Discovery
interactionRole=ObservedManualInteraction
automated=false
testExecution=false
verdictEligible=false
resultEvaluatorInvoked=false
canonicalVerdict=null
scenarioId=null
caseId=null
uiActionCount=0
transactionalActionCount=0
```

Native window text는 읽거나 저장하지 않는다. class와 `GetWindowTextLength` 길이만으로 만든 redacted metadata hash를 사용한다. visual evidence는 축소 block hash와 changed rectangle만 저장하며 screenshot pixel은 기본 산출물에 없다. name/value/password/keyboard text 속성은 저장 직전 검사에서 차단된다.

Owner-drawn `AfxWnd` 하나만 식별되면 실패로 처리하지 않는다. parent native signature, normalized parent point, 영역과 전후 state delta가 비슷한 interaction만 같은 `InteractionZoneCandidate`로 묶는다. 다른 지점은 별도 zone이고 모든 zone은 `ReviewRequired`, `Unapproved`, `executable=false`다.

## 0101 실행

먼저 Release build와 Windows offline regression을 완료한다. 이후 현재 열린 0101 화면에서 다음 명령을 별도 console로 실행한다.

```powershell
.\targets\1q-hts\0101\scripts\record-order-screen-interactions.ps1
```

3초 countdown 뒤 사용자가 선택 가능한 항목을 평소처럼 직접 누른다. 같은 control을 반복해도 된다. 거래 제출 control은 누를 필요가 없고 Recorder가 요구하지도 않는다. 완료하면 F10을 누르거나 console로 돌아와 Enter를 누른다.

로컬 출력은 기본적으로 `artifacts/local/passive-interactions/0101-<timestamp>`에 생성된다. snapshot, raw HWND, host 정보와 visual evidence는 commit/push 대상이 아니다. Git에는 generic 구현, schema, tests와 문서만 포함한다.

## 산출물 해석

- `interaction-session.json`: 시간·수량·영역별 집계와 0 action 불변식
- `observed-interactions.json`: manual click, hit target, pre/post fingerprint와 변화
- `interaction-zones.json`: 반복 interaction의 ReviewRequired zone cluster
- `logical-role-suggestions.json`: confidence/evidence가 있는 역할 제안
- `state-transition-suggestions.json`: 사람이 검토할 ConfigurationRequired 상태 후보
- `control-repository-candidates.json`: 자동 승인되지 않은 비실행 후보
- `scenario-authoring-hints.json`: executable scenario가 없는 작성 힌트

이 파일은 TestResult가 아니며 PASS/FAIL로 표시할 수 없다. 별도의 사람 검토, 승인 Control Repository, Scenario 작성과 승인 실행을 거쳐야만 이후 TestResult 근거가 될 수 있다.
