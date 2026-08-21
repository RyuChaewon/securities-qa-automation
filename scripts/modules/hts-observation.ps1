<#
.SYNOPSIS HTS 메시지와 대화상자 신호를 원시 Observation 계약으로 정규화한다.
.DESCRIPTION Observation은 증거와 기대 계약을 연결하지만 최종 PASS, FAIL, ERROR 또는 PENDING 판정을 수행하지 않는다.
#>

function New-HtsObservationContext {
    param(
        $MapCatalog,
        [string]$InstallationRoot = '',
        [Parameter(Mandatory = $true)]$Dependencies
    )

    [pscustomobject]@{
        MapCatalog = $MapCatalog
        InstallationRoot = $InstallationRoot
        Dependencies = $Dependencies
        ResultEvaluationSequence = 0
        CurrentResultEvaluationCases = New-Object Collections.Generic.List[object]
        CurrentSignalEvaluationGroups = @{}
        CurrentRequiredExpectations = New-Object Collections.Generic.List[object]
    }
}

function Get-HtsObservationTopWindows {
    param([Parameter(Mandatory = $true)]$Context)
    @(Invoke-HtsObservationDependency -Context $Context -Name 'GetTopWindows')
}

function Get-HtsObservationChildWindows {
    param([Parameter(Mandatory = $true)]$Context, [Int64]$Hwnd)
    @(Invoke-HtsObservationDependency -Context $Context -Name 'GetChildWindows' -Arguments @($Hwnd))
}

function Get-HtsObservationWindowInfo {
    param([Parameter(Mandatory = $true)]$Context, [Int64]$Hwnd)
    Invoke-HtsObservationDependency -Context $Context -Name 'GetWindowInfo' -Arguments @($Hwnd)
}

function Get-HtsObservationScreenNumber {
    param([Parameter(Mandatory = $true)]$Context, $Window)
    Invoke-HtsObservationDependency -Context $Context -Name 'GetScreenNumber' -Arguments @($Window)
}

function Protect-HtsObservationText {
    param([Parameter(Mandatory = $true)]$Context, $Text, [string]$Secret = '')
    Invoke-HtsObservationDependency -Context $Context -Name 'ProtectText' -Arguments @($Text,$Secret)
}

function Get-HtsObservationRelativePath {
    param([Parameter(Mandatory = $true)]$Context, [string]$BasePath, [string]$Path)
    Invoke-HtsObservationDependency -Context $Context -Name 'GetRelativeFilePath' -Arguments @($BasePath,$Path)
}

function Get-HtsObservationNow {
    param([Parameter(Mandatory = $true)]$Context)
    Invoke-HtsObservationDependency -Context $Context -Name 'GetNow'
}

function Reset-HtsObservationCaseContext {
    param(
        [Parameter(Mandatory = $true)]$Context,
        $ResultEvaluationCases = $null,
        $SignalEvaluationGroups = $null,
        $RequiredExpectations = $null
    )

    if ($null -ne $ResultEvaluationCases) { $Context.CurrentResultEvaluationCases = $ResultEvaluationCases }
    else { $Context.CurrentResultEvaluationCases = New-Object Collections.Generic.List[object] }
    if ($null -ne $SignalEvaluationGroups) { $Context.CurrentSignalEvaluationGroups = $SignalEvaluationGroups }
    else { $Context.CurrentSignalEvaluationGroups = @{} }
    if ($null -ne $RequiredExpectations) { $Context.CurrentRequiredExpectations = $RequiredExpectations }
    else { $Context.CurrentRequiredExpectations = New-Object Collections.Generic.List[object] }
    $Context
}

function Invoke-HtsObservationDependency {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$Arguments = @()
    )

    if (-not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)) {
        throw "HTS observation dependency가 없습니다: $Name"
    }
    $dependency = $Context.Dependencies.$Name
    if (-not ($dependency -is [scriptblock])) { throw "HTS observation dependency는 scriptblock이어야 합니다: $Name" }
    & $dependency @Arguments
}

function Get-HtsNextObservationSequence {
    param([Parameter(Mandatory = $true)]$Context)
    $Context.ResultEvaluationSequence++
    [int]$Context.ResultEvaluationSequence
}

function Get-HtsMapOracleMessageMatch {
    param([string]$Text, $MapOracle)

    if (-not $MapOracle -or [string]::IsNullOrWhiteSpace($Text)) { return $null }
    $rank = @{Error=0;InputValidation=1;Warning=2;Info=3}
    $matches = @($MapOracle.messageBoxes | Where-Object {
        $message=[string]$_.message;$title=[string]$_.title
        ($message -and $Text.IndexOf($message,[StringComparison]::OrdinalIgnoreCase) -ge 0) -or
        ($title -and $Text.IndexOf($title,[StringComparison]::OrdinalIgnoreCase) -ge 0)
    } | Sort-Object @{Expression={if($rank.ContainsKey([string]$_.classification)){$rank[[string]$_.classification]}else{9}}},ruleId)
    if ($matches.Count -gt 0) { return $matches[0] }
    $null
}

function Get-HtsInstallationErrorCodeMatch {
    param([Parameter(Mandatory = $true)]$Context, [string]$Text)

    if (-not $Context.MapCatalog -or -not $Context.MapCatalog.errorCodes -or [string]::IsNullOrWhiteSpace($Text)) { return $null }
    $matches = @($Context.MapCatalog.errorCodes | Where-Object {
        $code=[string]$_.code;$message=[string]$_.message
        ($code -and $Text -match "(?<![0-9])$([regex]::Escape($code))(?![0-9])") -or
        ($message.Length -ge 6 -and $Text.IndexOf($message,[StringComparison]::OrdinalIgnoreCase) -ge 0)
    } | Sort-Object @{Expression={if([bool]$_.isFailure){0}else{1}}},code)
    if ($matches.Count -gt 0) { return $matches[0] }
    $null
}

function Get-HtsExpectedOutcome {
    param($Option, $FallbackPatterns = @())

    $source = if ($Option -and $Option.expectedOutcome) { $Option.expectedOutcome } else { $null }
    $type = if ($source -and $source.type) { [string]$source.type } elseif(@($FallbackPatterns).Count -gt 0) { 'ValidationAllowed' } else { 'Unspecified' }
    $expectationSource = if($source -and $source.source -and [string]$source.source -ne 'Unspecified') {[string]$source.source} elseif($source -and $type -ne 'Unspecified') {'Dataset'} elseif(@($FallbackPatterns).Count -gt 0) {'ScreenExpectedPattern'} else {'Unspecified'}
    $confidence = if($source -and $source.confidence -and [string]$source.confidence -ne 'Unspecified') {[string]$source.confidence} elseif($source -and $type -ne 'Unspecified') {'High'} elseif(@($FallbackPatterns).Count -gt 0) {'Medium'} else {'Unspecified'}
    $patterns = New-Object Collections.Generic.List[string]
    foreach($pattern in @($FallbackPatterns) + @($(if($source){$source.messagePatterns}else{@()}))){
        if(-not [string]::IsNullOrWhiteSpace([string]$pattern) -and -not $patterns.Contains([string]$pattern)){$patterns.Add([string]$pattern)}
    }
    $evidence = New-Object Collections.Generic.List[string]
    foreach($item in @($(if($source){$source.evidence}else{@()}))){
        if(-not [string]::IsNullOrWhiteSpace([string]$item) -and -not $evidence.Contains([string]$item)){$evidence.Add([string]$item)}
    }
    if(@($FallbackPatterns).Count -gt 0 -and $evidence.Count -eq 0){$evidence.Add('화면 데이터셋 expectedPopupPatterns')}
    [pscustomobject]@{
        type=$type;source=$expectationSource;confidence=$confidence;evidence=$evidence.ToArray();messagePatterns=$patterns.ToArray()
        errorCodes=@($(if($source){$source.errorCodes}else{@()}));queryShouldComplete=$(if($source){$source.queryShouldComplete}else{$null})
        expectationId=$(if($Option){[string]$Option.id}else{'screen-default'})
    }
}

function Test-HtsSystemFailureSignal {
    param([string]$Text)
    $Text -match '시스템\s*오류|처리\s*오류가?\s*발생|서버\s*(오류|장애|접속)|통신\s*(오류|장애|실패)|소켓|Socket|Exception|예외|프로그램\s*(오류|종료)|강제\s*종료|응답\s*(없음|하지)|세션\s*만료|자동\s*로그아웃'
}

function Test-HtsInputValidationSignal {
    param([string]$Text)
    $Text -match '종목\s*코드\s*오류|계좌번호를?\s*확인|비밀번호를?\s*확인|하나를\s*선택해\s*주세요|입력해\s*주세요|선택해\s*주세요|조회가\s*불가|시작일자가\s*종료일자보다'
}

function New-HtsSignalObservation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$Text,
        $MapOracle,
        $ExpectedOutcome,
        [regex]$ErrorRegex,
        [string]$FallbackClassification = ''
    )

    $installedMatch = Get-HtsInstallationErrorCodeMatch -Context $Context -Text $Text
    $mapMatch = Get-HtsMapOracleMessageMatch -Text $Text -MapOracle $MapOracle
    $source='공통 규칙';$code='';$eventType='Info'
    if($installedMatch){
        $source='HTS 오류코드';$code=[string]$installedMatch.code
        switch([string]$installedMatch.classification){
            'Authentication'{$eventType='ProductFailure'};'TransientFailure'{$eventType='ProductFailure'};'SystemFailure'{$eventType='ProductFailure'}
            'NoData'{$eventType='NoData'};'Normal'{$eventType='Success'};default{$eventType='InputValidation'}
        }
    }elseif($mapMatch){
        $source='MAP';$code=[string]$mapMatch.ruleId
        switch([string]$mapMatch.classification){'Error'{$eventType='ProductFailure'};'InputValidation'{$eventType='InputValidation'};'Warning'{$eventType='Warning'};default{$eventType='Info'}}
    }elseif(Test-HtsSystemFailureSignal $Text){$eventType='ProductFailure'
    }elseif(Test-HtsInputValidationSignal $Text){$eventType='InputValidation'
    }elseif($FallbackClassification -eq '경고'){$eventType='Warning'
    }elseif($FallbackClassification -eq '정보'){$eventType='Info'
    }elseif(($ErrorRegex -and $Text -match $ErrorRegex) -or $FallbackClassification -eq '오류'){$eventType='GenericError'}

    $type=if($ExpectedOutcome){[string]$ExpectedOutcome.type}else{'Unspecified'}
    $sequence = Get-HtsNextObservationSequence -Context $Context
    $evaluationCase = Invoke-HtsObservationDependency -Context $Context -Name 'CreateSignalEvaluationCase' -Arguments @(
        ("signal-{0:D6}" -f $sequence),$eventType,$Text,$code,$source,$ExpectedOutcome
    )
    [pscustomobject]@{
        eventType=$eventType;disposition='Observed';expectedOutcomeType=$type
        expectedOutcomeSource=$(if($ExpectedOutcome){[string]$ExpectedOutcome.source}else{'Unspecified'})
        expectedOutcomeConfidence=$(if($ExpectedOutcome){[string]$ExpectedOutcome.confidence}else{'Unspecified'})
        expectedOutcomeEvidence=@($(if($ExpectedOutcome){$ExpectedOutcome.evidence}else{@()}))
        expectationId=$(if($ExpectedOutcome){[string]$ExpectedOutcome.expectationId}else{''})
        source=$source;code=$code;text=$Text;evaluationCase=$evaluationCase
    }
}

function New-HtsDialogObservation {
    param([Parameter(Mandatory = $true)]$Context,$Dialog,$MapOracle,$ExpectedOutcome,[regex]$ErrorRegex)
    New-HtsSignalObservation -Context $Context -Text ([string]$Dialog.text) -MapOracle $MapOracle -ExpectedOutcome $ExpectedOutcome -ErrorRegex $ErrorRegex -FallbackClassification ([string]$Dialog.classification)
}

function Add-HtsOracleObservation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$List,
        $Observation,
        [string]$Stage,
        [string]$ControlId = '',
        [string]$OptionId = ''
    )

    if(-not $Observation){return}
    $key="$Stage|$ControlId|$OptionId|$([string]$Observation.eventType)|$([string]$Observation.text)"
    if(@($List | Where-Object eventKey -eq $key).Count -gt 0){return}
    $now = Invoke-HtsObservationDependency -Context $Context -Name 'GetNow'
    $List.Add([pscustomobject]@{
        eventKey=$key;stage=$Stage;controlId=$ControlId;optionId=$OptionId;eventType=[string]$Observation.eventType
        disposition='Observed';expectedOutcomeType=[string]$Observation.expectedOutcomeType;expectedOutcomeSource=[string]$Observation.expectedOutcomeSource
        expectedOutcomeConfidence=[string]$Observation.expectedOutcomeConfidence;expectedOutcomeEvidence=@($Observation.expectedOutcomeEvidence)
        expectationId=[string]$Observation.expectationId;source=[string]$Observation.source;sourceCode=[string]$Observation.code
        message=[string]$Observation.text;detectedAt=$now.ToString('o')
    })
    if ($Observation.evaluationCase) {
        foreach($required in @($Context.CurrentRequiredExpectations.ToArray())){
            $sameControl=-not $ControlId -or [string]$required.controlId -eq $ControlId
            $sameOption=-not $OptionId -or [string]$required.optionId -eq $OptionId
            if($sameControl -and $sameOption -and $required.observations){$required.observations.Add(@($Observation.evaluationCase.observations)[0])}
        }
        if([string]$Observation.expectedOutcomeType -notin @('ValidationRequired','FailureRequired')){
            $groupKey="$ControlId|$OptionId|$([string]$Observation.expectedOutcomeType)|$([string]$Observation.expectationId)"
            if(-not $Context.CurrentSignalEvaluationGroups.ContainsKey($groupKey)){
                $Context.CurrentSignalEvaluationGroups[$groupKey]=[pscustomobject]@{stage=$Stage;controlId=$ControlId;optionId=$OptionId;observation=$Observation;expectedResult=$Observation.evaluationCase.expectedResult;observations=(New-Object Collections.Generic.List[object])}
            }
            $Context.CurrentSignalEvaluationGroups[$groupKey].observations.Add(@($Observation.evaluationCase.observations)[0])
        }
    }
}

function Get-HtsObservationErrorRegex {
    param([Parameter(Mandatory = $true)]$Context,[regex]$BaseRegex,$MapOracle)

    $patterns=New-Object Collections.Generic.List[string]
    $patterns.Add($BaseRegex.ToString())
    if($MapOracle){foreach($message in @($MapOracle.messageBoxes|Where-Object isExplicitError)){if($message.message){$patterns.Add([regex]::Escape([string]$message.message))};if($message.title){$patterns.Add([regex]::Escape([string]$message.title))}}}
    if($Context.MapCatalog -and $Context.MapCatalog.errorCodes){foreach($entry in @($Context.MapCatalog.errorCodes|Where-Object isFailure)){if($entry.code){$patterns.Add("(?<![0-9])$([regex]::Escape([string]$entry.code))(?![0-9])")};if([string]$entry.message -and ([string]$entry.message).Length -ge 6){$patterns.Add([regex]::Escape([string]$entry.message))}}}
    [regex]::new(($patterns -join '|'),[Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-HtsDialogs($Context, $RuntimeContext, $Main, [string]$Secret = "") {
    foreach ($window in @(Get-HtsObservationTopWindows $Context | Where-Object {
        $_.visible -and $_.pid -eq $Main.pid -and $_.hwnd -ne $Main.hwnd -and
        -not $RuntimeContext.TargetScreenTitleRegex.IsMatch([string]$_.rawTitle) -and
        ($_.className -eq "#32770" -or $_.rawTitle -eq "하나증권" -or $_.rawTitle -match '유의사항|참고사항|안내|경고|확인|설정|편집|도움말' -or
            ($_.owner -eq $Main.hwnd -and ($_.rawTitle -or $_.className -notlike 'AfxWnd*')))
    })) {
        $children = @(Get-HtsObservationChildWindows $Context ([Int64]$window.hwnd) | Where-Object { $_.visible })
        $buttons = @($children | Where-Object { $_.className -like "*Button*" -and $_.rawTitle } | ForEach-Object { Protect-HtsObservationText $Context $_.rawTitle $Secret } | Sort-Object -Unique)
        $messages = @($children | Where-Object { $_.className -notlike "*Button*" -and $_.rawTitle } | ForEach-Object { Protect-HtsObservationText $Context $_.rawTitle $Secret } | Sort-Object -Unique)
        $title = Protect-HtsObservationText $Context $window.rawTitle $Secret
        $text = Protect-HtsObservationText $Context ((@($title) + $messages + $buttons | Where-Object { $_ } | Sort-Object -Unique) -join " | ") $Secret
        $classification = if ($text -match '오류|에러|실패|예외|장애|Error|Exception|Fail|SOCKET') {
            "오류"
        } elseif ($text -match '경고|주의|Warning') {
            "경고"
        } elseif ($buttons -match '예|아니오|Yes|No|확인|취소') {
            "확인 요청"
        } else {
            "정보"
        }
        [pscustomobject]@{
            window = $window
            title = $title
            messageLines = $messages
            buttons = $buttons
            classification = $classification
            text = $text
            summary = "$classification 팝업: " + $(if ($messages.Count -gt 0) { $messages -join " / " } elseif ($title) { $title } else { "본문 없음" })
        }
    }
}

function Add-LinkedScreenObservations($Context, $RuntimeContext, $List, $LinkedScreens, $Main, [string]$CaseId, [string]$RequestedScreenNumber, [string]$ReportBase, [string]$Secret = "", $ExpectedTargets = @()) {
    $index=$List.Count
    $expectedNumbers=@($ExpectedTargets | Where-Object targetScreenCode | ForEach-Object {
        $code=[string]$_.targetScreenCode
        $codeMatch=$RuntimeContext.TargetMapScreenCodeRegex.Match($code)
        if($codeMatch.Success){[string]$codeMatch.Groups['screen'].Value}
    } | Where-Object {$_} | Sort-Object -Unique)
    foreach($linked in @($LinkedScreens)){
        $index++
        $linkedNumber=Get-HtsObservationScreenNumber $Context $linked
        $children=@(Get-HtsObservationChildWindows $Context ([Int64]$linked.hwnd) | Where-Object { $_.visible -and $_.rawTitle })
        $buttons=@($children | Where-Object { $_.className -like '*Button*' } | ForEach-Object { Protect-HtsObservationText $Context $_.rawTitle $Secret } | Sort-Object -Unique)
        $messages=@($children | Where-Object { $_.className -notlike '*Button*' } | ForEach-Object { Protect-HtsObservationText $Context $_.rawTitle $Secret } | Sort-Object -Unique | Select-Object -First 30)
        $linkedShot=Join-Path (Join-Path $ReportBase 'screenshots') ("linked-{0}-{1}-{2:000}.png" -f $RequestedScreenNumber,$CaseId,$index)
        $relativeShot=""
        if(Capture-HtsScreenshot $Context $Main $linkedShot){$relativeShot=Get-HtsObservationRelativePath $Context $ReportBase $linkedShot}
        $title=Protect-HtsObservationText $Context ([string]$linked.rawTitle) $Secret
        $isExpected=$expectedNumbers -contains $linkedNumber
        $List.Add([pscustomobject]@{
            popupId="NAV-$CaseId-$('{0:000}' -f $index)";title=$title;messageLines=$messages;buttons=$buttons
            classification=$(if($isExpected){'예상 연계 화면'}else{'예상 밖 연계 화면'});summary="내부 컨트롤 조작으로 연계 화면 [$linkedNumber]이 열렸습니다: $title"
            expected=$isExpected;oracleSource=$(if($isExpected){'MAP 연결 그래프'}else{'런타임 관찰'});screenshotPath=$relativeShot;detectedAt=(Get-HtsObservationNow $Context).ToString('o')
        })
    }
}

function Add-UnnumberedTransitionObservation($Context, $RuntimeContext, $List, $Main, [string]$CaseId, [string]$RequestedScreenNumber, [string]$ReportBase, [string]$Secret = "") {
    $index=$List.Count+1
    $visibleTitles=@(Get-HtsObservationTopWindows $Context | Where-Object {
        $_.visible -and $_.pid -eq $Main.pid -and $_.hwnd -ne $Main.hwnd -and -not $RuntimeContext.TargetScreenTitleRegex.IsMatch([string]$_.rawTitle)
    } | ForEach-Object { Protect-HtsObservationText $Context $_.rawTitle $Secret } | Where-Object { $_ } | Sort-Object -Unique | Select-Object -First 30)
    $transitionShot=Join-Path (Join-Path $ReportBase 'screenshots') ("transition-{0}-{1}-{2:000}.png" -f $RequestedScreenNumber,$CaseId,$index)
    $relativeShot=""
    if(Capture-HtsScreenshot $Context $Main $transitionShot){$relativeShot=Get-HtsObservationRelativePath $Context $ReportBase $transitionShot}
    $List.Add([pscustomobject]@{
        popupId="NAV-$CaseId-$('{0:000}' -f $index)";title='번호 없는 콘텐츠 전환';messageLines=$visibleTitles;buttons=@()
        classification='연계 화면';summary="버튼 조작 후 [$RequestedScreenNumber] 창이 번호 없는 콘텐츠로 전환되거나 자체 닫혀 원래 화면을 다시 열었습니다."
        expected=$true;screenshotPath=$relativeShot;detectedAt=(Get-HtsObservationNow $Context).ToString('o')
    })
}

function Test-HtsConnectionDialog($Dialog) {
    $buttonText = @($Dialog.buttons | ForEach-Object {
        if ($_ -is [string]) { [string]$_ }
        elseif ($_.PSObject.Properties.Name -contains 'title') { [string]$_.title }
        elseif ($_.PSObject.Properties.Name -contains 'name') { [string]$_.name }
        else { [string]$_ }
    }) -join ' '
    $dialogText = (([string]$Dialog.title) + ' ' + ([string]$Dialog.text) + ' ' + (@($Dialog.messageLines) -join ' ') + ' ' + $buttonText)
    $dialogText -match '접속\s*해제|연결이\s*끊어|재접속|프로그램\s*종료|connection\s*(lost|disconnected)|reconnect'
}

function Get-HtsConnectionDialogs($Context, $RuntimeContext, $Main, [string]$Secret = '') {
    if (-not $Main) { return @() }
    @(Get-HtsDialogs $Context $RuntimeContext $Main $Secret | Where-Object { Test-HtsConnectionDialog $_ })
}

function Add-PopupObservations($Context, $List, $Dialogs, $Main, [string]$CaseId, [string]$ScreenNumber, [string]$ReportBase, $ExpectedPatterns, $MapOracle = $null) {
    $index = $List.Count
    foreach ($dialog in @($Dialogs)) {
        $index++
        $expected = $false
        foreach ($pattern in @($ExpectedPatterns)) {
            if ($pattern -and $dialog.text -match [string]$pattern) { $expected=$true; break }
        }
        $mapMatch = Get-HtsMapOracleMessageMatch ([string]$dialog.text) $MapOracle
        $installedMatch = Get-HtsInstallationErrorCodeMatch -Context $Context ([string]$dialog.text)
        $classification = if ($installedMatch) {
            switch ([string]$installedMatch.classification) {
                'Authentication' { '인증 오류' }
                'TransientFailure' { '일시 장애' }
                'SystemFailure' { '시스템 오류' }
                'NoData' { '자료 없음' }
                'Normal' { '정상 응답' }
                default { '입력·업무 검증' }
            }
        } elseif ($mapMatch) {
            switch ([string]$mapMatch.classification) {
                'Error' { '오류' }
                'InputValidation' { '입력 검증' }
                'Warning' { '경고' }
                default { '정보' }
            }
        } else { [string]$dialog.classification }
        $oracleSource = if ($installedMatch) { 'HTS 오류코드' } elseif ($mapMatch) { 'MAP' } else { '공통 규칙' }
        $popupShot = Join-Path (Join-Path $ReportBase "screenshots") ("popup-{0}-{1}-{2:000}.png" -f $ScreenNumber,$CaseId,$index)
        $relativeShot = ""
        if (Capture-HtsScreenshot $Context $Main $popupShot $true) { $relativeShot = Get-HtsObservationRelativePath $Context $ReportBase $popupShot }
        $List.Add([pscustomobject]@{
            popupId="POP-$CaseId-$('{0:000}' -f $index)"; title=[string]$dialog.title
            windowHwnd=[Int64]$dialog.window.hwnd; windowClass=[string]$dialog.window.className; windowRect=$dialog.window.rect
            messageLines=@($dialog.messageLines); buttons=@($dialog.buttons); classification=$classification
            summary="$classification 팝업: " + $(if (@($dialog.messageLines).Count -gt 0) { @($dialog.messageLines) -join ' / ' } elseif ($dialog.title) { [string]$dialog.title } else { '본문 없음' })
            expected=$expected; oracleSource=$oracleSource; oracleRuleId=$(if($mapMatch){[string]$mapMatch.ruleId}else{''})
            mapHandler=$(if($mapMatch){[string]$mapMatch.handler}else{''}); mapMessage=$(if($mapMatch){[string]$mapMatch.message}else{''})
            installedErrorCode=$(if($installedMatch){[string]$installedMatch.code}else{''}); installedErrorClass=$(if($installedMatch){[string]$installedMatch.classification}else{''})
            screenshotPath=$relativeShot; detectedAt=(Get-HtsObservationNow $Context).ToString("o")
        })
    }
}

function Capture-HtsScreenshot($Context, $Main, [string]$Path, [bool]$IncludeVisibleOwnedWindows = $false) {
    $mainHwnd=[IntPtr][Int64]$Main.hwnd
    if(-not [TargetRuleNative]::IsWindow($mainHwnd)){return $false}
    $previousDpiContext=[TargetRuleNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
    $bitmap=$null
    $graphics=$null
    try {
        $physicalMain=Get-HtsObservationWindowInfo $Context $mainHwnd
        $rect=$physicalMain.rect
        $width=[int]$rect.width
        $height=[int]$rect.height
        if($width-le0 -or $height-le0){return $false}
        $bitmap=New-Object Drawing.Bitmap $width,$height
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        $printed=$false
        if(-not $IncludeVisibleOwnedWindows){
            $hdc=$graphics.GetHdc()
            try{$printed=[TargetRuleNative]::PrintWindow($mainHwnd,$hdc,2)}finally{$graphics.ReleaseHdc($hdc)}
        }
        if($IncludeVisibleOwnedWindows -or -not $printed){
            $graphics.CopyFromScreen([int]$rect.left,[int]$rect.top,0,0,(New-Object Drawing.Size $width,$height))
        }
        $bitmap.Save($Path,[Drawing.Imaging.ImageFormat]::Png)
        return $true
    } finally {
        if($graphics){$graphics.Dispose()}
        if($bitmap){$bitmap.Dispose()}
        [void][TargetRuleNative]::SetThreadDpiAwarenessContext($previousDpiContext)
    }
}

function Get-LogState($Context) {
    $state = @{}
    $sources = if ($Context.MapCatalog -and $Context.MapCatalog.logSources) { @($Context.MapCatalog.logSources) } else {
        # 설치 카탈로그가 로그 정의를 제공하지 않을 때도 대상 프로필의 설치 루트 밖으로 벗어나지 않는다.
        $logDirectory = Join-Path $Context.InstallationRoot 'log'
        @(
            [pscustomobject]@{id='DEBUG_MAIN';pathPattern=(Join-Path $logDirectory 'debugmain.log');mode='AppendText';sensitive=$false;failureOnChange=$false},
            [pscustomobject]@{id='SOCKET_ERROR';pathPattern=(Join-Path $logDirectory 'SocketErr.log');mode='AppendText';sensitive=$false;failureOnChange=$false},
            [pscustomobject]@{id='STARTER';pathPattern=(Join-Path $logDirectory 'Starter.log');mode='AppendText';sensitive=$false;failureOnChange=$false}
        )
    }
    foreach ($source in $sources) {
        $paths = if ([string]$source.pathPattern -match '[*?]') { @(Get-ChildItem -Path ([string]$source.pathPattern) -File -ErrorAction SilentlyContinue | ForEach-Object FullName) } else { @([string]$source.pathPattern) }
        foreach ($path in $paths) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $item=Get-Item -LiteralPath $path
            $state[$path] = [pscustomobject]@{
                id=[string]$source.id;mode=[string]$source.mode;sensitive=[bool]$source.sensitive;failureOnChange=[bool]$source.failureOnChange
                length=[Int64]$item.Length;lastWriteUtc=$item.LastWriteTimeUtc.Ticks
            }
        }
    }
    $state
}

function Get-TransmissionDelta($Context, $Before) {
    $after = Get-LogState $Context
    $changes = New-Object Collections.Generic.List[string]
    foreach ($path in $after.Keys) {
        $current = $after[$path]
        if ([string]$current.mode -ne 'SensitiveDelta') { continue }
        if (-not $Before.ContainsKey($path)) {
            $changes.Add([string]$current.id)
            continue
        }
        $previous = $Before[$path]
        if ([Int64]$current.length -ne [Int64]$previous.length -or [Int64]$current.lastWriteUtc -ne [Int64]$previous.lastWriteUtc) {
            $changes.Add([string]$current.id)
        }
    }
    [pscustomobject]@{hasTransmission=($changes.Count-gt0);sources=@($changes.ToArray() | Select-Object -Unique)}
}

function Get-LogErrors($Context, $Before, [regex]$ErrorRegex, [string]$Secret, $MapOracle = $null) {
    $errors = New-Object Collections.Generic.List[string]
    foreach ($path in $Before.Keys) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path
        $beforeState=$Before[$path]
        $offset=if($beforeState -is [ValueType]){[Int64]$beforeState}else{[Int64]$beforeState.length}
        $mode=if($beforeState -is [ValueType]){'AppendText'}else{[string]$beforeState.mode}
        $changed=($item.Length -ne $offset) -or ($beforeState -isnot [ValueType] -and $item.LastWriteTimeUtc.Ticks -ne [Int64]$beforeState.lastWriteUtc)
        if(-not $changed){continue}
        if($mode -eq 'SensitiveDelta'){
            if([bool]$beforeState.failureOnChange){$errors.Add("[민감 로그 변화 감지] 조회 테스트 중 체결·주문 관련 로그의 크기 또는 시간이 변경되었습니다. 원문은 개인정보 보호를 위해 수집하지 않았습니다.")}
            continue
        }
        if($mode -eq 'DiagnosticSnapshot'){
            continue
        }
        if ($item.Length -le $offset) { continue }
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::Default)
            $tokens = if ($MapOracle) { @($MapOracle.requestNames) + @($MapOracle.transactionCodes) } else { @() }
            foreach ($line in @($reader.ReadToEnd() -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                $installedMatch = Get-HtsInstallationErrorCodeMatch -Context $Context ([string]$line)
                $mapMessage = Get-HtsMapOracleMessageMatch ([string]$line) $MapOracle
                $isCandidate=($line -match $ErrorRegex) -or ($line -match '자동\s*로그아웃\s*후|세션\s*만료') -or $installedMatch -or $mapMessage
                if(-not $isCandidate){continue}
                if ($installedMatch -and -not [bool]$installedMatch.isFailure) { continue }
                if ($mapMessage -and -not [bool]$mapMessage.isExplicitError) { continue }
                $matchedToken = @($tokens | Where-Object { $_ -and $line.IndexOf([string]$_, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1)
                $prefix = if ($installedMatch) { "[HTS 오류코드 $($installedMatch.code)/$($installedMatch.classification)] " } elseif ($matchedToken.Count -gt 0) { "[MAP 통신 $($matchedToken[0])] " } else { "" }
                $errors.Add($prefix + (Protect-HtsObservationText $Context $line $Secret))
            }
        } finally { $stream.Dispose() }
    }
    @($errors | Select-Object -Last 20)
}

function Get-ErrorWindowTexts($Context, $Main, [regex]$ErrorRegex, [string]$Secret) {
    $rows = New-Object Collections.Generic.List[string]
    foreach ($window in @(Get-HtsObservationTopWindows $Context | Where-Object { $_.visible -and $_.pid -eq $Main.pid })) {
        $texts = @($window.rawTitle) + @(Get-HtsObservationChildWindows $Context ([Int64]$window.hwnd) | ForEach-Object { $_.rawTitle })
        foreach ($match in @($texts | Where-Object { $_ -and $_ -match $ErrorRegex })) { $rows.Add((Protect-HtsObservationText $Context $match $Secret)) }
    }
    @($rows | Sort-Object -Unique)
}

function Get-ExplicitWindowErrors($Context, $Main, $BeforeErrorTexts, [regex]$ErrorRegex, [string]$Secret, $MapOracle = $null) {
    $rows = New-Object Collections.Generic.List[string]
    $top = @(Get-HtsObservationTopWindows $Context | Where-Object { $_.visible -and $_.pid -eq $Main.pid })
    foreach ($window in $top) {
        $texts = @($window.rawTitle) + @(Get-HtsObservationChildWindows $Context ([Int64]$window.hwnd) | ForEach-Object { $_.rawTitle })
        $matches = @($texts | Where-Object { $_ -and $_ -match $ErrorRegex })
        foreach ($match in $matches) {
            $mapMessage = Get-HtsMapOracleMessageMatch ([string]$match) $MapOracle
            if ($mapMessage -and -not [bool]$mapMessage.isExplicitError) { continue }
            $safe = Protect-HtsObservationText $Context $match $Secret
            if ($BeforeErrorTexts -notcontains $safe) { $rows.Add($safe) }
        }
    }
    @($rows | Sort-Object -Unique)
}
