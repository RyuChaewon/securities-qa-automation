<#
.SYNOPSIS FlaUI 브리지 프로세스와 HTS 메인 창 세션의 수명을 관리한다.
.DESCRIPTION 명시적 context와 주입된 읽기/대기/프로세스 의존성만 사용하며 판정과 리포트를 생성하지 않는다.
#>

function New-HtsSessionContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FlaUiAssembly,
        [string]$TargetWindowClassName = '',
        [string]$TargetWindowTitlePrefix = '',
        [string]$DisplayName = 'HTS',
        [Parameter(Mandatory = $true)]
        [scriptblock]$GetTopWindows,
        [scriptblock]$Sleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
        [scriptblock]$GetNow = { Get-Date },
        [scriptblock]$ResolveDotNet = { (Get-Command dotnet -ErrorAction Stop).Source },
        [scriptblock]$ProcessFactory = {
            param([string]$DotNetPath, [string]$AssemblyPath)
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $DotNetPath
            $startInfo.Arguments = '"' + $AssemblyPath + '" --stdio'
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $process = New-Object Diagnostics.Process
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { throw 'FlaUI UIA3 실행기 프로세스를 시작하지 못했습니다.' }
            $process
        }
    )

    [pscustomobject]@{
        FlaUiAssembly = $FlaUiAssembly
        TargetWindowClassName = $TargetWindowClassName
        TargetWindowTitlePrefix = $TargetWindowTitlePrefix
        DisplayName = $DisplayName
        Bridge = $null
        MainWindow = $null
        Dependencies = [pscustomobject]@{
            GetTopWindows = $GetTopWindows
            Sleep = $Sleep
            GetNow = $GetNow
            ResolveDotNet = $ResolveDotNet
            ProcessFactory = $ProcessFactory
        }
    }
}

# Windows PowerShell 5.1의 리디렉션 인코딩 차이를 피하도록 비 ASCII 문자를 JSON \uXXXX로 바꾼다.
function ConvertTo-FlaUiAsciiJson($Request) {
    $json = ConvertTo-Json -InputObject $Request -Compress -Depth 12
    $builder = New-Object Text.StringBuilder
    foreach ($character in $json.ToCharArray()) {
        if ([int]$character -gt 127) { [void]$builder.AppendFormat('\u{0:X4}', [int]$character) }
        else { [void]$builder.Append($character) }
    }
    $builder.ToString()
}

function Invoke-FlaUiBridgeRequest {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Request
    )

    $process = $Context.Bridge
    if (-not $process -or $process.HasExited) {
        throw 'FlaUI UIA3 실행기가 실행 중이 아닙니다.'
    }
    $json = ConvertTo-FlaUiAsciiJson $Request
    $process.StandardInput.WriteLine($json)
    $process.StandardInput.Flush()
    $line = $process.StandardOutput.ReadLine()
    if ([string]::IsNullOrWhiteSpace($line)) {
        $errorText = if ($process.HasExited) { $process.StandardError.ReadToEnd() } else { '빈 응답' }
        throw "FlaUI UIA3 실행기가 응답을 반환하지 않았습니다: $errorText"
    }
    $response = $line | ConvertFrom-Json
    if ([string]$response.requestId -ne [string]$Request.requestId) {
        throw "FlaUI UIA3 요청/응답 식별자가 일치하지 않습니다: $($Request.requestId) / $($response.requestId)"
    }
    $response
}

function Stop-FlaUiBridge {
    param([Parameter(Mandatory = $true)]$Context)

    $process = $Context.Bridge
    $Context.Bridge = $null
    if (-not $process) { return }
    try { $process.StandardInput.Close() } catch { }
    try {
        if (-not $process.WaitForExit(2000)) { $process.Kill() }
    } catch { }
    try { $process.Dispose() } catch { }
}

function Start-FlaUiBridge {
    param([Parameter(Mandatory = $true)]$Context)

    if ($Context.Bridge -and -not $Context.Bridge.HasExited) { return $Context.Bridge }
    if (-not (Test-Path -LiteralPath $Context.FlaUiAssembly -PathType Leaf)) {
        throw "FlaUI UIA3 실행기 빌드 결과를 찾을 수 없습니다: $($Context.FlaUiAssembly). 먼저 dotnet build HtsQaPoc.sln -c Release를 실행하세요."
    }

    $dotnetPath = & $Context.Dependencies.ResolveDotNet
    $process = & $Context.Dependencies.ProcessFactory $dotnetPath $Context.FlaUiAssembly
    $Context.Bridge = $process

    $ping = Invoke-FlaUiBridgeRequest -Context $Context -Request ([ordered]@{
        requestId = [Guid]::NewGuid().ToString('N')
        operation = 'ping'
        rootHwnd = 0
    })
    if (-not $ping.success -or [string]$ping.engine -ne 'FlaUI.UIA3') {
        $errorText = if ($process.HasExited) { $process.StandardError.ReadToEnd() } else { [string]$ping.message }
        Stop-FlaUiBridge -Context $Context
        throw "FlaUI UIA3 실행기 ping에 실패했습니다: $errorText"
    }
    $process
}

function Find-HtsMainWindow {
    param([Parameter(Mandatory = $true)]$Context)

    $main = @(& $Context.Dependencies.GetTopWindows) | Where-Object {
        $classMatches = (-not $Context.TargetWindowClassName) -or $_.className -eq $Context.TargetWindowClassName
        $titleMatches = (-not $Context.TargetWindowTitlePrefix) -or $_.rawTitle.StartsWith($Context.TargetWindowTitlePrefix)
        $_.visible -and $classMatches -and $titleMatches
    } | Sort-Object hwnd -Descending | Select-Object -First 1
    if (-not $main) {
        throw "표시 중인 $($Context.DisplayName) 메인 창을 찾을 수 없습니다. 대상과 같은 권한 수준에서 이 스크립트를 실행하세요."
    }
    $Context.MainWindow = $main
    $main
}

function Wait-HtsMainWindow {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [int]$TimeoutMs = 45000
    )

    $deadline = (& $Context.Dependencies.GetNow).AddMilliseconds($TimeoutMs)
    $lastMessage = ''
    while ((& $Context.Dependencies.GetNow) -lt $deadline) {
        try {
            $candidate = Find-HtsMainWindow -Context $Context
            if ($candidate -and -not $candidate.hung) { return $candidate }
        } catch {
            $lastMessage = $_.Exception.Message
        }
        & $Context.Dependencies.Sleep 500
    }
    throw "HTS 메인 창이 제한 시간 안에 복구되지 않았습니다. $lastMessage"
}

# Native window snapshot helpers used by Session dependencies.
function Get-WindowInfo([IntPtr]$Hwnd) {
    [uint32]$windowPid = 0
    [void][TargetRuleNative]::GetWindowThreadProcessId($Hwnd, [ref]$windowPid)
    $title = New-Object Text.StringBuilder 1024
    $class = New-Object Text.StringBuilder 512
    [void][TargetRuleNative]::GetWindowText($Hwnd, $title, $title.Capacity)
    [void][TargetRuleNative]::GetClassName($Hwnd, $class, $class.Capacity)
    $rect = New-Object TargetRuleNative+RECT
    [void][TargetRuleNative]::GetWindowRect($Hwnd, [ref]$rect)
    [pscustomobject]@{
        hwnd = $Hwnd.ToInt64()
        parent = ([TargetRuleNative]::GetParent($Hwnd)).ToInt64()
        owner = ([TargetRuleNative]::GetWindow($Hwnd, 4)).ToInt64()
        pid = [int]$windowPid
        visible = [TargetRuleNative]::IsWindowVisible($Hwnd)
        enabled = [TargetRuleNative]::IsWindowEnabled($Hwnd)
        hung = [TargetRuleNative]::IsHungAppWindow($Hwnd)
        className = $class.ToString()
        rawTitle = $title.ToString()
        style = [TargetRuleNative]::GetStyle($Hwnd)
        rect = [pscustomobject]@{
            left = $rect.Left; top = $rect.Top; right = $rect.Right; bottom = $rect.Bottom
            width = $rect.Right - $rect.Left; height = $rect.Bottom - $rect.Top
        }
    }
}

function Get-TopWindows {
    $rows = New-Object Collections.Generic.List[object]
    [void][TargetRuleNative]::EnumWindows({ param($h, $l) $rows.Add((Get-WindowInfo $h)); return $true }, [IntPtr]::Zero)
    $rows
}

function Get-ChildWindows([Int64]$ParentHwnd) {
    $rows = New-Object Collections.Generic.List[object]
    [void][TargetRuleNative]::EnumChildWindows([IntPtr]$ParentHwnd, { param($h, $l) $rows.Add((Get-WindowInfo $h)); return $true }, [IntPtr]::Zero)
    for ($index=0; $index -lt $rows.Count; $index++) {
        $rows[$index] | Add-Member -NotePropertyName enumerationIndex -NotePropertyValue $index -Force
    }
    $rows
}
