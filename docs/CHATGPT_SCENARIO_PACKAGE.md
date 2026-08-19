# ChatGPT 테스트 시나리오 생성 패키지

## 목적

외부 ChatGPT에 원본 설치 파일이나 전체 실행 로그를 전달하지 않고도 데이터셋에 등록된 임의 화면군의 테스트 시나리오와 입력 데이터 후보를 생성할 수 있도록 정보를 압축한다.

## 포함 정보

- 대상 화면번호·화면명·MAP 파일 해시·무결성 상태
- 조작 가능 MAP 컨트롤의 논리 ID, 종류, 의미 역할, 이벤트, 조회 요청, 상태 영향 관계
- 조회·자동조회·페이지·내보내기·연계 화면·결과 컨트롤 관계
- MAP 입력 검증 메시지, 조건식, 대상 컨트롤, 규칙 ID
- 설치 INI의 공식 입력 선택지
- 무결성이 확인된 종목 마스터 표본
- HTS 공식 오류코드와 입력 계약 판정 정책
- 민감정보와 좌표를 제거한 과거 런타임 탭·라벨 관찰
- 생성 결과 JSON Schema, 최소 예시, 로컬 의미 검증기

## 제외 정보

- 계좌번호, 예금주, 비밀번호, 비밀번호 환경변수 이름
- 로그 원문, 스크린샷, 동영상
- HWND, 화면 좌표, locatorSignature, initialValue, caseId
- 잔고·손익·정산 금액의 추정 정답

## 생성

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\export-chatgpt-scenario-package.ps1
```

실행할 때마다 `targetProfile.map`에서 MAP·설치 카탈로그를 새로 추출하고 `exports\chatgpt-scenario-package-{시각}` 폴더와 ZIP을 생성한다. 출력 경로를 고정하려면 `-OutputDir`을 지정한다. 기존에 내용이 있는 폴더는 덮어쓰지 않는다.

## ChatGPT 전달

ZIP은 보관·전달용이다. ChatGPT가 ZIP 내부 파일을 직접 읽지 못하는 환경에서는 패키지 폴더의 `01_ChatGPT_요청문.md`부터 `07_오류_판정_정책.md`까지 7개 파일을 첨부하고 요청문 파일의 내용을 그대로 사용한다.

`08_생성결과_검증.mjs`는 ChatGPT에 전달할 필요가 없는 로컬 검증기다.

## 생성 결과 검사

ChatGPT가 반환한 파일을 패키지 폴더에 `generated-scenarios.json`으로 저장한 뒤 실행한다.

```powershell
node .\08_생성결과_검증.mjs .\generated-scenarios.json
```

검증기는 다음을 확인한다.

- 현재 데이터셋에 등록된 활성 화면이 정확히 한 번씩 존재하는지
- 설치 지문이 같은지
- 시나리오 ID·단계 순서·런타임 탭오더 정책이 유효한지
- 참조한 컨트롤과 MAP 검증 규칙이 실제 컨텍스트에 존재하는지
- 모든 미커버 항목에 `coverageGaps`가 있는지
- 데이터 변수 종류·값 매칭·적용 화면·기대 결과가 지원 범위인지
- `ValidationRequired`와 `FailureRequired`에 문구 패턴 또는 오류코드가 있는지
- 계좌·예금주·비밀번호 관련 키가 생성 결과에 포함되지 않았는지

검증을 통과해도 `locatorRequests`, `reviewItems`, 업무 결과 정합성 항목은 사람 검토 후 기존 데이터셋에 병합한다.
