<#
.SYNOPSIS HTS 메인 창 전체의 물리 픽셀 프레임을 수집하고 MP4로 인코딩한다.
.DESCRIPTION DPI 보정, 창 재생성 추적, 프레임 누락 검사를 수행하며 지정 HTS 창 밖은 캡처하지 않는다.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$OutDir,

    [Parameter(Mandatory=$true)]
    [string]$VideoOut,

    [int]$DurationSeconds = 180,

    [double]$Fps = 5.0,

    [string]$StopFile = "",

    [string]$WindowClass = "",

    [string]$WindowTitlePrefix = "",

    [switch]$ShowCursor
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$encoder = Join-Path $root "tools\encode_frames_video.py"
$done = Join-Path (Split-Path -Parent $VideoOut) "recording.done.json"
$errorLog = Join-Path (Split-Path -Parent $VideoOut) "recording.error.txt"
$cursorTracePath = Join-Path (Split-Path -Parent $VideoOut) "cursor-trace.ndjson"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $VideoOut) | Out-Null
if (Test-Path -LiteralPath $cursorTracePath) { Remove-Item -LiteralPath $cursorTracePath -Force }

try {
    # DPI awareness must be set before Windows Forms reads monitor metrics.
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RecorderDpiNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);
}
'@
    $dpiAwarenessEnabled = [RecorderDpiNative]::SetProcessDpiAwarenessContext([IntPtr](-4))

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class DesktopFrameNative {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);
  [DllImport("user32.dll")] public static extern bool GetPhysicalCursorPos(out POINT point);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT value, int valueSize);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

    # Win32 창 제목을 읽어 녹화 대상 후보를 식별한다.
    function Get-WindowTextValue([IntPtr]$Hwnd) {
        $builder = New-Object System.Text.StringBuilder 1024
        [void][DesktopFrameNative]::GetWindowText($Hwnd, $builder, $builder.Capacity)
        return $builder.ToString()
    }

    # 데이터셋에서 전달된 창 클래스명으로 대상 HTS 메인 프레임과 일반 팝업을 구분한다.
    function Get-WindowClassValue([IntPtr]$Hwnd) {
        $builder = New-Object System.Text.StringBuilder 512
        [void][DesktopFrameNative]::GetClassName($Hwnd, $builder, $builder.Capacity)
        return $builder.ToString()
    }

    # DWM의 실제 테두리 좌표를 우선 사용해 DPI 배율에서도 HTS 전체가 잘리지 않게 한다.
    function Get-PhysicalWindowBounds([IntPtr]$Hwnd) {
        $rect = New-Object DesktopFrameNative+RECT
        $dwmResult = [DesktopFrameNative]::DwmGetWindowAttribute(
            $Hwnd,
            9,
            [ref]$rect,
            [Runtime.InteropServices.Marshal]::SizeOf([type][DesktopFrameNative+RECT]))
        if ($dwmResult -ne 0 -or $rect.Right -le $rect.Left -or $rect.Bottom -le $rect.Top) {
            if (-not [DesktopFrameNative]::GetWindowRect($Hwnd, [ref]$rect)) {
                throw "GetWindowRect failed for window $Hwnd."
            }
        }
        $width = [Math]::Max(1, $rect.Right - $rect.Left)
        $height = [Math]::Max(1, $rect.Bottom - $rect.Top)
        return New-Object System.Drawing.Rectangle $rect.Left, $rect.Top, $width, $height
    }

    # 클래스·제목이 맞는 최상위 창 중 면적이 가장 큰 창을 HTS 메인 창으로 선택한다.
    function Find-CaptureWindow {
        if (-not $WindowClass -and -not $WindowTitlePrefix) {
            return [IntPtr]::Zero
        }
        $script:windowCandidates = New-Object System.Collections.Generic.List[object]
        [void][DesktopFrameNative]::EnumWindows({
            param($h, $l)
            if (-not [DesktopFrameNative]::IsWindowVisible($h)) { return $true }
            $title = Get-WindowTextValue $h
            $className = Get-WindowClassValue $h
            $classOk = (-not $WindowClass) -or ($className -eq $WindowClass)
            $titleOk = (-not $WindowTitlePrefix) -or ($title.StartsWith($WindowTitlePrefix))
            if ($classOk -and $titleOk) {
                try {
                    $candidateBounds = Get-PhysicalWindowBounds $h
                    $script:windowCandidates.Add([pscustomobject]@{
                        Hwnd = $h
                        Area = [long]$candidateBounds.Width * [long]$candidateBounds.Height
                    })
                } catch {
                    # Ignore a window that disappears during enumeration.
                }
            }
            return $true
        }, [IntPtr]::Zero)
        $best = $script:windowCandidates | Sort-Object Area -Descending | Select-Object -First 1
        if ($null -eq $best) { return [IntPtr]::Zero }
        return [IntPtr]$best.Hwnd
    }

    # 화면 복사가 가능한 가상 데스크톱 범위 안에 창 전체가 들어오는지 확인한다.
    function Test-BoundsInsideVirtualScreen([System.Drawing.Rectangle]$Bounds) {
        $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
        return $Bounds.Left -ge $virtual.Left -and
            $Bounds.Top -ge $virtual.Top -and
            $Bounds.Right -le $virtual.Right -and
            $Bounds.Bottom -le $virtual.Bottom
    }

    $script:captureWindow = Find-CaptureWindow
    if (($WindowClass -or $WindowTitlePrefix) -and $script:captureWindow -eq [IntPtr]::Zero) {
        throw "Could not find capture window class='$WindowClass' titlePrefix='$WindowTitlePrefix'."
    }

    if ($script:captureWindow -eq [IntPtr]::Zero) {
        $initialWindowBounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        [uint32]$script:capturePid = 0
        $windowDpi = 0
    } else {
        $initialWindowBounds = Get-PhysicalWindowBounds $script:captureWindow
        [uint32]$script:capturePid = 0
        [void][DesktopFrameNative]::GetWindowThreadProcessId($script:captureWindow, [ref]$script:capturePid)
        $windowDpi = [DesktopFrameNative]::GetDpiForWindow($script:captureWindow)
    }

    # Common video codecs require even dimensions. Padding is added, never cropped.
    $canvasWidth = $initialWindowBounds.Width + ($initialWindowBounds.Width % 2)
    $canvasHeight = $initialWindowBounds.Height + ($initialWindowBounds.Height % 2)
    $intervalMs = [Math]::Max(1, [int](1000.0 / $Fps))
    $recordingStartedAt = Get-Date
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $frame = 0
    $attempt = 0
    $skipped = 0
    $repeated = 0
    $reacquired = 0
    $rescaled = 0
    $copyFromScreenFrames = 0
    $printWindowFrames = 0
    $cursorFrames = 0
    $cursorTraceRows = New-Object System.Collections.Generic.List[string]
    $lastGoodFrame = $null
    $lastWindowBounds = $initialWindowBounds
    $maxFrames = [Math]::Ceiling($DurationSeconds * $Fps)

    # 매 프레임 창 위치를 다시 읽어 이동·크기 변경·핸들 재생성에도 같은 캔버스에 전체 창을 기록한다.
    while ($stopwatch.Elapsed.TotalSeconds -lt $DurationSeconds -and $attempt -lt $maxFrames) {
        if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { break }
        $loopStart = [System.Diagnostics.Stopwatch]::StartNew()
        $sourceBitmap = $null
        $sourceGraphics = $null
        $outputBitmap = $null
        $outputGraphics = $null
        try {
            if (($WindowClass -or $WindowTitlePrefix) -and
                ($script:captureWindow -eq [IntPtr]::Zero -or -not [DesktopFrameNative]::IsWindow($script:captureWindow))) {
                $replacement = Find-CaptureWindow
                if ($replacement -eq [IntPtr]::Zero) { throw "Capture window is temporarily unavailable." }
                $script:captureWindow = $replacement
                [uint32]$script:capturePid = 0
                [void][DesktopFrameNative]::GetWindowThreadProcessId($script:captureWindow, [ref]$script:capturePid)
                $reacquired++
            }

            $currentBounds = if ($script:captureWindow -eq [IntPtr]::Zero) {
                [System.Windows.Forms.SystemInformation]::VirtualScreen
            } else {
                Get-PhysicalWindowBounds $script:captureWindow
            }
            $lastWindowBounds = $currentBounds
            $sourceBitmap = New-Object System.Drawing.Bitmap $currentBounds.Width, $currentBounds.Height
            $sourceGraphics = [System.Drawing.Graphics]::FromImage($sourceBitmap)

            $foreground = [DesktopFrameNative]::GetForegroundWindow()
            [uint32]$foregroundPid = 0
            if ($foreground -ne [IntPtr]::Zero) {
                [void][DesktopFrameNative]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
            }
            $captured = $false
            $sameHtsProcessIsForeground = $script:captureWindow -eq [IntPtr]::Zero -or [int]$foregroundPid -eq [int]$script:capturePid
            if ($sameHtsProcessIsForeground -and (Test-BoundsInsideVirtualScreen $currentBounds)) {
                $sourceGraphics.CopyFromScreen($currentBounds.Location, [System.Drawing.Point]::Empty, $currentBounds.Size)
                $captured = $true
                $copyFromScreenFrames++
            } elseif ($script:captureWindow -ne [IntPtr]::Zero) {
                $hdc = $sourceGraphics.GetHdc()
                try {
                    $captured = [DesktopFrameNative]::PrintWindow($script:captureWindow, $hdc, 2)
                } finally {
                    $sourceGraphics.ReleaseHdc($hdc)
                }
                if ($captured) { $printWindowFrames++ }
            }
            if (-not $captured -and (Test-BoundsInsideVirtualScreen $currentBounds)) {
                $sourceGraphics.CopyFromScreen($currentBounds.Location, [System.Drawing.Point]::Empty, $currentBounds.Size)
                $captured = $true
                $copyFromScreenFrames++
            }
            if (-not $captured) { throw "The full HTS window frame could not be captured." }

            $outputBitmap = New-Object System.Drawing.Bitmap $canvasWidth, $canvasHeight
            $outputGraphics = [System.Drawing.Graphics]::FromImage($outputBitmap)
            $outputGraphics.Clear([System.Drawing.Color]::Black)
            $scale = [Math]::Min($canvasWidth / [double]$currentBounds.Width, $canvasHeight / [double]$currentBounds.Height)
            $drawWidth = [Math]::Max(1, [int][Math]::Round($currentBounds.Width * $scale))
            $drawHeight = [Math]::Max(1, [int][Math]::Round($currentBounds.Height * $scale))
            $drawX = [int](($canvasWidth - $drawWidth) / 2)
            $drawY = [int](($canvasHeight - $drawHeight) / 2)
            if ($drawWidth -ne $currentBounds.Width -or $drawHeight -ne $currentBounds.Height) { $rescaled++ }
            $outputGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $outputGraphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $outputGraphics.DrawImage($sourceBitmap, $drawX, $drawY, $drawWidth, $drawHeight)
            if ($ShowCursor) {
                $cursorPoint = New-Object DesktopFrameNative+POINT
                $cursorInsideCapture = $false
                if ([DesktopFrameNative]::GetPhysicalCursorPos([ref]$cursorPoint)) {
                    $cursorInsideCapture = $currentBounds.Contains([int]$cursorPoint.X,[int]$cursorPoint.Y)
                    $cursorTraceRows.Add(([pscustomobject]@{
                        timestamp=(Get-Date).ToString('o');frame=[int]$frame;x=[int]$cursorPoint.X;y=[int]$cursorPoint.Y
                        insideCapture=[bool]$cursorInsideCapture;captureLeft=[int]$currentBounds.Left;captureTop=[int]$currentBounds.Top
                    } | ConvertTo-Json -Compress))
                }
                if ($cursorInsideCapture) {
                    $cursorX = $drawX + [int][Math]::Round(([int]$cursorPoint.X-$currentBounds.Left)*$scale)
                    $cursorY = $drawY + [int][Math]::Round(([int]$cursorPoint.Y-$currentBounds.Top)*$scale)
                    $outerPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 5
                    $innerPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Yellow), 2
                    try {
                        $outputGraphics.DrawEllipse($outerPen,$cursorX-10,$cursorY-10,20,20)
                        $outputGraphics.DrawEllipse($innerPen,$cursorX-10,$cursorY-10,20,20)
                        $outputGraphics.DrawLine($outerPen,$cursorX-14,$cursorY,$cursorX+14,$cursorY)
                        $outputGraphics.DrawLine($outerPen,$cursorX,$cursorY-14,$cursorX,$cursorY+14)
                        $outputGraphics.DrawLine($innerPen,$cursorX-14,$cursorY,$cursorX+14,$cursorY)
                        $outputGraphics.DrawLine($innerPen,$cursorX,$cursorY-14,$cursorX,$cursorY+14)
                    } finally {
                        $innerPen.Dispose()
                        $outerPen.Dispose()
                    }
                    $cursorFrames++
                }
            }

            $file = Join-Path $OutDir ("frame_{0:D6}.png" -f $frame)
            $outputBitmap.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
            if ($null -ne $lastGoodFrame) { $lastGoodFrame.Dispose() }
            $lastGoodFrame = $outputBitmap.Clone()
            $frame++
        } catch {
            if ($null -ne $lastGoodFrame) {
                $file = Join-Path $OutDir ("frame_{0:D6}.png" -f $frame)
                $lastGoodFrame.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
                $frame++
                $repeated++
                Add-Content -LiteralPath $errorLog -Value ((Get-Date).ToString("o") + " repeated last full frame: " + $_.Exception.Message)
            } else {
                $skipped++
                Add-Content -LiteralPath $errorLog -Value ((Get-Date).ToString("o") + " skipped frame: " + $_.Exception.Message)
            }
        } finally {
            if ($null -ne $outputGraphics) { $outputGraphics.Dispose() }
            if ($null -ne $outputBitmap) { $outputBitmap.Dispose() }
            if ($null -ne $sourceGraphics) { $sourceGraphics.Dispose() }
            if ($null -ne $sourceBitmap) { $sourceBitmap.Dispose() }
        }
        $attempt++
        $remaining = $intervalMs - [int]$loopStart.ElapsedMilliseconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
    }

    if ($null -ne $lastGoodFrame) { $lastGoodFrame.Dispose() }
    if ($frame -eq 0) { throw "No video frames were captured." }
    if ($cursorTraceRows.Count -gt 0) {
        [IO.File]::WriteAllLines($cursorTracePath,$cursorTraceRows.ToArray(),[Text.UTF8Encoding]::new($false))
    }

    # PNG 연속 프레임을 MP4로 인코딩하고 별도 검사 도구가 읽을 수 있는 메타데이터를 남긴다.
    $encodeOutput = & python $encoder --frames-dir $OutDir --out $VideoOut --fps $Fps 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Video encoding failed: $encodeOutput" }

    [pscustomobject]@{
        status = "DONE"
        video = $VideoOut
        framesDir = $OutDir
        frames = $frame
        attemptedFrames = $attempt
        skippedFrames = $skipped
        repeatedFrames = $repeated
        reacquiredWindows = $reacquired
        rescaledFrames = $rescaled
        copyFromScreenFrames = $copyFromScreenFrames
        printWindowFrames = $printWindowFrames
        cursorOverlay = [bool]$ShowCursor
        cursorFrames = $cursorFrames
        cursorTrace = $(if($cursorTraceRows.Count -gt 0){$cursorTracePath}else{''})
        cursorTraceRows = $cursorTraceRows.Count
        fps = $Fps
        durationSeconds = $DurationSeconds
        elapsedSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        startedAt = $recordingStartedAt.ToString("o")
        processDpiAware = [bool]$dpiAwarenessEnabled
        windowDpi = $windowDpi
        captureBounds = @{
            left = $initialWindowBounds.Left
            top = $initialWindowBounds.Top
            windowWidth = $initialWindowBounds.Width
            windowHeight = $initialWindowBounds.Height
            encodedWidth = $canvasWidth
            encodedHeight = $canvasHeight
            lastLeft = $lastWindowBounds.Left
            lastTop = $lastWindowBounds.Top
            lastWindowWidth = $lastWindowBounds.Width
            lastWindowHeight = $lastWindowBounds.Height
            windowClass = $WindowClass
            windowTitlePrefix = $WindowTitlePrefix
        }
        stoppedByMarker = [bool]($StopFile -and (Test-Path -LiteralPath $StopFile))
        finishedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $done -Encoding UTF8
} catch {
    $_.Exception.ToString() | Set-Content -LiteralPath $errorLog -Encoding UTF8
    [pscustomobject]@{
        status = "ERROR"
        video = $VideoOut
        error = $_.Exception.Message
        finishedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $done -Encoding UTF8
    exit 1
}
