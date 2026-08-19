# 코드 수정 가이드

## 가장 먼저 볼 파일

- `config/pipeline.manifest.json`: 실행 파일 연결과 단계 순서
- `scripts/modules/pipeline-common.ps1`: 데이터셋을 공통 실행 컨텍스트로 변환
- `src/HtsQa.Core/Datasets/RuleBased.cs`: 데이터셋·결과 모델과 검증
- `scripts/run-target-rule-suite.ps1`: 실제 실행과 오류 관찰
- `scripts/modules/rule-control-exploration.ps1`: 컨트롤 발견·계획·조작
- `src/HtsQa.Core/Scenarios/RuleScenarioGeneration.cs`: 자동 시나리오 생성
- `src/HtsQa.Core/Scenarios/ScenarioPlanning.cs`: 승인·컴파일·바인딩
- `tools/build-rule-results-workbook.mjs`: Excel 생성

## 연결 변경

실행 파일 이름이나 위치가 바뀌면 `pipeline.manifest.json`의 `entryPoints`를 수정한다. 호출 스크립트에 새 경로 문자열을 추가하지 않는다. 공통 경로 계산은 `Resolve-RulePath`, 진입점 탐색은 `Get-RulePipelineEntryPoint`를 사용한다.

## 대상 프로필 변경

대상 창, 화면 ID 정규식, 설치 경로와 MAP 패턴은 데이터셋 `targetProfile`에 둔다. 코드에 대상별 클래스명, 제목, 화면번호 범위를 추가하지 않는다.

새 프로필 필드를 추가할 때는 다음을 함께 수정한다.

1. `RuleTargetProfile` 또는 하위 record
2. `RuleDatasetValidator`
3. `Get-RuleTargetContext`
4. `target-template.dataset.json`
5. Excel `입력데이터안내`
6. 관련 단위 테스트

## 컨트롤 종류 추가

1. `RuleControlKind`에 종류 추가
2. MAP 타입 변환 규칙 추가
3. `Get-RuleDiscoveredControls`의 발견 규칙 추가
4. `Invoke-RuleControlPlanItem`의 조작 규칙 추가
5. 시나리오 생성기의 값 생성 규칙 추가
6. Excel 라벨과 데이터 가이드 추가

물리 입력 전 `Assert-HtsClickScope`와 `Assert-HtsKeyboardScope`를 우회하지 않는다.

## 오류 판정 추가

- 설치 근거: `src/HtsQa.Core/Installation/HtsInstallation.cs`
- MAP 메시지·핸들러: `src/HtsQa.Core/Maps/HtsMap.cs`
- 기대 계약 우선순위: `src/HtsQa.Core/Outcomes/RuleOutcomePolicy.cs`
- 런타임 팝업·로그 비교: `run-target-rule-suite.ps1`
- 보고서 표시: `build-rule-results-workbook.mjs`

오류 키워드만으로 FAIL을 만들지 않는다. 현재 입력의 기대 결과와 시스템 실패 우선 정책을 함께 적용한다.

## 보고서 컬럼 추가

실행 JSON 모델, PowerShell 결과 객체, Excel 머리글, 행 배열, 열 너비와 `컬럼설명` 시트를 함께 수정한다. 계좌·비밀번호·민감 변수라면 마스킹 모듈도 갱신한다.

## 주석 기준

- 파일 시작: 역할, 입력, 부작용
- 함수 시작: 반환값과 안전 조건
- 복잡한 분기: 왜 해당 상태가 PASS/FAIL/PENDING인지
- Win32 입력 직전: 경계 검사가 무엇을 보장하는지
- 산출물 쓰기 직전: 다음 소비 단계와 계약

단순 대입을 그대로 읽어 주는 주석은 추가하지 않는다. 수정자가 계약과 실패 조건을 파악할 수 있는 주석을 우선한다.

파일과 폴더 책임, 의존 방향과 구조 검사는 [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md)를 따른다.

## 검증

```powershell
$env:DOTNET_CLI_HOME=(Join-Path (Get-Location) '.dotnet-home')
dotnet build .\HtsQaPoc.sln -c Release --no-restore
dotnet test .\HtsQaPoc.sln -c Release --no-build --no-restore
```

PowerShell 파서, Node `--check`, Python `ast.parse`도 함께 실행한다. 코드 검증 성공은 실제 HTS 테스트 PASS가 아니다.
