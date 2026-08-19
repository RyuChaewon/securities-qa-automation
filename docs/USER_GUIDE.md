# 사용자 가이드

## 기존 대상 실행

1Q HTS 계좌정보 예시는 다음 데이터셋을 사용한다.

```powershell
.\scripts\run-auto-scenario-pipeline.ps1 `
  -DatasetPath .\data\rule-tests\1q-hts-account-inquiry.dataset.json `
  -AllowElevatedActionPrompt
```

일부 화면만 실행하려면 데이터셋에 등록된 ID를 지정한다.

```powershell
.\scripts\run-auto-scenario-pipeline.ps1 `
  -DatasetPath .\data\rule-tests\1q-hts-account-inquiry.dataset.json `
  -ScreensCsv '화면ID1,화면ID2' `
  -AllowElevatedActionPrompt
```

## 새 화면군 추가

1. `data/rule-tests/target-template.dataset.json`을 새 이름으로 복제한다.
2. `targetProfile`에 대상 창과 설치 정보를 적는다.
3. `screens[]`에 실행할 화면 ID와 이름을 등록한다.
4. 필요한 입력을 `variables[]`에 추가한다.
5. 계좌 조합이 필요한 경우에만 `accounts[]`를 추가한다.
6. 데이터셋 검증 후 `-StaticOnly`로 정적 파이프라인을 확인한다.
7. 로그인된 대상에서 `-PrepareOnly`로 바인딩을 확인한다.
8. 준비 상태가 `READY`일 때 실제 녹화 실행을 수행한다.

## targetProfile

```json
{
  "targetProfile": {
    "id": "new-target",
    "displayName": "새 대상 화면군",
    "runLabel": "new-target",
    "screenIdPattern": "^[0-9]{4}$",
    "window": {
      "className": "대상 Win32 클래스",
      "titlePrefix": "대상 창 제목"
    },
    "map": {
      "installationRoot": "C:/TARGET",
      "screenDirectory": "screen",
      "filePattern": "ht{screenNumber}00.map"
    }
  }
}
```

`screenDirectory`가 상대 경로면 `installationRoot` 기준으로 계산한다. `filePattern`에는 `{screenNumber}`가 필요하다. 창 클래스와 제목 접두사 중 하나 이상을 지정한다.

## 실행 단계 선택

```powershell
# 데이터셋과 설치 MAP만 사용하며 대상 창을 열지 않는다.
.\scripts\run-auto-scenario-pipeline.ps1 -DatasetPath <dataset.json> -StaticOnly

# 화면을 열어 컨트롤을 관찰하지만 테스트 입력·선택·클릭은 수행하지 않는다.
.\scripts\run-auto-scenario-pipeline.ps1 -DatasetPath <dataset.json> -PrepareOnly

# 녹화와 실제 시나리오 조작까지 수행한다.
.\scripts\run-auto-scenario-pipeline.ps1 -DatasetPath <dataset.json> -AllowElevatedActionPrompt
```

## 직접 하위 기능 실행

```powershell
# 케이스 조합만 확인
.\scripts\run-target-rule-suite.ps1 -DatasetPath <dataset.json> -DryRun

# 런타임 탭 순서와 바인딩 후보만 확인
.\scripts\run-target-rule-suite.ps1 -DatasetPath <dataset.json> -PlanOnly

# 이미 생성된 JSON을 Excel로 변환
.\scripts\export-rule-results-xlsx.ps1 -ReportDir <results-folder>
```

실제 조작은 컴파일 계획과 물리 계획을 함께 전달하는 자동 파이프라인 사용을 권장한다.

## 입력 데이터

- 날짜: `yyyyMMdd`
- 체크박스: 문자열 `true`와 `false`
- 라디오·콤보·탭: 모든 유한 선택지를 `values[]`에 등록하거나 자동 발견값 사용
- 민감 값: `sensitive: true`
- 비밀번호 명시 입력: 평문이 아니라 환경 변수 참조

계좌가 없는 화면군은 `accounts: []`로 둔다. 계좌가 있으면 활성 계좌 × 활성 화면 × 적용 변수 값의 조합으로 케이스가 생성된다.

## 결과 확인

- `summary.json`: 실행 전체 상태와 대상 프로필
- `case-results.json`: 입력 조합별 결과
- `control-plan.json`: 발견 컨트롤과 선택지
- `full-run.mp4`: 대상 메인 창 전체 녹화
- `테스트결과-*.xlsx`: 한국어 통합 보고서

실제 조작하지 않은 단계는 `PENDING`이어야 한다.
