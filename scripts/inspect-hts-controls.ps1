<#
.SYNOPSIS 현재 HTS 창의 네이티브 자식 컨트롤 구조를 진단한다.
.DESCRIPTION HWND, 클래스, 제목, 좌표를 읽기 전용으로 수집해 로케이터와 콘텐츠 경계 보완에 사용한다.
#>
param(
    [string]$ScreenNumber = "",
    [Parameter(Mandatory = $true)]
    [string]$DatasetPath,
    [Parameter(Mandatory=$true)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\pipeline-common.ps1")
$targetContext = Get-RuleTargetContext $root $DatasetPath $ScreenNumber
if (-not $ScreenNumber) { $ScreenNumber = [string]$targetContext.TargetScreens[0] }
trap {
    $_.Exception.ToString() | Set-Content -LiteralPath ($OutputPath + ".error.txt") -Encoding UTF8
    exit 1
}
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class HtsInspectNative {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  public delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumChildProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, string lParam);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", EntryPoint="GetWindowLong")] public static extern int GetWindowLong32(IntPtr hWnd, int index);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtr")] public static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);
  [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  public static long GetStyle(IntPtr hWnd) { return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, -16).ToInt64() : GetWindowLong32(hWnd, -16); }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

# 단일 HWND에서 제목·클래스·상태·화면 좌표를 읽어 직렬화 가능한 진단 행으로 만든다.
function Get-Info([IntPtr]$Hwnd) {
    $title=New-Object Text.StringBuilder 1024
    $class=New-Object Text.StringBuilder 512
    $rect=New-Object HtsInspectNative+RECT
    [void][HtsInspectNative]::GetWindowText($Hwnd,$title,$title.Capacity)
    [void][HtsInspectNative]::GetClassName($Hwnd,$class,$class.Capacity)
    [void][HtsInspectNative]::GetWindowRect($Hwnd,[ref]$rect)
    [pscustomobject]@{
        hwnd=$Hwnd.ToInt64();parent=([HtsInspectNative]::GetParent($Hwnd)).ToInt64()
        visible=[HtsInspectNative]::IsWindowVisible($Hwnd);enabled=[HtsInspectNative]::IsWindowEnabled($Hwnd)
        className=$class.ToString();rawTitle=$title.ToString();style=[HtsInspectNative]::GetStyle($Hwnd)
        rect=[pscustomobject]@{left=$rect.Left;top=$rect.Top;right=$rect.Right;bottom=$rect.Bottom;width=$rect.Right-$rect.Left;height=$rect.Bottom-$rect.Top}
    }
}

$top=New-Object Collections.Generic.List[object]
[void][HtsInspectNative]::EnumWindows({param($h,$l);$top.Add((Get-Info $h));return $true},[IntPtr]::Zero)
$main=$top|Where-Object{
    $classOk=(-not $targetContext.WindowClassName)-or$_.className-eq$targetContext.WindowClassName
    $titleOk=(-not $targetContext.WindowTitlePrefix)-or$_.rawTitle.StartsWith($targetContext.WindowTitlePrefix)
    $_.visible-and$classOk-and$titleOk
}|Select-Object -First 1
if(-not$main){throw "$($targetContext.DisplayName) 메인 창을 찾을 수 없습니다."}

$children=New-Object Collections.Generic.List[object]
[void][HtsInspectNative]::EnumChildWindows([IntPtr][Int64]$main.hwnd,{param($h,$l);$children.Add((Get-Info $h));return $true},[IntPtr]::Zero)
$screenEdit=$children|Where-Object{$_.visible-and$_.enabled-and$_.className-eq"Edit"-and$_.rect.left-lt($main.rect.left+250)-and$_.rect.top-lt($main.rect.top+90)-and$_.rect.width-ge35-and$_.rect.width-le180}|Sort-Object rect.top,rect.left|Select-Object -First 1
if(-not$screenEdit){throw "화면번호 입력칸을 찾을 수 없습니다."}
[void][HtsInspectNative]::SendMessage([IntPtr][Int64]$screenEdit.hwnd,0x000C,[IntPtr]::Zero,$ScreenNumber)
[void][HtsInspectNative]::SetForegroundWindow([IntPtr][Int64]$main.hwnd)
[HtsInspectNative]::keybd_event(0x0D,0,0,[UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[HtsInspectNative]::keybd_event(0x0D,0,0x0002,[UIntPtr]::Zero)
Start-Sleep -Seconds 3

$children=New-Object Collections.Generic.List[object]
[void][HtsInspectNative]::EnumChildWindows([IntPtr][Int64]$main.hwnd,{param($h,$l);$children.Add((Get-Info $h));return $true},[IntPtr]::Zero)
$screen=$children|Where-Object{$_.visible-and$_.rawTitle-match("^\["+[regex]::Escape($ScreenNumber)+"\]")}|Sort-Object @{Expression={$_.rect.width*$_.rect.height};Descending=$true}|Select-Object -First 1
if(-not$screen){throw "[$ScreenNumber] 화면을 찾을 수 없습니다."}
$screenChildren=New-Object Collections.Generic.List[object]
[void][HtsInspectNative]::EnumChildWindows([IntPtr][Int64]$screen.hwnd,{param($h,$l);$screenChildren.Add((Get-Info $h));return $true},[IntPtr]::Zero)
[pscustomobject]@{screenNumber=$ScreenNumber;main=$main;screen=$screen;children=@($screenChildren|Sort-Object {$_.rect.top},{$_.rect.left})} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
[void][HtsInspectNative]::SendMessage([IntPtr][Int64]$screen.hwnd,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
$OutputPath
