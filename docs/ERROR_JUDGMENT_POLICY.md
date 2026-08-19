# 오류 판정 정책

## 목적

오류 문구의 존재와 제품 결함을 분리한다. 잘못된 입력을 HTS가 거부한 정상 검증은 결함이 아니며, 정상 입력의 거부·시스템 실패·필수 검증 누락을 결함으로 판정한다. 입력 의도가 정의되지 않아 자동 구분할 수 없는 반응은 `PENDING`으로 남긴다.

## 판정 입력

판정기는 다음 세 정보를 함께 사용한다.

1. 관찰 이벤트: 팝업, 화면에 새로 나타난 문구, 신규 로그 행, 화면 미생성·종료·무응답
2. 정적 근거: 설치 `errcode.txt` 분류, 화면 MAP의 메시지·오류 핸들러·RQ/TR, 공통 시스템 실패 규칙
3. 입력 계약: 값별 `expectedOutcome.type`, `messagePatterns`, `errorCodes`, `queryShouldComplete`, `source`, `confidence`, `evidence`

우선순위는 공식 오류코드, 화면 MAP, 공통 시스템 실패, 일반 문구 순이다. `OnError` 선언이나 오류 인자 이름만으로는 실제 오류 발생으로 판정하지 않는다.

## 기대 계약 자동 생성

모든 입력값의 기대 결과를 사용자가 직접 작성할 필요는 없다. 다음 순서로 기존 설치 자료를 사용하며, 앞선 근거가 뒤의 자동 추론보다 우선한다.

| 우선순위 | 출처 | 자동 계약 | 신뢰도 | 근거 |
|---:|---|---|---|---|
| 1 | `Dataset` | 사용자가 명시한 유형 유지 | `High` | 데이터셋 값별 계약 |
| 2 | `InstallationInputOption` | `Success` | `High` | `exchange.ini`, `empcommon.ini` 등 의미가 확정된 입력 사전 |
| 2 | `InstallationMaster` | `Success` | `High` | 무결성을 확인한 `stkcode.cod`, `nxtcode.cod`, `etfcode.cod` 표본 |
| 3 | `MapValidation` | 계산 가능한 위반값은 `ValidationRequired`, 그 외 관련값은 `ValidationAllowed` | 조건식 연결 시 `High`, 메시지만 연결 시 `Medium` | MAP 메시지, 대상 컨트롤, `If/ElseIf/Else` 조건식 |
| 3 | `MapBehavior` | 조회 역할은 `Success`, 일반 명령은 `ObservationOnly` | `High` | MAP 이벤트와 실제 요청 호출 그래프 |
| 4 | `RuntimeChoice` | 활성 유한 선택지는 `Success` | `Medium` | 런타임 콤보·라디오·체크·탭 선택지 |
| 4 | `GeneratedBoundary` | 명백한 형식 위반은 `ValidationRequired`, 불확실한 경계는 `ValidationAllowed` | `High` 또는 `Medium` | 마스터 형식과 자동 경계 생성 규칙 |
| 5 | `ScreenExpectedPattern` | `ValidationAllowed` | `Medium` | 화면별 기대 팝업 패턴 |
| 6 | `Unspecified` | 자동 결함 단정 금지 | `Unspecified` | 충분한 근거 없음 |

`evidence`에는 원본 파일, MAP 규칙 ID·메시지·조건식 또는 런타임 발견 경로를 기록한다. 높은 신뢰도의 정적 정상값이라도 계좌 권한·영업일·데이터 유효기간 같은 외부 선행조건까지 보증하지 않는다. 설치 자료가 알려 주지 않는 금액·수량·손익의 업무 정답은 별도 데이터 오라클이 필요하다.

데이터셋 계약은 자동 추론을 재정의할 수 있다. 다만 `ValidationAllowed`나 `ObservationOnly`도 시스템·통신·인증·프로그램 실패를 숨길 수 없다. MAP 조건을 현재 실행기가 계산하지 못하면 검증 필수로 단정하지 않고 `ValidationAllowed/Medium` 또는 `Unspecified`로 낮춘다.

## 관찰 이벤트 분류

| 이벤트 | 의미 | 대표 근거 |
|---|---|---|
| `ProductFailure` | 시스템·통신·인증·세션·프로그램 실패 | 공식 실패 코드, MAP `Error`, 무응답·비정상 종료 |
| `InputValidation` | 입력 형식·범위·업무 조건 거부 | MAP `InputValidation`, 기대 패턴과 일치한 일반 오류 문구 |
| `NoData` | 정상 요청이나 결과 자료 없음 | 공식 `NoData` 코드·문구 |
| `Warning` | 계속 진행 전 확인 또는 주의 | MAP 경고, 경고 팝업 |
| `GenericError` | 오류성 문구이나 정적 분류가 불충분 | 공통 오류 정규식 |
| `Success` | 정상 완료 신호 | 정상 코드·조회 완료 |

## 기대 결과 유형

| `expectedOutcome.type` | 용도 |
|---|---|
| `Success` | 정상값이며 검증·경고·자료 없음이 발생하면 안 됨 |
| `ValidationAllowed` | 경계값 탐색 중 지정 검증이 나타나도 정상으로 허용 |
| `ValidationRequired` | 의도적인 잘못된 값이므로 지정 검증이 반드시 나타나야 함 |
| `FailureRequired` | 오류 주입 시나리오에서 지정 실패가 반드시 나타나야 함 |
| `NoDataAllowed` | 해당 조건에서 자료 없음이 정상일 수 있음 |
| `WarningAllowed` | 해당 조건에서 지정 경고가 정상일 수 있음 |
| `ObservationOnly` | 반응을 기록하되 비시스템 이벤트는 자동 결함 판정하지 않음 |
| `Unspecified` | 입력 의도가 없어 비시스템 이벤트 발생 시 검토 필요 |

`messagePatterns`와 `errorCodes`가 있으면 실제 관찰 내용이 그중 하나와 일치해야 기대 반응으로 인정한다. 시스템 실패는 `ValidationAllowed`, `NoDataAllowed`, `WarningAllowed`, `ObservationOnly`로 숨길 수 없다.

## 최종 판정표

| 관찰 결과 | 입력 계약 | 판정 | 결과 코드 |
|---|---|---|---|
| 시스템·통신·인증·프로그램 실패 | 일반 계약 | `FAIL` | `PRODUCT_FAILURE_DETECTED` |
| 지정한 실패와 정확히 일치 | `FailureRequired` | `PASS` | `EXPECTED_FAILURE_OBSERVED` |
| 지정한 입력 검증과 일치 | `ValidationAllowed` 또는 `ValidationRequired` | `PASS` | `EXPECTED_VALIDATION_OBSERVED` |
| 지정 검증이 나타나지 않음 | `ValidationRequired` | `FAIL` | `EXPECTED_OUTCOME_NOT_OBSERVED` |
| 정상값이 입력 검증·경고·자료 없음으로 거부됨 | `Success` | `FAIL` | `UNEXPECTED_APPLICATION_EVENT` |
| 지정 유형이나 문구와 다른 반응 | 명시 계약 | `FAIL` | `UNEXPECTED_APPLICATION_EVENT` |
| 입력 검증·경고·자료 없음·일반 오류 | `Unspecified` | `PENDING` | `OUTCOME_EXPECTATION_REQUIRED` |
| 컨트롤 조작·조회·선택 검증 미완료 | 모든 계약 | `PENDING` | 기존 자동화 미완료 코드 |
| 물리계획 고정 후보 재식별 실패·모호·identity 변경 | 승인된 물리 시나리오 | `ERROR` | `CONTROL_STALE` / `CONTROL_AMBIGUOUS` / `PHYSICAL_BINDING_DRIFT` |
| 체크 상태를 읽어 검증할 수 없음 | 승인된 물리 시나리오 | `ERROR` | `CHECK_STATE_UNVERIFIABLE` |
| 접속 해제·재접속 선택이 필요한 연결 장애 | 모든 계약 | `ERROR` | `HTS_CONNECTION_LOST` |
| `queryShouldComplete: true`이나 조회 미실행 | 모든 계약 | `PENDING` | `QUERY_EXPECTATION_NOT_EXECUTED` |
| 실행기 내부 예외 | 모든 계약 | `ERROR` | `EXECUTOR_EXCEPTION` |
| 오류 신호 없음과 필수 조작 완료 | `Success` 또는 허용 계약 | `PASS` | 오류 코드 없음 |

`PASS`는 실행한 조작과 정의된 반응 계약의 충족만 뜻한다. 조회 결과 금액·수량 등 업무 값의 정합성은 별도 오라클 없이는 보증하지 않는다.

## 과거 종목코드 판정 정정

과거 실행에서 자동 탐색값 `99999999`를 종목코드 입력란에 넣은 뒤 `종목코드오류`가 표시되었다. 이는 잘못된 종목코드를 거부한 입력 검증이므로, 값의 계약이 `ValidationAllowed` 또는 `ValidationRequired`이고 문구 패턴이 일치하면 현재 정책에서는 `EXPECTED_VALIDATION_OBSERVED`, `PASS`, 제품 결함 0건으로 판정한다.

과거 보고서의 `EXPLICIT_ERROR_DETECTED`, `FAIL`은 오류라는 단어를 제품 결함으로 직접 연결한 구형 정책의 결과다. 원본 증적은 감사 이력으로 보존하지만 현재 결함 통계에는 합산하지 않는다. 새 정책의 실제 HTS 재실행 전까지 재판정 실행 결과는 `PENDING`이다.

## 데이터 작성 예시

```json
{
  "id": "invalid-stock",
  "value": "99999999",
  "expectedOutcome": {
    "type": "ValidationRequired",
    "messagePatterns": [
      "종목코드오류|등록되지 않은 종목코드"
    ],
    "queryShouldComplete": false
  }
}
```

`targetProfile.map.installationRoot` 아래 `mst`의 검증된 종목 마스터 표본은 `Success/InstallationMaster/High`로 자동 등록되므로 같은 값을 다시 적을 필요가 없다. 마스터에 없거나 화면마다 의미가 다른 값, 설치 파일만으로 정답을 알 수 없는 업무 결과는 `variables[].appliesToScreens`와 명시 계약으로 보강한다.
