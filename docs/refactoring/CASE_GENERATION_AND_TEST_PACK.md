# 케이스 생성·CaseId·TestPack 계약

이 문서는 Dataset 직접 실행에서 Approved TestPack 실행으로 바뀐 공개 계약과 마이그레이션 절차를 설명한다. 실제 HTS 실행 여부나 테스트 PASS/FAIL 판정 계약은 변경하지 않는다.

## 단일 흐름

```text
Dataset
  -> RuleDatasetValidator
  -> CombinationGenerator
  -> ExpectationResolver
  -> TestPackCompiler
  -> 승인 오버레이(contentHash 결합)
  -> Approved RuleTestPack
  -> TestPackRunnerContract / PowerShell Runner
```

- `CombinationGenerator`가 `Cartesian`, `Pairwise`, `PerControl`을 구현하는 유일한 조합 생성기다. PoC 기본값은 `Cartesian`이다.
- `RuleCaseExpander`는 기존 C# 소비자를 위한 얇은 호환 어댑터이며 자체 조합 분기가 없다.
- 시나리오 컴파일러의 Cartesian 확장도 `CombinationGenerator.GenerateCartesian`을 호출한다.
- PowerShell의 `Get-VariableCombinations`, Dataset 기반 `Get-RuleCases`, CaseId SHA 분기는 제거했다. Runner는 TestPack의 `cases[]`를 그대로 실행기 객체로 변환할 뿐이다.
- `CaseIdFactory`는 key를 ordinal 정렬한 canonical JSON의 SHA-256으로 모든 실행 CaseId를 만든다. JSON property 또는 PowerShell 사전 입력 순서는 CaseId에 영향을 주지 않는다.

## CombinationPolicy와 상한

| 값 | 의미 |
|---|---|
| `Cartesian` | 적용 차원의 모든 값 조합. Dataset 필드가 없을 때의 기본값 |
| `Pairwise` | 모든 두 차원 값 pair를 덮는 결정론적 IPO 조합 |
| `PerControl` | 첫 값을 기준 상태로 두고 한 제어의 값만 한 번씩 바꾸는 조합 |

`maxCases`는 CLI 값과 Dataset의 `maxExpandedCases` 중 작은 값이다. 예상 케이스 수가 이 값을 넘으면 `CombinationLimitExceededException`으로 컴파일이 실패한다. 일부 케이스만 조용히 저장하거나 승인된 것처럼 만들지 않는다.

## TestPack 저장 계약

`RuleTestPack`은 `schemaVersion`, `generatorVersion`, `testPackId`, `contentHash`, 원본 `datasetSha256`/`sourceHash`, canonical `datasetContentHash`, `combinationPolicy`, `maxCases`, `cases[]`, 각 케이스의 `expectedResult`, `approval`, `generatedAt`, 전체 `datasetSnapshot`을 포함한다. `contentHash`는 생성 시각과 승인 메타데이터를 제외한 실행 내용을 고정한다. 승인은 이 `contentHash`에 결합된다.

`datasetPath`는 기존 리포트 소비자를 위한 출처 표시 호환 필드로 유지한다. 새 소비자는 `testPackId`, `testPackPath`, `testPackContentHash`를 사용해야 한다. Runner는 `datasetPath`를 읽거나 확장하지 않는다.

## 컴파일·승인·검증·dry-run

```powershell
# 1. PendingApproval TestPack 컴파일
dotnet run --project .\src\HtsQa.Cli -c Release --no-build -- `
  compile-test-pack --dataset <dataset.json> --combination-policy Cartesian --max-cases 1000 --out <pending-test-pack.json>

# 2. contentHash에 결합된 승인 초안 생성
dotnet run --project .\src\HtsQa.Cli -c Release --no-build -- `
  create-test-pack-approval --test-pack <pending-test-pack.json> --out <approval.json>

# approval.json을 검토해 status=Approved, approvedBy, approvedAt, evidenceRefs를 기록한다.

# 3. 같은 Dataset을 승인 오버레이와 함께 다시 컴파일
dotnet run --project .\src\HtsQa.Cli -c Release --no-build -- `
  compile-test-pack --dataset <dataset.json> --approval <approval.json> --out <approved-test-pack.json>

# 4. 승인·내용·현재 Dataset 원본 해시 검증
dotnet run --project .\src\HtsQa.Cli -c Release --no-build -- `
  validate-test-pack --file <approved-test-pack.json> --dataset <dataset.json>

# 5. 실제 UI 동작 없는 PENDING dry-run
.\scripts\run-target-rule-suite.ps1 -TestPackPath <approved-test-pack.json> -DryRun -SkipExcel
```

`run-rule-dataset`은 Dataset 직접 실행을 막기 위해 지원 종료되었다. `run-target-rule-suite.ps1`, `run-target-rule-suite-recorded.ps1`, `plan-scenario-bindings.ps1`은 `-DatasetPath` 대신 `-TestPackPath`를 받는다. 자동 파이프라인은 시나리오 생성 원본 검증용 `-DatasetPath`와 Runner 입력용 `-TestPackPath`를 함께 받으며 두 해시가 다르면 실행 전에 중단한다.

미승인, 내용 손상, 승인 hash 불일치, Dataset 변경은 파이프라인 계약 오류다. dry-run 결과는 실제 HTS를 실행하지 않았으므로 계속 `PENDING`이며 PASS로 기록하지 않는다.
