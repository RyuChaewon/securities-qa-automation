<#
.SYNOPSIS 실행 중인 HTS 최상위 창 후보를 읽기 전용으로 진단한다.
.DESCRIPTION 데이터셋 targetProfile의 설치 경로, 창 제목, 창 클래스 중 하나와 일치하는 표시 창만 JSON으로 저장한다.
.INPUTS 대상 데이터셋 경로, 선택적 설치 경로·창 정규식 재정의, 출력 JSON 경로.
.OUTPUTS 대상 프로필과 일치한 최상위 창 후보 목록.
.NOTES 화면번호와 제품별 설치·창 식별값은 이 파일에 두지 않고 targetProfile에서 읽는다.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$DatasetPath,
    [string]$InstallationRoot = "",
    [string]$TitlePattern = "",
    [string]$ClassPattern = "",
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\pipeline-common.ps1")

# 대상별 설치·창 식별값은 데이터셋이 소유하며 명령행 값은 일회성 진단 재정의에만 사용한다.
$targetContext = Get-RuleTargetContext $root $DatasetPath '' $InstallationRoot
$InstallationRoot = $targetContext.InstallationRoot
if (-not $TitlePattern -and $targetContext.WindowTitlePrefix) {
    $TitlePattern = [regex]::Escape($targetContext.WindowTitlePrefix)
}
if (-not $ClassPattern -and $targetContext.WindowClassName) {
    $ClassPattern = '^' + [regex]::Escape($targetContext.WindowClassName) + '$'
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class HtsWindowDiagnosticNative {
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

$normalizedRoot = if ($InstallationRoot) { [IO.Path]::GetFullPath($InstallationRoot).TrimEnd('\') + '\' } else { '' }
$rows = New-Object Collections.Generic.List[object]

# EnumWindows 콜백 안에서는 창이 사라질 수 있으므로 각 속성을 독립적으로 읽고 실패 후보는 건너뛴다.
[void][HtsWindowDiagnosticNative]::EnumWindows({
    param($hwnd, $lParam)

    if (-not [HtsWindowDiagnosticNative]::IsWindowVisible($hwnd)) { return $true }

    $titleBuilder = New-Object Text.StringBuilder 1024
    $classBuilder = New-Object Text.StringBuilder 512
    $rect = New-Object HtsWindowDiagnosticNative+RECT
    [uint32]$processId = 0
    [void][HtsWindowDiagnosticNative]::GetWindowText($hwnd, $titleBuilder, $titleBuilder.Capacity)
    [void][HtsWindowDiagnosticNative]::GetClassName($hwnd, $classBuilder, $classBuilder.Capacity)
    [void][HtsWindowDiagnosticNative]::GetWindowThreadProcessId($hwnd, [ref]$processId)
    [void][HtsWindowDiagnosticNative]::GetWindowRect($hwnd, [ref]$rect)

    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    $processPath = ""
    try { $processPath = [string]$process.Path } catch { $processPath = "" }

    $title = $titleBuilder.ToString()
    $className = $classBuilder.ToString()
    $pathMatches = $normalizedRoot -and $processPath -and $processPath.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)
    $titleMatches = $TitlePattern -and $title -match $TitlePattern
    $classMatches = $ClassPattern -and $className -match $ClassPattern
    if (-not ($pathMatches -or $titleMatches -or $classMatches)) { return $true }

    $rows.Add([pscustomobject]@{
        hwnd = $hwnd.ToInt64()
        processId = $processId
        processName = [string]$process.ProcessName
        processPath = $processPath
        title = $title
        className = $className
        rect = [pscustomobject]@{
            left = $rect.Left
            top = $rect.Top
            right = $rect.Right
            bottom = $rect.Bottom
            width = $rect.Right - $rect.Left
            height = $rect.Bottom - $rect.Top
        }
    })
    return $true
}, [IntPtr]::Zero)

$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $fullOutputPath
if ($outputDirectory) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }

[pscustomobject]@{
    capturedAt = (Get-Date).ToString("o")
    targetProfileId = $targetContext.ProfileId
    targetDisplayName = $targetContext.DisplayName
    installationRoot = $normalizedRoot
    isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    candidateCount = $rows.Count
    candidates = @($rows | Sort-Object processId, hwnd)
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fullOutputPath -Encoding UTF8

Write-Output $fullOutputPath
