<# .SYNOPSIS Regression tests for the explicit HTS session context. #>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\modules\hts-session.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT_TRUE failed: $Message" }
    $script:assertions++
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) {
        throw "ASSERT_EQUAL failed: $Message. expected='$Expected' actual='$Actual'"
    }
    $script:assertions++
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    try {
        & $Action
        throw "ASSERT_THROWS failed: $Message"
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
    }
    $script:assertions++
}

function New-FakeBridgeProcess([string]$ResponseLine) {
    $input = [pscustomobject]@{
        Lines = New-Object Collections.Generic.List[string]
        Closed = $false
    }
    $input | Add-Member ScriptMethod WriteLine { param([string]$Line) $this.Lines.Add($Line) }
    $input | Add-Member ScriptMethod Flush { }
    $input | Add-Member ScriptMethod Close { $this.Closed = $true }

    $output = [pscustomobject]@{ Lines = New-Object Collections.Generic.Queue[string] }
    if ($ResponseLine) { $output.Lines.Enqueue($ResponseLine) }
    $output | Add-Member ScriptMethod ReadLine {
        if ($this.Lines.Count -eq 0) { return $null }
        $this.Lines.Dequeue()
    }

    $errorOutput = [pscustomobject]@{ Text = '' }
    $errorOutput | Add-Member ScriptMethod ReadToEnd { $this.Text }

    $process = [pscustomobject]@{
        HasExited = $false
        StandardInput = $input
        StandardOutput = $output
        StandardError = $errorOutput
        Killed = $false
        Disposed = $false
    }
    $process | Add-Member ScriptMethod WaitForExit { param([int]$Milliseconds) $true }
    $process | Add-Member ScriptMethod Kill { $this.Killed = $true; $this.HasExited = $true }
    $process | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    $process
}

$script:assertions = 0
$script:topWindows = @(
    [pscustomobject]@{hwnd=3;visible=$true;className='Main';rawTitle='Target A';hung=$false},
    [pscustomobject]@{hwnd=8;visible=$true;className='Main';rawTitle='Target B';hung=$false},
    [pscustomobject]@{hwnd=9;visible=$false;className='Main';rawTitle='Target C';hung=$false})
$context = New-HtsSessionContext `
    -FlaUiAssembly 'unused' `
    -TargetWindowClassName 'Main' `
    -TargetWindowTitlePrefix 'Target' `
    -DisplayName 'Target HTS' `
    -GetTopWindows { @($script:topWindows) }

$ascii = ConvertTo-FlaUiAsciiJson ([ordered]@{requestId='x';text='한'})
Assert-Equal '{"requestId":"x","text":"\uD55C"}' $ascii 'ASCII JSON contract'
Assert-True (-not $ascii.Contains('한')) 'ASCII JSON excludes raw non-ASCII text'

$main = Find-HtsMainWindow -Context $context
Assert-Equal 8 $main.hwnd 'main window ranking'
Assert-Equal 8 $context.MainWindow.hwnd 'main window retained on context'
Assert-Equal 8 (Wait-HtsMainWindow -Context $context -TimeoutMs 100).hwnd 'wait returns available main window'

$request = [ordered]@{requestId='same-id';operation='ping';rootHwnd=0}
$process = New-FakeBridgeProcess '{"requestId":"same-id","success":true,"engine":"FlaUI.UIA3"}'
$context.Bridge = $process
$response = Invoke-FlaUiBridgeRequest -Context $context -Request $request
Assert-True ([bool]$response.success) 'bridge response success preserved'
Assert-Equal 1 $process.StandardInput.Lines.Count 'one request line written'
Assert-Equal $process (Start-FlaUiBridge -Context $context) 'start is idempotent for a running bridge'

Stop-FlaUiBridge -Context $context
Assert-True ($null -eq $context.Bridge) 'stop clears context bridge reference'
Assert-True ($process.StandardInput.Closed) 'stop closes bridge input'
Assert-True ($process.Disposed) 'stop disposes bridge process'

$emptyContext = New-HtsSessionContext -FlaUiAssembly 'unused' -GetTopWindows { @() }
Assert-Throws { Invoke-FlaUiBridgeRequest -Context $emptyContext -Request $request } '실행 중이 아닙니다' 'request requires a running bridge'

$sessionSource = Get-Content -LiteralPath (Join-Path $root 'scripts\modules\hts-session.ps1') -Raw -Encoding UTF8
Assert-True ($sessionSource -notmatch '\$script:') 'session module has no script-scoped mutable state'
Assert-True ($sessionSource -notmatch 'ResultEvaluator|TestResult|Set-Content|Add-Content|Export-Rule') 'session module has no evaluation or reporting logic'

Write-Output "HTS_SESSION_TESTS=PASS assertions=$script:assertions"
