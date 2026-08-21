<#
.SYNOPSIS HTS 업무 화면의 식별, 이동, 포커스와 화면 수명을 관리한다.
.DESCRIPTION 명시적 context와 UI/Win32 dependency adapter를 사용하며 판정과 리포트를 생성하지 않는다.
#>

function New-HtsNavigationContext {
    param(
        [Parameter(Mandatory = $true)]$SessionContext,
        [Parameter(Mandatory = $true)][regex]$TargetScreenTitleRegex,
        [int]$ScreenOpenTimeoutMs = 10000,
        [Parameter(Mandatory = $true)]$Dependencies
    )

    $requiredDependencies = @(
        'GetChildWindows', 'GetWindowInfo', 'IsWindow', 'ActivateMain', 'ActivateRequestedScreen',
        'SetInputSurface', 'SetScreenNumber', 'InvokeControlAction', 'TestInputAccess', 'ClickCenter',
        'SendEnter', 'FocusInputWindow', 'Sleep', 'GetNow', 'GetWindowProcessId', 'IsChild',
        'CloseWindow', 'ClearInputSurfaceForWindow')
    foreach ($name in $requiredDependencies) {
        if (-not ($Dependencies.PSObject.Properties.Name -contains $name) -or -not ($Dependencies.$name -is [scriptblock])) {
            throw "HTS navigation dependency '$name' is required."
        }
    }

    [pscustomobject]@{
        SessionContext = $SessionContext
        TargetScreenTitleRegex = $TargetScreenTitleRegex
        ScreenOpenTimeoutMs = $ScreenOpenTimeoutMs
        PreservedTargetScreenHwnds = @()
        Dependencies = $Dependencies
    }
}

# 이름으로 등록된 Navigation 의존성을 명시적 인수로 호출한다.
function Invoke-HtsNavigationDependency {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$ArgumentList = @()
    )
    $adapter = $Context.Dependencies.$Name
    & $adapter @ArgumentList
}

# 현재 탐색 세션에서 닫지 않을 화면 식별자 집합을 설정한다.
function Set-HtsNavigationPreservedScreens {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Int64[]]$Hwnds = @()
    )
    $Context.PreservedTargetScreenHwnds = @($Hwnds | Select-Object -Unique)
    $Context.PreservedTargetScreenHwnds
}

# 요청한 화면 번호와 일치하는 최상위 창을 찾는다.
function Find-HtsNavigationScreenWindow {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Main,
        [Parameter(Mandatory = $true)][string]$ScreenNumber
    )
    @(Invoke-HtsNavigationDependency -Context $Context -Name 'GetChildWindows' -ArgumentList @([Int64]$Main.hwnd)) | Where-Object {
        $_.visible -and $_.rawTitle -match ("^\[" + [regex]::Escape($ScreenNumber) + "\]")
    } | Sort-Object @{ Expression = { [int]$_.rect.width * [int]$_.rect.height }; Descending = $true } | Select-Object -First 1
}

# 창 메타데이터에서 화면 번호를 추출한다.
function Get-HtsNavigationScreenNumber {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Window
    )
    if ($Window) {
        $match = $Context.TargetScreenTitleRegex.Match([string]$Window.rawTitle)
        if ($match.Success) { return [string]$match.Groups['screen'].Value }
    }
    ''
}

# HTS 메인 창에 연결된 번호 화면 창 목록을 반환한다.
function Get-HtsNavigationScreenWindows {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Main
    )
    @(@(Invoke-HtsNavigationDependency -Context $Context -Name 'GetChildWindows' -ArgumentList @([Int64]$Main.hwnd)) | Where-Object {
        $_.visible -and $Context.TargetScreenTitleRegex.IsMatch([string]$_.rawTitle) -and
        $_.rect.width -ge 240 -and $_.rect.height -ge 120
    } | Sort-Object @{Expression={ [Int64]$_.rect.width * [Int64]$_.rect.height };Descending=$true})
}

# 발견한 창이 요청 화면과 일치하는지 확인한다.
function Test-HtsNavigationRequestedScreen {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Screen,
        [Parameter(Mandatory = $true)][string]$ScreenNumber
    )
    if (-not $Screen -or -not [bool](Invoke-HtsNavigationDependency -Context $Context -Name 'IsWindow' -ArgumentList @([Int64]$Screen.hwnd))) { return $false }
    $current = Invoke-HtsNavigationDependency -Context $Context -Name 'GetWindowInfo' -ArgumentList @([Int64]$Screen.hwnd)
    [bool]$current.visible -and (Get-HtsNavigationScreenNumber -Context $Context -Window $current) -eq $ScreenNumber
}

# 요청 화면 창을 전경으로 전환하고 접근 가능 여부를 반환한다.
function Focus-HtsNavigationRequestedScreen {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Main,
        $Screen,
        [Parameter(Mandatory = $true)][string]$ScreenNumber
    )
    if (-not (Test-HtsNavigationRequestedScreen -Context $Context -Screen $Screen -ScreenNumber $ScreenNumber)) { return $false }
    $Context.SessionContext.MainWindow = $Main
    Invoke-HtsNavigationDependency -Context $Context -Name 'ActivateRequestedScreen' -ArgumentList @($Main, $Screen) | Out-Null
    Invoke-HtsNavigationDependency -Context $Context -Name 'Sleep' -ArgumentList @(180) | Out-Null
    if (-not (Test-HtsNavigationRequestedScreen -Context $Context -Screen $Screen -ScreenNumber $ScreenNumber)) { return $false }
    $current = Invoke-HtsNavigationDependency -Context $Context -Name 'GetWindowInfo' -ArgumentList @([Int64]$Screen.hwnd)
    Invoke-HtsNavigationDependency -Context $Context -Name 'SetInputSurface' -ArgumentList @($current, 'Content', "[$ScreenNumber] 대상 화면") | Out-Null
    $true
}

# 화면 번호 입력 경로를 통해 요청 화면을 열고 결과 창을 반환한다.
function Open-HtsNavigationScreen {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Main,
        [Parameter(Mandatory = $true)]$ScreenEdit,
        [Parameter(Mandatory = $true)][string]$ScreenNumber
    )
    $Context.SessionContext.MainWindow = $Main
    Invoke-HtsNavigationDependency -Context $Context -Name 'SetInputSurface' -ArgumentList @($Main, 'Main', 'HTS 메인 화면번호 입력 영역') | Out-Null
    Invoke-HtsNavigationDependency -Context $Context -Name 'ActivateMain' -ArgumentList @($Main) | Out-Null
    Invoke-HtsNavigationDependency -Context $Context -Name 'SetScreenNumber' -ArgumentList @($ScreenEdit, $ScreenNumber) | Out-Null
    $currentEdit = Invoke-HtsNavigationDependency -Context $Context -Name 'GetWindowInfo' -ArgumentList @([Int64]$ScreenEdit.hwnd)
    $enterResult = Invoke-HtsNavigationDependency -Context $Context -Name 'InvokeControlAction' -ArgumentList @($currentEdit, 'pressKey', 'ENTER')
    if (-not ([bool]$enterResult.success -and [bool]$enterResult.verified)) {
        Invoke-HtsNavigationDependency -Context $Context -Name 'TestInputAccess' -ArgumentList @($currentEdit) | Out-Null
        Invoke-HtsNavigationDependency -Context $Context -Name 'ClickCenter' -ArgumentList @($currentEdit) | Out-Null
        Invoke-HtsNavigationDependency -Context $Context -Name 'SendEnter' | Out-Null
    }
    $openWaitMs = [Math]::Min(5000, [Math]::Max(1000, [int]$Context.ScreenOpenTimeoutMs / 2))
    Invoke-HtsNavigationDependency -Context $Context -Name 'Sleep' -ArgumentList @($openWaitMs) | Out-Null
    if (-not (Find-HtsNavigationScreenWindow -Context $Context -Main $Main -ScreenNumber $ScreenNumber)) {
        Invoke-HtsNavigationDependency -Context $Context -Name 'TestInputAccess' -ArgumentList @($currentEdit) | Out-Null
        Invoke-HtsNavigationDependency -Context $Context -Name 'FocusInputWindow' -ArgumentList @($currentEdit) | Out-Null
        Invoke-HtsNavigationDependency -Context $Context -Name 'SendEnter' | Out-Null
        Invoke-HtsNavigationDependency -Context $Context -Name 'Sleep' -ArgumentList @($openWaitMs) | Out-Null
    }
}

# 요청 화면과 연결된 보조 화면 창을 조회한다.
function Get-HtsNavigationLinkedScreens {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Main,
        [Parameter(Mandatory = $true)][string]$RequestedScreenNumber
    )
    @(Get-HtsNavigationScreenWindows -Context $Context -Main $Main | Where-Object {
        (Get-HtsNavigationScreenNumber -Context $Context -Window $_) -ne $RequestedScreenNumber -and
        $Context.PreservedTargetScreenHwnds -notcontains [Int64]$_.hwnd
    })
}

# 보존 대상이 아닌 요청 화면의 연결 창만 닫는다.
function Close-HtsNavigationLinkedScreens {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Main,
        [Parameter(Mandatory = $true)][string]$RequestedScreenNumber
    )
    $closed = 0
    foreach ($linked in @(Get-HtsNavigationLinkedScreens -Context $Context -Main $Main -RequestedScreenNumber $RequestedScreenNumber)) {
        if (Close-HtsNavigationScreen -Context $Context -Screen $linked) { $closed++; continue }
        if ([bool](Invoke-HtsNavigationDependency -Context $Context -Name 'IsWindow' -ArgumentList @([Int64]$linked.hwnd))) {
            Invoke-HtsNavigationDependency -Context $Context -Name 'Sleep' -ArgumentList @(250) | Out-Null
            if (Close-HtsNavigationScreen -Context $Context -Screen $linked) { $closed++ }
        }
    }
    $closed
}

# 창의 입력 가능 영역 특성으로 콘텐츠 표면 후보 점수를 계산한다.
function Get-HtsNavigationInputSurfaceScore {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Window
    )
    if (-not $Window -or -not [bool](Invoke-HtsNavigationDependency -Context $Context -Name 'IsWindow' -ArgumentList @([Int64]$Window.hwnd))) { return 0 }
    $current = Invoke-HtsNavigationDependency -Context $Context -Name 'GetWindowInfo' -ArgumentList @([Int64]$Window.hwnd)
    $children = @(Invoke-HtsNavigationDependency -Context $Context -Name 'GetChildWindows' -ArgumentList @([Int64]$current.hwnd) | Where-Object {
        $_.visible -and $_.enabled -and $_.rect.width -ge 8 -and $_.rect.height -ge 8
    })
    @($children | Where-Object {
        (([Int64]$_.style -band 0x00010000) -ne 0) -or
        $_.className -in @('Edit','ComboBox','ComboBoxEx32','SysTabControl32','ListBox') -or
        ($_.className -like 'AfxWnd*' -and $_.rawTitle -match '^\d{8,14}(-\d{3})?$') -or
        ($_.className -like 'AfxWnd*' -and ($_.rawTitle -match '조회|검색|확인|저장' -or $_.rect.height -le 40))
    }).Count
}

# 요청 화면과 새로 열린 창 중 가장 적합한 입력 표면을 선택한다.
function Find-HtsNavigationBestContentSurface {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Main,
        $RequestedWindow,
        [Parameter(Mandatory = $true)][string]$RequestedScreenNumber,
        [Int64[]]$BaselineScreenHwnds = @()
    )
    $requestedHwnd = if ($RequestedWindow) { [Int64]$RequestedWindow.hwnd } else { [Int64]0 }
    $candidates = @(Invoke-HtsNavigationDependency -Context $Context -Name 'GetChildWindows' -ArgumentList @([Int64]$Main.hwnd) | Where-Object {
        $_.visible -and $Context.TargetScreenTitleRegex.IsMatch([string]$_.rawTitle) -and
        $_.rect.width -ge 240 -and $_.rect.height -ge 120
    })
    if ($RequestedWindow -and @($candidates | Where-Object { $_.hwnd -eq $RequestedWindow.hwnd }).Count -eq 0) {
        $candidates = @($RequestedWindow) + $candidates
    }

    $exactCandidates = @($candidates | Where-Object {
        ($requestedHwnd -ne 0 -and $_.hwnd -eq $requestedHwnd) -or
        $_.rawTitle -match ("^\[" + [regex]::Escape($RequestedScreenNumber) + "\]")
    })
    $rankedExact = @($exactCandidates | ForEach-Object {
        [pscustomobject]@{
            window = $_
            score = Get-HtsNavigationInputSurfaceScore -Context $Context -Window $_
            area = [Int64]$_.rect.width * [Int64]$_.rect.height
        }
    } | Sort-Object score,area -Descending)
    if ($rankedExact.Count -gt 0) { return $rankedExact[0].window }

    $newCandidates = @($candidates | Where-Object { $BaselineScreenHwnds -notcontains [Int64]$_.hwnd })
    $rankedNew = @($newCandidates | ForEach-Object {
        [pscustomobject]@{
            window = $_
            score = Get-HtsNavigationInputSurfaceScore -Context $Context -Window $_
            area = [Int64]$_.rect.width * [Int64]$_.rect.height
        }
    } | Sort-Object score,area -Descending)
    if ($rankedNew.Count -gt 0 -and $rankedNew[0].score -gt 0) { return $rankedNew[0].window }
    $RequestedWindow
}

# 허용된 화면 창에 닫기 요청을 보내고 종료 여부를 확인한다.
function Close-HtsNavigationScreen {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Screen
    )
    if (-not $Screen -or -not [bool](Invoke-HtsNavigationDependency -Context $Context -Name 'IsWindow' -ArgumentList @([Int64]$Screen.hwnd))) { return $true }
    $main = $Context.SessionContext.MainWindow
    if (-not $main) { return $false }
    if ([Int64]$Screen.hwnd -eq [Int64]$main.hwnd) { return $false }
    $screenPid = [int](Invoke-HtsNavigationDependency -Context $Context -Name 'GetWindowProcessId' -ArgumentList @([Int64]$Screen.hwnd))
    if ($screenPid -ne [int]$main.pid -or -not [bool](Invoke-HtsNavigationDependency -Context $Context -Name 'IsChild' -ArgumentList @([Int64]$main.hwnd, [Int64]$Screen.hwnd))) { return $false }
    Invoke-HtsNavigationDependency -Context $Context -Name 'ClearInputSurfaceForWindow' -ArgumentList @($Screen) | Out-Null
    Invoke-HtsNavigationDependency -Context $Context -Name 'CloseWindow' -ArgumentList @($Screen) | Out-Null
    $deadline = (Invoke-HtsNavigationDependency -Context $Context -Name 'GetNow').AddSeconds(3)
    while ([bool](Invoke-HtsNavigationDependency -Context $Context -Name 'IsWindow' -ArgumentList @([Int64]$Screen.hwnd)) -and
        (Invoke-HtsNavigationDependency -Context $Context -Name 'GetNow') -lt $deadline) {
        Invoke-HtsNavigationDependency -Context $Context -Name 'Sleep' -ArgumentList @(100) | Out-Null
    }
    -not [bool](Invoke-HtsNavigationDependency -Context $Context -Name 'IsWindow' -ArgumentList @([Int64]$Screen.hwnd))
}

# 보존 정책을 지키며 기존 대상 화면 창을 정리한다.
function Close-HtsNavigationExistingTargetScreens {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Main
    )
    $closed = 0
    $targets = @(Invoke-HtsNavigationDependency -Context $Context -Name 'GetChildWindows' -ArgumentList @([Int64]$Main.hwnd) | Where-Object {
        $Context.TargetScreenTitleRegex.IsMatch([string]$_.rawTitle) -and
        $Context.PreservedTargetScreenHwnds -notcontains [Int64]$_.hwnd
    } | Sort-Object { [int]$_.rect.width * [int]$_.rect.height } -Descending)
    foreach ($target in $targets) {
        if (Close-HtsNavigationScreen -Context $Context -Screen $target) { $closed++ }
    }
    $closed
}

# 창이 현재 탐색 세션의 보존 화면인지 확인한다.
function Test-HtsNavigationPreservedTargetScreen {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Window
    )
    $Window -and $Context.PreservedTargetScreenHwnds -contains [Int64]$Window.hwnd
}

# 화면 검색 과정에서 열린 임시 overlay만 닫는다.
function Close-HtsNavigationSearchOverlays {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Main
    )
    $closed = 0
    foreach ($overlay in @(Invoke-HtsNavigationDependency -Context $Context -Name 'GetChildWindows' -ArgumentList @([Int64]$Main.hwnd) | Where-Object {
        $_.visible -and $_.rawTitle -eq '화면검색'
    })) {
        if (Close-HtsNavigationScreen -Context $Context -Screen $overlay) { $closed++ }
    }
    $closed
}

# Rule-suite navigation adapters with explicit contexts.
function Find-ScreenNumberEdit($RuntimeContext, $Main) {
    if ([int]$Main.rect.left -le -30000 -or [int]$Main.rect.top -le -30000) {
        [void][TargetRuleNative]::ShowWindow([IntPtr][Int64]$Main.hwnd, 9)
        [void][TargetRuleNative]::SetForegroundWindow([IntPtr][Int64]$Main.hwnd)
        Start-Sleep -Milliseconds 500
        $Main = Get-WindowInfo ([IntPtr][Int64]$Main.hwnd)
    }
    $edit = Get-ChildWindows ([Int64]$Main.hwnd) | Where-Object {
        $_.visible -and $_.enabled -and $_.className -eq "Edit" -and
        $_.rect.left -lt ($Main.rect.left + 250) -and $_.rect.top -lt ($Main.rect.top + 90) -and $_.rect.width -ge 35 -and $_.rect.width -le 180
    } | Sort-Object @{ Expression = { if ($RuntimeContext.TargetScreenIdRegex.IsMatch([string]$_.rawTitle)) { 0 } else { 1 } } }, { $_.rect.top }, { $_.rect.left } | Select-Object -First 1
    if (-not $edit) { throw "HTS 화면번호 입력칸을 찾을 수 없습니다." }
    $edit
}

# 화면 번호 입력 control이 실제로 입력 가능한 상태인지 확인한다.
function Test-HtsScreenNavigationInputAccess($ScreenEdit) {
    $targetHwnd = [IntPtr][Int64]$ScreenEdit.hwnd
    [IntPtr]$messageResult = [IntPtr]::Zero
    $completed = [TargetRuleNative]::SendMessageTimeout($targetHwnd, $WM_GETTEXTLENGTH, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 1200, [ref]$messageResult)
    $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($completed -eq [IntPtr]::Zero -and $nativeError -eq 5) {
        throw "HTS_UI_ACCESS_DENIED: 화면번호 입력부 HWND=$([Int64]$ScreenEdit.hwnd)에 대한 Win32 메시지가 Access denied(5)로 차단되었습니다. HTS와 같은 권한 수준에서 실행해야 합니다."
    }
    if ($completed -eq [IntPtr]::Zero) {
        throw "SCREEN_NAVIGATION_INPUT_UNAVAILABLE: 화면번호 입력부 HWND=$([Int64]$ScreenEdit.hwnd) 접근을 확인하지 못했습니다. win32Error=$nativeError"
    }
    [int]$messageResult.ToInt64()
}

# 화면 번호 입력 control에 요청 값을 설정한다.
function Set-HtsScreenNumber($ScreenEdit, [string]$ScreenNumber) {
    [void](Test-HtsScreenNavigationInputAccess $ScreenEdit)
    $uiaResult = Invoke-FlaUiControlAction $ScreenEdit 'setText' -Value $ScreenNumber
    Start-Sleep -Milliseconds 180
    $current = Get-WindowInfo ([IntPtr][Int64]$ScreenEdit.hwnd)
    if ([string]$current.rawTitle -eq $ScreenNumber) {
        Write-HtsInputBoundaryAudit 'ScreenNavigationText' 'ALLOWED' -1 -1 "engine=FlaUI.UIA3; value=$ScreenNumber; nativeTextVerified=True"
        return
    }

    [IntPtr]$messageResult = [IntPtr]::Zero
    $completed = [TargetRuleNative]::SendMessageTimeoutText([IntPtr][Int64]$ScreenEdit.hwnd, $WM_SETTEXT, [IntPtr]::Zero, $ScreenNumber, 0x0002, 1200, [ref]$messageResult)
    $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($completed -eq [IntPtr]::Zero -and $nativeError -eq 5) {
        throw "HTS_UI_ACCESS_DENIED: UIA 화면번호 입력 결과를 네이티브로 확인하지 못했고 WM_SETTEXT도 Access denied(5)로 차단되었습니다. HTS와 같은 권한 수준에서 실행해야 합니다."
    }
    $current = Get-WindowInfo ([IntPtr][Int64]$ScreenEdit.hwnd)
    if ([string]$current.rawTitle -eq $ScreenNumber) {
        Write-HtsInputBoundaryAudit 'ScreenNavigationText' 'ALLOWED' -1 -1 "engine=Win32; value=$ScreenNumber; nativeTextVerified=True"
        return
    }
    if ([bool]$uiaResult.success -and [bool]$uiaResult.verified) {
        # 이 입력부는 값을 owner-drawn 래퍼에 그려 native window text가 비어 있을 수 있다.
        # 값 입력은 UIA 패턴으로 확인하고, 뒤이어 업무 화면 생성으로 종단 간 검증한다.
        Write-HtsInputBoundaryAudit 'ScreenNavigationText' 'ALLOWED' -1 -1 "engine=FlaUI.UIA3; value=$ScreenNumber; nativeTextVerified=False; ownerDrawn=True; screenCreationPending=True"
        return
    }
    if ($completed -ne [IntPtr]::Zero) {
        Write-HtsInputBoundaryAudit 'ScreenNavigationText' 'ALLOWED' -1 -1 "engine=Win32; value=$ScreenNumber; nativeTextVerified=False; ownerDrawn=True; screenCreationPending=True"
        return
    }
    $uiaDetail = "success=$([bool]$uiaResult.success), verified=$([bool]$uiaResult.verified)"
    throw "SCREEN_NAVIGATION_TEXT_UNVERIFIED: 화면번호 '$ScreenNumber' 입력을 확인하지 못했습니다. $uiaDetail; nativeText='$([string]$current.rawTitle)'; win32Error=$nativeError"
}

# 기존 호출 계약을 유지하며 화면 열기를 Navigation 구현에 위임한다.
function Open-HtsScreen($NavigationContext, $Main, $ScreenEdit, [string]$ScreenNumber) {
    Open-HtsNavigationScreen -Context $navigationContext -Main $Main -ScreenEdit $ScreenEdit -ScreenNumber $ScreenNumber
}

# 기존 호출 계약을 유지하며 화면 창 찾기를 Navigation 구현에 위임한다.
function Find-ScreenWindow($NavigationContext, $Main, [string]$ScreenNumber) {
    Find-HtsNavigationScreenWindow -Context $navigationContext -Main $Main -ScreenNumber $ScreenNumber
}

# 기존 호출 계약을 유지하며 화면 번호 추출을 Navigation 구현에 위임한다.
function Get-HtsScreenNumber($NavigationContext, $Window) {
    Get-HtsNavigationScreenNumber -Context $navigationContext -Window $Window
}

# 기존 호출 계약을 유지하며 화면 창 조회를 Navigation 구현에 위임한다.
function Get-HtsScreenWindows($NavigationContext, $Main) {
    @(Get-HtsNavigationScreenWindows -Context $navigationContext -Main $Main)
}

# 기존 호출 계약을 유지하며 요청 화면 검증을 Navigation 구현에 위임한다.
function Test-HtsRequestedScreen($NavigationContext, $Screen, [string]$ScreenNumber) {
    Test-HtsNavigationRequestedScreen -Context $navigationContext -Screen $Screen -ScreenNumber $ScreenNumber
}

# 기존 호출 계약을 유지하며 요청 화면 포커스를 Navigation 구현에 위임한다.
function Focus-HtsRequestedScreen($NavigationContext, $Main, $Screen, [string]$ScreenNumber) {
    Focus-HtsNavigationRequestedScreen -Context $navigationContext -Main $Main -Screen $Screen -ScreenNumber $ScreenNumber
}

# 기존 호출 계약을 유지하며 연결 화면 조회를 Navigation 구현에 위임한다.
function Get-HtsLinkedScreens($NavigationContext, $Main, [string]$RequestedScreenNumber) {
    @(Get-HtsNavigationLinkedScreens -Context $navigationContext -Main $Main -RequestedScreenNumber $RequestedScreenNumber)
}

# 기존 호출 계약을 유지하며 연결 화면 닫기를 Navigation 구현에 위임한다.
function Close-HtsLinkedScreens($NavigationContext, $Main, [string]$RequestedScreenNumber) {
    Close-HtsNavigationLinkedScreens -Context $navigationContext -Main $Main -RequestedScreenNumber $RequestedScreenNumber
}

# 기존 호출 계약을 유지하며 입력 표면 점수 계산을 Navigation 구현에 위임한다.
function Get-HtsInputSurfaceScore($NavigationContext, $Window) {
    Get-HtsNavigationInputSurfaceScore -Context $navigationContext -Window $Window
}

# 기존 호출 계약을 유지하며 최적 콘텐츠 표면 선택을 Navigation 구현에 위임한다.
function Find-BestHtsContentSurface($NavigationContext, $Main, $RequestedWindow, [string]$RequestedScreenNumber, [Int64[]]$BaselineScreenHwnds = @()) {
    Find-HtsNavigationBestContentSurface -Context $navigationContext -Main $Main -RequestedWindow $RequestedWindow -RequestedScreenNumber $RequestedScreenNumber -BaselineScreenHwnds $BaselineScreenHwnds
}

# 기존 호출 계약을 유지하며 화면 닫기를 Navigation 구현에 위임한다.
function Close-HtsScreen($NavigationContext, $Screen) {
    Close-HtsNavigationScreen -Context $navigationContext -Screen $Screen
}

# 기존 호출 계약을 유지하며 기존 대상 화면 정리를 Navigation 구현에 위임한다.
function Close-ExistingTargetScreens($NavigationContext, $Main) {
    Close-HtsNavigationExistingTargetScreens -Context $navigationContext -Main $Main
}

# 기존 호출 계약을 유지하며 보존 화면 여부 확인을 Navigation 구현에 위임한다.
function Test-PreservedTargetScreen($NavigationContext, $Window) {
    Test-HtsNavigationPreservedTargetScreen -Context $navigationContext -Window $Window
}

# 기존 호출 계약을 유지하며 검색 overlay 정리를 Navigation 구현에 위임한다.
function Close-ScreenSearchOverlays($NavigationContext, $Main) {
    Close-HtsNavigationSearchOverlays -Context $navigationContext -Main $Main
}
