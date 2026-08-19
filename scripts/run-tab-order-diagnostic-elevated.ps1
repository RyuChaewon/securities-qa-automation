<#
.SYNOPSIS 관리자 권한 HTS와 같은 무결성 수준에서 탭오더 진단기를 실행한다.
.DESCRIPTION 권한 차이 때문에 HWND 포커스를 읽지 못하는 경우 사용하는 얇은 승격 래퍼다.
#>
param(
    [string]$ScreenNumber = "",
    [Parameter(Mandatory = $true)]
    [string]$DatasetPath,
    [string]$OutputDir = "reports\tab-order-diagnostic",
    [int]$MaxSteps = 24
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$diagnostic = Join-Path $PSScriptRoot "inspect-hts-tab-order.ps1"
$output = if ([IO.Path]::IsPathRooted($OutputDir)) { [IO.Path]::GetFullPath($OutputDir) } else { [IO.Path]::GetFullPath((Join-Path $root $OutputDir)) }
$arguments = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $diagnostic,
    "-ScreenNumber", $ScreenNumber, "-DatasetPath", $DatasetPath, "-OutputDir", $output, "-MaxSteps", $MaxSteps
)
$process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0) { throw "관리자 권한 탭오더 진단이 실패했습니다. 종료 코드: $($process.ExitCode)" }
$result = Join-Path $output "tab-order.json"
if (-not (Test-Path -LiteralPath $result)) { throw "탭오더 진단 결과가 생성되지 않았습니다: $result" }
Write-Output $result
