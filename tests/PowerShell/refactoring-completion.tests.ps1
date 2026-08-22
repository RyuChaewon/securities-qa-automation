<# .SYNOPSIS Runs the read-only refactoring ownership and safety boundary regression gate. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$verifier = Join-Path $root 'scripts\dev\verify-refactoring-completion.ps1'
$output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifier 2>&1)
if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
if (($output -join [Environment]::NewLine) -notmatch 'REFACTORING_COMPLETION=PASS') {
    throw "Refactoring completion verifier did not emit PASS: $($output -join [Environment]::NewLine)"
}
Write-Output 'REFACTORING_COMPLETION_TESTS=PASS assertions=1'
