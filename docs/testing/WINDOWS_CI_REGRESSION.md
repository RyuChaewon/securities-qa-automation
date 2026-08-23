# Windows 회귀 검증 게이트

`.github/workflows/windows-regression.yml`은 `windows-latest`에서 이후 의미 변경과 UI 자동화 변경을 검증한다. GitHub checkout과 .NET SDK/Node 설치 및 NuGet restore에는 각 공식 배포 서비스를 사용하지만, 테스트 실행 자체는 HTS·실계좌·비밀정보·외부 API에 의존하지 않는다.

## 로컬 검증

저장소 루트의 Windows PowerShell에서 다음 명령을 실행한다.

```powershell
$env:DOTNET_CLI_HOME=(Join-Path (Get-Location) '.dotnet-home')
dotnet restore .\HtsQaPoc.sln
dotnet build .\HtsQaPoc.sln -c Release --no-restore
dotnet test .\HtsQaPoc.sln -c Release --no-build --no-restore
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev\verify-source-layout.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev\verify-refactoring-completion.ps1

Get-ChildItem .\tests\PowerShell\*.tests.ps1 | Sort-Object Name | ForEach-Object {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName
  if ($LASTEXITCODE -ne 0) { throw "FAILED: $($_.Name)" }
}

Get-ChildItem .\tools, .\tests, .\targets\1q-hts\0101\tools -Recurse -File -Filter *.mjs |
  Sort-Object FullName -Unique | ForEach-Object {
    node --check $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "FAILED: $($_.FullName)" }
  }

node .\tests\targets\1q-hts\0101\importer-contract.tests.mjs
node .\tests\reporting\rule-results-contract.tests.mjs
node .\tests\reporting\repository-hygiene.tests.mjs
```

`FlaUiAutomationEngineTests`는 테스트 프로세스가 만든 WinForms fixture에만 UIA3 동작을 수행한다. PowerShell 테스트는 Fake 의존성, 임시 JSON 또는 승인 TestPack의 `-DryRun`만 사용하며 dry-run의 FlaUI action 수가 0인지 검증한다. `verify-refactoring-completion.ps1`은 `ResultEvaluator` 선언이 하나인지와 미실행·무증거 PASS 차단 코드가 그 단일 소유자에 있는지를 정적으로 검사한다. 별도 evaluator unit smoke는 미실행, 무증거, `ObservationOnly`가 PASS가 아님을 검사한다.

## CI 제외 범위

- 실제 HTS 프로세스 탐색·실행, 로그인, 실계좌 접속
- 0101 실제 창의 입력·마우스·키보드 동작과 주문·정정·취소 제출
- 설치별 UI tree, screenshot, popup, API·DB·로그 endpoint 관측
- 원본 workbook과 ignored `tools/node_modules/@oai/artifact-tool`이 필요한 전체 importer 변환 및 workbook golden

마지막 두 항목은 실제 Windows 단말 또는 승인된 로컬 의존성이 있는 별도 검증 대상이며 이 workflow의 PASS로 간주하지 않는다. CI는 importer의 구문·승인 시트/경로 비노출 경계·이동 전후 의미 비교와 reporter의 canonical JSON 계약까지만 검증한다.
