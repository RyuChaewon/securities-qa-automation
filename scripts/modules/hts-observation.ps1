<#
.SYNOPSIS HTS 메시지와 대화상자 신호를 원시 Observation 계약으로 정규화한다.
.DESCRIPTION Observation은 증거와 기대 계약을 연결하지만 최종 PASS, FAIL, ERROR 또는 PENDING 판정을 수행하지 않는다.
#>

function New-HtsObservationContext {
    param(
        $MapCatalog,
        [Parameter(Mandatory = $true)]$Dependencies
    )

    [pscustomobject]@{
        MapCatalog = $MapCatalog
        Dependencies = $Dependencies
        ResultEvaluationSequence = 0
        CurrentResultEvaluationCases = New-Object Collections.Generic.List[object]
        CurrentSignalEvaluationGroups = @{}
        CurrentRequiredExpectations = New-Object Collections.Generic.List[object]
    }
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
