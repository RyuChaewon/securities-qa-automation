<#
.SYNOPSIS F8 hover hotkey로 redacted Control Repository 검토 후보를 생성한다.
.DESCRIPTION cursor를 이동하거나 click하지 않으며 결과는 ReviewRequired capture JSON일 뿐 repository 승인 entry가 아니다.
#>
param(
    [Parameter(Mandatory=$true)][Int64]$RootHwnd,
    [Parameter(Mandatory=$true)][string]$StateContext,
    [Parameter(Mandatory=$true)][string]$MapScreenCode,
    [ValidateSet('MapHostClient','ScreenClient')][string]$CoordinateSpace='ScreenClient',
    [Parameter(Mandatory=$true)][string]$OutPath,
    [string]$FlaUiAssembly=''
)

$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'modules\hts-session.ps1')
. (Join-Path $PSScriptRoot 'modules\hts-control-repository.ps1')

if (-not $FlaUiAssembly) {
    $FlaUiAssembly=Join-Path $root 'src\HtsQa.FlaUi\bin\Release\net8.0-windows7.0\HtsQa.FlaUi.dll'
}
$session=New-HtsSessionContext -FlaUiAssembly $FlaUiAssembly -DisplayName 'read-only capture target' -GetTopWindows { @() }
[void](Start-FlaUiBridge -Context $session)
try {
    $captureContext=New-HtsControlCaptureContext -SessionContext $session -Dependencies ([pscustomobject]@{
        ReadHotkey={ $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
        GetCursorPosition={ Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.Cursor]::Position }
        InvokeBridgeRequest={ param($Context,$Request) Invoke-FlaUiBridgeRequest -Context $Context -Request $Request }
    })
    Write-Host '대상 위에 cursor를 올리고 F8을 누르십시오. 도구는 cursor 이동이나 click을 수행하지 않습니다.'
    $candidate=Invoke-HtsControlCandidateCapture -Context $captureContext -RootHwnd $RootHwnd -StateContext $StateContext -MapScreenCode $MapScreenCode -CoordinateSpace $CoordinateSpace
    $fullOut=[IO.Path]::GetFullPath($OutPath)
    $parent=Split-Path -Parent $fullOut
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent) }
    $candidate | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fullOut -Encoding UTF8
    Write-Output $fullOut
} finally {
    Stop-FlaUiBridge -Context $session
}
