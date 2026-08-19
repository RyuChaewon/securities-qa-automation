<#
.SYNOPSIS 최소화되거나 가려진 대상 프로그램 메인 창을 찾아 전경으로 복구한다.
.DESCRIPTION 화면 테스트 전 준비용이며 업무 화면 내부 컨트롤은 조작하지 않는다.
#>
param(
    [string]$OutputPath = "reports\target-window-restore.json",
    [Parameter(Mandatory = $true)]
    [string]$DatasetPath,
    [switch]$Maximize
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\pipeline-common.ps1")
$targetContext = Get-RuleTargetContext $root $DatasetPath
$output = if([IO.Path]::IsPathRooted($OutputPath)){$OutputPath}else{Join-Path $root $OutputPath}
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class HtsRestoreNative {
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
}
'@

$targets=New-Object Collections.Generic.List[object]
[void][HtsRestoreNative]::EnumWindows({
    param($hwnd,$lparam)
    [uint32]$processId=0
    [void][HtsRestoreNative]::GetWindowThreadProcessId($hwnd,[ref]$processId)
    $title=New-Object Text.StringBuilder 1024
    $class=New-Object Text.StringBuilder 512
    [void][HtsRestoreNative]::GetWindowText($hwnd,$title,$title.Capacity)
    [void][HtsRestoreNative]::GetClassName($hwnd,$class,$class.Capacity)
    $targets.Add([pscustomobject]@{hwnd=$hwnd.ToInt64();pid=[int]$processId;title=$title.ToString();className=$class.ToString();visible=[HtsRestoreNative]::IsWindowVisible($hwnd)})
    return $true
},[IntPtr]::Zero)

$main=@($targets | Where-Object {
    $classOk=(-not $targetContext.WindowClassName)-or$_.className-eq$targetContext.WindowClassName
    $titleOk=(-not $targetContext.WindowTitlePrefix)-or$_.title.StartsWith($targetContext.WindowTitlePrefix)
    $classOk-and$titleOk
} | Select-Object -First 1)
$restored=$false
if($main.Count -gt 0){
    $hwnd=[IntPtr][Int64]$main[0].hwnd
    # SW_MAXIMIZE(3)는 전체 창 녹화 준비에, SW_RESTORE(9)는 일반 전경 복구에 사용한다.
    [void][HtsRestoreNative]::ShowWindow($hwnd,$(if($Maximize){3}else{9}))
    [void][HtsRestoreNative]::BringWindowToTop($hwnd)
    [void][HtsRestoreNative]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 500
    $restored=[HtsRestoreNative]::IsWindowVisible($hwnd)
}
[pscustomobject]@{restored=$restored;maximized=[bool]$Maximize;main=if($main.Count -gt 0){$main[0]}else{$null};windows=$targets.ToArray();checkedAt=(Get-Date).ToString('o')} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $output -Encoding UTF8
if(-not $restored){exit 2}
