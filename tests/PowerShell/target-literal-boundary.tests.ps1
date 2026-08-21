<# .SYNOPSIS 0101 target literal이 src와 generic scripts/tools로 다시 유입되는 것을 차단한다. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}

$script:assertions = 0
$targetRoot = Join-Path $root 'targets\1q-hts\0101'
foreach ($relativePath in @(
    'target-profile.json',
    'tools\import-testcases.mjs',
    'scripts\import-testcases.ps1',
    'scripts\run-live-validation-v2.ps1'
)) {
    Assert-True (Test-Path -LiteralPath (Join-Path $targetRoot $relativePath) -PathType Leaf) "target adapter file exists: $relativePath"
}
foreach ($legacyPath in @(
    'tools\import-0101-testcases.mjs',
    'scripts\import-0101-testcases.ps1',
    'scripts\run-0101-live-validation-v2.ps1'
)) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $legacyPath))) "legacy generic target path removed: $legacyPath"
}
$genericFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter '*.cs' |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
    Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1','.cmd') }
    Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Recurse -File |
        Where-Object { $_.Extension -in @('.mjs','.js','.ps1','.cs') -and $_.FullName -notmatch '\\node_modules\\' }
)

$forbidden = [ordered]@{
    screenId = '(?<![0-9])0101(?![0-9])'
    internalScreen = 'HT0101'
    stateControl = 'TAB_Ord'
    commandControl = 'BTN_Ord_(Buy|Sell|Mod|Can)'
    stateContext = 'order-tab:'
    compatibilitySemantic = 'OrderTab'
    confirmationText = '(매수|매도|정정|취소)\s*주문'
}
$violations = New-Object Collections.Generic.List[string]
foreach ($file in $genericFiles) {
    $relative = $file.FullName.Substring($root.Length).TrimStart('\')
    Assert-True (-not $relative.StartsWith('targets\',[StringComparison]::OrdinalIgnoreCase)) 'target files are excluded from the generic scan'
    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    # 공개 인자 이름의 유일한 호환 alias는 해석 분기가 아니며 migration 제거 시점까지 허용한다.
    $scanText = $text -replace "\[Alias\('OrderTabStateOverride'\)\]", ''
    foreach ($entry in $forbidden.GetEnumerator()) {
        if ($scanText -match [string]$entry.Value) {
            $violations.Add("$relative [$($entry.Key)]")
        }
    }
}

Assert-True ($violations.Count -eq 0) ("generic target literal violations: " + ($violations -join ', '))
Assert-True (@($genericFiles).Count -gt 0) 'generic scan has source files'
Write-Output "TARGET_LITERAL_BOUNDARY=PASS files=$($genericFiles.Count) assertions=$script:assertions"
