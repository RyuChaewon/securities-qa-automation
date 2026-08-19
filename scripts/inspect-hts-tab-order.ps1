<#
.SYNOPSIS 지정 HTS 화면의 실제 키보드 탭 순서와 포커스 변화를 진단한다.
.DESCRIPTION 화면 내부에서 Tab을 순회하고 각 단계의 HWND·좌표·이미지를 저장하며 민감 문자열을 보호한다.
#>
param(
    [string]$ScreenNumber = "",
    [Parameter(Mandatory = $true)]
    [string]$DatasetPath,
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    [int]$MaxSteps = 24,
    [int]$StepDelayMs = 350,
    [switch]$KeepScreenOpen
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "modules\pipeline-common.ps1")
$targetContext = Get-RuleTargetContext $root $DatasetPath $ScreenNumber
if (-not $ScreenNumber) { $ScreenNumber = [string]$targetContext.TargetScreens[0] }
$diagnosticErrorPath = [IO.Path]::GetFullPath($OutputDir) + ".error.txt"
trap {
    $parent = Split-Path -Parent $diagnosticErrorPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    ($_ | Out-String) | Set-Content -LiteralPath $diagnosticErrorPath -Encoding UTF8
    exit 1
}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class HtsTabOrderNative {
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    public delegate bool EnumChildProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumChildProc proc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, string lParam);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
    [DllImport("user32.dll", EntryPoint="GetWindowLong")] public static extern int GetWindowLong(IntPtr hwnd, int index);

    [StructLayout(LayoutKind.Sequential)] public struct RECT {
        public int Left; public int Top; public int Right; public int Bottom;
    }
    [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
        public int cbSize; public int flags;
        public IntPtr hwndActive; public IntPtr hwndFocus; public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    public static Rectangle DifferenceBounds(Bitmap before, Bitmap after, int threshold) {
        if (before == null || after == null || before.Width != after.Width || before.Height != after.Height) {
            return Rectangle.Empty;
        }
        Rectangle area = new Rectangle(0, 0, before.Width, before.Height);
        BitmapData a = before.LockBits(area, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        BitmapData b = after.LockBits(area, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int bytes = Math.Abs(a.Stride) * a.Height;
            byte[] left = new byte[bytes];
            byte[] right = new byte[bytes];
            Marshal.Copy(a.Scan0, left, 0, bytes);
            Marshal.Copy(b.Scan0, right, 0, bytes);
            int minX = before.Width, minY = before.Height, maxX = -1, maxY = -1;
            for (int y = 0; y < before.Height; y++) {
                int row = y * a.Stride;
                for (int x = 0; x < before.Width; x++) {
                    int p = row + (x * 4);
                    int delta = Math.Abs(left[p] - right[p]) + Math.Abs(left[p + 1] - right[p + 1]) + Math.Abs(left[p + 2] - right[p + 2]);
                    if (delta <= threshold) continue;
                    if (x < minX) minX = x; if (x > maxX) maxX = x;
                    if (y < minY) minY = y; if (y > maxY) maxY = y;
                }
            }
            return maxX < minX ? Rectangle.Empty : Rectangle.FromLTRB(minX, minY, maxX + 1, maxY + 1);
        } finally {
            before.UnlockBits(a); after.UnlockBits(b);
        }
    }
}
'@

$WM_SETTEXT = 0x000C
$WM_CLOSE = 0x0010
$VK_RETURN = 0x0D
$VK_TAB = 0x09
$KEYEVENTF_KEYUP = 0x0002
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004
$WS_TABSTOP = 0x00010000

# 탭 단계에서 비교할 수 있도록 HWND의 표시 상태와 물리 경계를 한 객체로 정규화한다.
function Get-WindowInfo([IntPtr]$Hwnd) {
    $title = New-Object Text.StringBuilder 1024
    $className = New-Object Text.StringBuilder 512
    $rect = New-Object HtsTabOrderNative+RECT
    [void][HtsTabOrderNative]::GetWindowText($Hwnd, $title, $title.Capacity)
    [void][HtsTabOrderNative]::GetClassName($Hwnd, $className, $className.Capacity)
    [void][HtsTabOrderNative]::GetWindowRect($Hwnd, [ref]$rect)
    [pscustomobject]@{
        hwnd = $Hwnd.ToInt64(); visible = [HtsTabOrderNative]::IsWindowVisible($Hwnd); enabled = [HtsTabOrderNative]::IsWindowEnabled($Hwnd)
        rawTitle = $title.ToString(); className = $className.ToString()
        style = [HtsTabOrderNative]::GetWindowLong($Hwnd, -16)
        rect = [pscustomobject]@{ left=$rect.Left; top=$rect.Top; right=$rect.Right; bottom=$rect.Bottom; width=$rect.Right-$rect.Left; height=$rect.Bottom-$rect.Top }
    }
}

# 대상 메인 창 선택에 사용할 현재 데스크톱 최상위 창 목록을 수집한다.
function Get-TopWindows {
    $rows = New-Object Collections.Generic.List[object]
    [void][HtsTabOrderNative]::EnumWindows({ param($h, $l) $rows.Add((Get-WindowInfo $h)); return $true }, [IntPtr]::Zero)
    $rows
}

# 지정 부모 HWND 아래의 모든 자식 창을 진단 행 형태로 열거한다.
function Get-ChildWindows([Int64]$Parent) {
    $rows = New-Object Collections.Generic.List[object]
    [void][HtsTabOrderNative]::EnumChildWindows([IntPtr]$Parent, { param($h, $l) $rows.Add((Get-WindowInfo $h)); return $true }, [IntPtr]::Zero)
    $rows
}

# 키 누름과 키 해제를 한 쌍으로 보내 고정된 탭 순회를 재현한다.
function Send-Key([byte]$Key) {
    [HtsTabOrderNative]::keybd_event($Key, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 35
    [HtsTabOrderNative]::keybd_event($Key, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

# 이미 대상 창 안으로 검증된 컨트롤의 중심점을 한 번 클릭한다.
function Click-Center($Window) {
    $x = [int](($Window.rect.left + $Window.rect.right) / 2)
    $y = [int](($Window.rect.top + $Window.rect.bottom) / 2)
    [void][HtsTabOrderNative]::SetCursorPos($x, $y)
    [HtsTabOrderNative]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [HtsTabOrderNative]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}

# 포커스 변화 전후를 비교할 수 있도록 현재 콘텐츠 창 영역만 캡처한다.
function Capture-Screen($Screen, [string]$Path) {
    $bitmap = New-Object Drawing.Bitmap([int]$Screen.rect.width, [int]$Screen.rect.height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([int]$Screen.rect.left, [int]$Screen.rect.top, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
        $bitmap
    } finally {
        $graphics.Dispose()
    }
}

# 포커스 제목에서 계좌·비밀번호로 오인될 수 있는 숫자 원문을 저장 전에 마스킹한다.
function Protect-DiagnosticText([string]$Value) {
    if (-not $Value) { return "" }
    if ($Value -match '^\d{9,14}$') {
        return $Value.Substring(0, [Math]::Min(3, $Value.Length)) + '****' + $Value.Substring([Math]::Max(3, $Value.Length - 3))
    }
    if ($Value -match '^\d{1,8}$') { return '******' }
    $Value
}

# Win32 포커스, UIA 포커스, 캐럿과 이미지 변화 영역을 하나의 탭 단계 증거로 묶는다.
function Get-FocusSnapshot($Screen, [int]$Step, [string]$ImagePath, $Difference) {
    $threadInfo = New-Object HtsTabOrderNative+GUITHREADINFO
    $threadInfo.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][HtsTabOrderNative+GUITHREADINFO])
    [void][HtsTabOrderNative]::GetGUIThreadInfo(0, [ref]$threadInfo)
    $focusWindow = if ($threadInfo.hwndFocus -ne [IntPtr]::Zero) { Get-WindowInfo $threadInfo.hwndFocus } else { $null }
    if ($focusWindow) { $focusWindow.rawTitle = Protect-DiagnosticText ([string]$focusWindow.rawTitle) }
    $uia = $null
    try {
        $element = [Windows.Automation.AutomationElement]::FocusedElement
        if ($element) {
            $current = $element.Current
            $bounds = $current.BoundingRectangle
            $uia = [pscustomobject]@{
                name=(Protect-DiagnosticText ([string]$current.Name)); automationId=[string]$current.AutomationId; className=[string]$current.ClassName
                controlType=[string]$current.ControlType.ProgrammaticName; isEnabled=[bool]$current.IsEnabled; isKeyboardFocusable=[bool]$current.IsKeyboardFocusable
                rect=[pscustomobject]@{left=[int]$bounds.Left;top=[int]$bounds.Top;right=[int]$bounds.Right;bottom=[int]$bounds.Bottom;width=[int]$bounds.Width;height=[int]$bounds.Height}
                runtimeId=(@($element.GetRuntimeId()) -join '.')
            }
        }
    } catch { }
    [pscustomobject]@{
        step=$Step; image=[IO.Path]::GetFileName($ImagePath)
        focusWindow=$focusWindow; uia=$uia
        caret=[pscustomobject]@{hwnd=$threadInfo.hwndCaret.ToInt64();left=$threadInfo.rcCaret.Left;top=$threadInfo.rcCaret.Top;right=$threadInfo.rcCaret.Right;bottom=$threadInfo.rcCaret.Bottom}
        changedRect=if($Difference){[pscustomobject]@{left=$Difference.Left;top=$Difference.Top;right=$Difference.Right;bottom=$Difference.Bottom;width=$Difference.Width;height=$Difference.Height}}else{$null}
    }
}

$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$main = Get-TopWindows | Where-Object {
    $classOk = (-not $targetContext.WindowClassName) -or $_.className -eq $targetContext.WindowClassName
    $titleOk = (-not $targetContext.WindowTitlePrefix) -or $_.rawTitle.StartsWith($targetContext.WindowTitlePrefix)
    $_.visible -and $classOk -and $titleOk
} | Select-Object -First 1
if (-not $main) { throw "$($targetContext.DisplayName) 메인 창을 찾을 수 없습니다." }

$mainChildren = @(Get-ChildWindows ([Int64]$main.hwnd))
$screenEdit = $mainChildren | Where-Object {
    $_.visible -and $_.enabled -and $_.className -eq 'Edit' -and $_.rect.left -lt ($main.rect.left + 250) -and $_.rect.top -lt ($main.rect.top + 90)
} | Sort-Object rect.top,rect.left | Select-Object -First 1
if (-not $screenEdit) { throw '화면번호 입력칸을 찾을 수 없습니다.' }

[void][HtsTabOrderNative]::SendMessage([IntPtr][Int64]$screenEdit.hwnd, $WM_SETTEXT, [IntPtr]::Zero, $ScreenNumber)
[void][HtsTabOrderNative]::SetForegroundWindow([IntPtr][Int64]$main.hwnd)
Click-Center $screenEdit
Send-Key $VK_RETURN
Start-Sleep -Seconds 3

$screen = Get-ChildWindows ([Int64]$main.hwnd) | Where-Object { $_.visible -and $_.rawTitle -match ('^\[' + [regex]::Escape($ScreenNumber) + '\]') } |
    Sort-Object @{Expression={$_.rect.width*$_.rect.height};Descending=$true} | Select-Object -First 1
if (-not $screen) { throw "[$ScreenNumber] 화면을 찾을 수 없습니다." }

$allChildren = @(Get-ChildWindows ([Int64]$screen.hwnd) | Where-Object {
    $_.visible -and $_.enabled -and $_.rect.width -ge 8 -and $_.rect.height -ge 8 -and $_.rect.top -ge ($screen.rect.top + 30)
})
$contentInputs = @($allChildren | Where-Object {
    $_.className -in @('Edit','ComboBox','ComboBoxEx32') -or $_.rawTitle -match '^\d{8,14}(-\d{3})?$'
} | Sort-Object rect.top,rect.left)
if ($contentInputs.Count -eq 0) {
    $contentInputs = @($allChildren | Where-Object { (([Int64]$_.style -band $WS_TABSTOP) -ne 0) } | Sort-Object rect.top,rect.left)
}
if ($contentInputs.Count -eq 0) {
    $contentInputs = @($allChildren | Where-Object {
        $_.className -like 'AfxWnd*' -and $_.rect.height -le 40 -and $_.rect.top -le ($screen.rect.top + 220)
    } | Sort-Object rect.top,rect.left)
}
if ($contentInputs.Count -eq 0) { throw '탭오더 시작점 후보를 찾을 수 없습니다.' }
Click-Center $contentInputs[0]
Start-Sleep -Milliseconds $StepDelayMs

$steps = New-Object Collections.Generic.List[object]
$previousBitmap = $null
try {
    for ($step = 0; $step -le $MaxSteps; $step++) {
        if ($step -gt 0) {
            Send-Key $VK_TAB
            Start-Sleep -Milliseconds $StepDelayMs
        }
        $imagePath = Join-Path $OutputDir ('tab-{0:D2}.png' -f $step)
        $bitmap = Capture-Screen $screen $imagePath
        $difference = if ($previousBitmap) { [HtsTabOrderNative]::DifferenceBounds($previousBitmap, $bitmap, 24) } else { $null }
        $steps.Add((Get-FocusSnapshot $screen $step $imagePath $difference))
        if ($previousBitmap) { $previousBitmap.Dispose() }
        $previousBitmap = $bitmap
    }
} finally {
    if ($previousBitmap) { $previousBitmap.Dispose() }
    if (-not $KeepScreenOpen -and [HtsTabOrderNative]::IsWindowVisible([IntPtr][Int64]$screen.hwnd)) {
        [void][HtsTabOrderNative]::SendMessage([IntPtr][Int64]$screen.hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    }
}

[pscustomobject]@{
    screenNumber=$ScreenNumber; screenTitle=$screen.rawTitle; startedFrom=$contentInputs[0]
    childWindows=@($allChildren | ForEach-Object {
        [pscustomobject]@{
            hwnd=$_.hwnd; visible=$_.visible; enabled=$_.enabled; rawTitle=(Protect-DiagnosticText ([string]$_.rawTitle))
            className=$_.className; style=$_.style; tabStop=(([Int64]$_.style -band $WS_TABSTOP) -ne 0); rect=$_.rect
        }
    })
    maxSteps=$MaxSteps; steps=$steps.ToArray(); capturedAt=(Get-Date).ToString('o')
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDir 'tab-order.json') -Encoding UTF8

Write-Output (Join-Path $OutputDir 'tab-order.json')
