<#
.SYNOPSIS 사용자의 manual mouse interaction을 전후 native frame과 묶어 로컬 Discovery artifact로 기록한다.
.DESCRIPTION injected input이나 keyboard 문자열 없이 pointer/WinEvent queue, read-only bridge frame과 suggestion을 조정한다.
.INPUTS dependency-injected observer/bridge context, root HWND, output directory와 제한 시간.
.OUTPUTS interaction session, observations, zones, role/state/repository/scenario suggestion JSON과 snapshot references.
.NOTES UI Action, transactional injection, ResultEvaluator, TestResult와 자동 repository 승인은 수행하지 않는다.
#>

$ErrorActionPreference = 'Stop'

# Recorder의 native hook, frame 관측과 파일 출력을 테스트 가능한 dependency로 묶는다.
function New-HtsPassiveInteractionRecorderContext {
    param([Parameter(Mandatory = $true)]$Dependencies)
    [pscustomobject]@{ Dependencies = $Dependencies }
}

# 필수 dependency가 없는 production 실행을 fail-closed로 중단한다.
function Invoke-HtsPassiveRecorderDependency {
    param($Context,[string]$Name,[object[]]$Arguments=@())
    if (-not $Context -or -not $Context.Dependencies -or -not ($Context.Dependencies.PSObject.Properties.Name -contains $Name)) {
        throw "PASSIVE_RECORDER_DEPENDENCY_MISSING: $Name"
    }
    $dependency=$Context.Dependencies.$Name
    if(-not($dependency-is[scriptblock])){throw "PASSIVE_RECORDER_DEPENDENCY_INVALID: $Name"}
    & $dependency @Arguments
}

# 모든 산출물의 Discovery/TestResult 분리 metadata를 한 곳에서 고정한다.
function New-HtsPassiveRecorderEnvelope {
    param([Parameter(Mandatory = $true)][string]$ArtifactKind,[Parameter(Mandatory = $true)]$Payload)
    [ordered]@{
        schemaVersion='1.0';artifactRole='Discovery';artifactKind=$ArtifactKind
        interactionRole='ObservedManualInteraction';testExecution=$false;verdictEligible=$false
        resultEvaluatorInvoked=$false;canonicalVerdict=$null;scenarioId=$null;caseId=$null
        executionStatus='NotExecuted';verdictStatus='NoCanonicalVerdict';evaluatorStatus='ResultEvaluatorNotInvoked'
        automated=$false;payload=$Payload
    }
}

# 계정·password·keyboard 문자열이나 action/verdict metadata가 저장 직전 객체에 나타나면 차단한다.
function Assert-HtsPassiveRecorderArtifactSafety {
    param([Parameter(Mandatory = $true)]$Artifact)
    $json=ConvertTo-Json -InputObject $Artifact -Depth 40 -Compress
    $forbiddenProperty='"(?:rawText|observedValue|currentValue|keyboardText|keystroke|passwordValue|typedText)"\s*:'
    if($json-match$forbiddenProperty){throw "PASSIVE_RECORDER_REDACTION_FAILED: forbidden plaintext-bearing property '$($Matches[0])'"}
    if($json-match'"(?:actionSentCount|transactionalActionCount)"\s*:\s*[1-9]'){throw 'PASSIVE_RECORDER_ACTION_COUNT_NONZERO'}
    if($json-match'"(?:testExecution|verdictEligible|resultEvaluatorInvoked|automated)"\s*:\s*true'){throw 'PASSIVE_RECORDER_DISCOVERY_METADATA_INVALID'}
    $true
}

# target profile과 동일한 화면 영역 가설을 frame 요청에 전달한다.
function Get-HtsPassiveRecorderRegions {
    @(
        [ordered]@{region='GlobalHeader';left=0.0;top=0.0;right=1.0;bottom=0.12;priority=20},
        [ordered]@{region='QuotePanel';left=0.0;top=0.12;right=0.5;bottom=0.62;priority=10},
        [ordered]@{region='OrderEntryPanel';left=0.5;top=0.12;right=1.0;bottom=0.62;priority=10},
        [ordered]@{region='TradeInfoPanel';left=0.0;top=0.62;right=1.0;bottom=1.0;priority=10})
}

# interaction·zone을 최종 승인 없이 사람이 검토할 7개 로컬 artifact payload로 투영한다.
function New-HtsPassiveInteractionArtifactSet {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Interactions,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Zones)
    $roleSuggestions=@($Interactions|ForEach-Object{
        [ordered]@{interactionId=[string]$_.interactionId;status='ReviewRequired';role=[string]$_.suggestion.inferredRole
            actionKind=[string]$_.suggestion.inferredActionKind;confidence=[double]$_.suggestion.confidence
            ambiguity=[bool]$_.suggestion.ambiguous;transactionalRiskCandidate=[bool]$_.suggestion.transactionalRiskCandidate
            evidence=@($_.suggestion.evidence);automaticallyApproved=$false}
    })
    $stateSuggestions=@($Interactions|Where-Object{
        [string]$_.suggestion.inferredActionKind-eq'Select'-and[bool]$_.delta.stateFingerprintChanged
    }|ForEach-Object{
        [ordered]@{interactionId=[string]$_.interactionId;status='ConfigurationRequired';candidateStateContext=[string]$_.suggestion.inferredRole
            preStateFingerprint=[string]$_.preStateFingerprint;postStateFingerprint=[string]$_.postStateFingerprint
            transitionApproved=$false;restoreConfigured=$false;evidenceRefs=@([string]$_.preFrameReference,[string]$_.postFrameReference)}
    })
    $repositoryCandidates=@($Zones|ForEach-Object{
        [ordered]@{repositoryKey=$null;status='ReviewRequired';approvalStatus='Unapproved';executable=$false
            zoneId=[string]$_.zoneId;parentHwnd=[Int64]$_.parentHwnd;nativeSignature=[string]$_.nativeSignature;className=[string]$_.className
            spatialRegion=[string]$_.spatialRegion;normalizedPoint=[ordered]@{x=[double]$_.centerX;y=[double]$_.centerY}
            stateContext='ConfigurationRequired'
            logicalRoleSuggestion=[string]$_.roleSuggestion;actionKindSuggestion=[string]$_.actionKindSuggestion
            confidence=[double]$_.confidence;automaticallyApproved=$false;rawAbsolutePointPersistent=$false}
    })
    $scenarioHints=@($roleSuggestions|ForEach-Object{
        [ordered]@{interactionId=$_.interactionId;status='ConfigurationRequired';logicalRoleSuggestion=$_.role
            actionKindSuggestion=$_.actionKind;executableScenario=$false;humanReviewRequired=$true}
    })
    [ordered]@{
        'interaction-session.json'=(New-HtsPassiveRecorderEnvelope 'InteractionSession' $Session)
        'observed-interactions.json'=(New-HtsPassiveRecorderEnvelope 'ObservedInteractions' ([ordered]@{interactions=$Interactions}))
        'interaction-zones.json'=(New-HtsPassiveRecorderEnvelope 'InteractionZones' ([ordered]@{zones=$Zones}))
        'state-transition-suggestions.json'=(New-HtsPassiveRecorderEnvelope 'StateTransitionSuggestions' ([ordered]@{suggestions=$stateSuggestions}))
        'logical-role-suggestions.json'=(New-HtsPassiveRecorderEnvelope 'LogicalRoleSuggestions' ([ordered]@{suggestions=$roleSuggestions}))
        'control-repository-candidates.json'=(New-HtsPassiveRecorderEnvelope 'ControlRepositoryCandidates' ([ordered]@{status='ReviewRequired';automaticallyApproved=$false;candidates=$repositoryCandidates}))
        'scenario-authoring-hints.json'=(New-HtsPassiveRecorderEnvelope 'ScenarioAuthoringHints' ([ordered]@{status='ConfigurationRequired';hints=$scenarioHints;executableScenarios=@()}))
    }
}

# hook queue의 manual click을 100/300/750ms post frames와 상관분석하고 local artifact만 저장한다.
function Invoke-HtsPassiveInteractionRecording {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][Int64]$RootHwnd,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [ValidateRange(1,7200)][int]$MaxDurationSeconds=1800,
        [ValidateRange(50,2000)][int]$IdleSnapshotMilliseconds=400)
    $fullOutput=[IO.Path]::GetFullPath($OutputDirectory)
    $snapshotDirectory=Join-Path $fullOutput 'snapshots'
    Invoke-HtsPassiveRecorderDependency $Context 'EnsureDirectory' @($snapshotDirectory)|Out-Null
    $regions=Get-HtsPassiveRecorderRegions
    $initial=Invoke-HtsPassiveRecorderDependency $Context 'CaptureFrame' @($RootHwnd,$null,$regions)
    if(-not$initial-or[Int64]$initial.rootHwnd-ne$RootHwnd-or[int]$initial.actionSentCount-ne0-or[int]$initial.transactionalActionCount-ne0){throw 'PASSIVE_RECORDER_INITIAL_FRAME_INVALID'}
    foreach($remaining in 3..1){Invoke-HtsPassiveRecorderDependency $Context 'WriteStatus' @("Recording starts in $remaining...")|Out-Null;Invoke-HtsPassiveRecorderDependency $Context 'WaitMilliseconds' @(1000)|Out-Null}
    Invoke-HtsPassiveRecorderDependency $Context 'StartObserver' @([int]$initial.processId)|Out-Null
    $startedAt=Invoke-HtsPassiveRecorderDependency $Context 'Now'
    $deadline=$startedAt.AddSeconds($MaxDurationSeconds)
    $lastFrame=$initial;$lastIdleAt=$startedAt;$stopReason='Unknown'
    $downByButton=@{};$preByButton=@{};$interactions=New-Object Collections.Generic.List[object]
    $windowEvents=New-Object Collections.Generic.List[object]
    try{
        $lastFrame=Invoke-HtsPassiveRecorderDependency $Context 'CaptureFrame' @($RootHwnd,$null,$regions)
        if(-not$lastFrame-or[Int64]$lastFrame.rootHwnd-ne$RootHwnd-or[int]$lastFrame.actionSentCount-ne0-or[int]$lastFrame.transactionalActionCount-ne0){throw 'PASSIVE_RECORDER_RECORDING_FRAME_INVALID'}
        Invoke-HtsPassiveRecorderDependency $Context 'WriteStatus' @('Recording manual clicks. Press F10 globally or return to the console and press Enter to stop.')|Out-Null
        while($true){
            $now=Invoke-HtsPassiveRecorderDependency $Context 'Now'
            if($now-ge$deadline){$stopReason='MaximumDuration';break}
            $requested=Invoke-HtsPassiveRecorderDependency $Context 'GetStopReason'
            if($requested){$stopReason=[string]$requested;break}
            while($true){$event=Invoke-HtsPassiveRecorderDependency $Context 'TryDequeueWindowEvent';if($null-eq$event){break};$windowEvents.Add($event)}
            $pointer=Invoke-HtsPassiveRecorderDependency $Context 'TryDequeuePointer'
            if($null-ne$pointer){
                if([bool]$pointer.injected){continue}
                $button=[string]$pointer.button;$phase=[string]$pointer.phase
                if($phase-eq'Down'){
                    $downByButton[$button]=$pointer
                    $downPoint=[ordered]@{x=[int]$pointer.x;y=[int]$pointer.y}
                    $preByButton[$button]=Invoke-HtsPassiveRecorderDependency $Context 'CaptureFrame' @($RootHwnd,$downPoint,$regions)
                    continue
                }
                if($phase-ne'Up'-or-not$downByButton.ContainsKey($button)){continue}
                $down=$downByButton[$button];$downByButton.Remove($button)
                $preFrame=if($preByButton.ContainsKey($button)){$preByButton[$button]}else{$lastFrame}
                $preByButton.Remove($button)
                $point=[ordered]@{x=[int]$pointer.x;y=[int]$pointer.y}
                $immediate=Invoke-HtsPassiveRecorderDependency $Context 'CaptureFrame' @($RootHwnd,$point,$regions)
                $insideBefore=$null-ne$preFrame.hitTarget-and[bool]$preFrame.hitTarget.insideTarget
                $insideAfter=$null-ne$immediate.hitTarget-and[bool]$immediate.hitTarget.insideTarget
                if(-not$insideBefore-and-not$insideAfter){$lastFrame=$immediate;continue}
                $postFrames=New-Object Collections.Generic.List[object];$postFrames.Add($immediate)
                foreach($delay in @(100,200,450)){
                    Invoke-HtsPassiveRecorderDependency $Context 'WaitMilliseconds' @($delay)|Out-Null
                    $postFrames.Add((Invoke-HtsPassiveRecorderDependency $Context 'CaptureFrame' @($RootHwnd,$point,$regions)))
                }
                while($true){$event=Invoke-HtsPassiveRecorderDependency $Context 'TryDequeueWindowEvent';if($null-eq$event){break};$windowEvents.Add($event)}
                $eventStart=([DateTimeOffset]$down.observedAt).AddMilliseconds(-100)
                $eventEnd=([DateTimeOffset]$postFrames[$postFrames.Count-1].observedAt).AddMilliseconds(100)
                $correlated=@($windowEvents|Where-Object{[DateTimeOffset]$_.observedAt-ge$eventStart-and[DateTimeOffset]$_.observedAt-le$eventEnd})
                $sequence=$interactions.Count+1;$previous=if($interactions.Count-gt0){$interactions[$interactions.Count-1]}else{$null}
                $postFrameArray=$postFrames.ToArray()
                $interaction=Invoke-HtsPassiveRecorderDependency $Context 'AnalyzeInteraction' @($sequence,$down,$pointer,$preFrame,$postFrameArray,$correlated,$previous)
                if(-not$interaction-or[bool]$interaction.automated-or[bool]$interaction.testExecution-or[bool]$interaction.verdictEligible-or[bool]$interaction.resultEvaluatorInvoked-or$null-ne$interaction.canonicalVerdict-or[int]$interaction.actionSentCount-ne0-or[int]$interaction.transactionalActionCount-ne0){throw 'PASSIVE_RECORDER_INTERACTION_METADATA_INVALID'}
                $prePath=Join-Path $fullOutput ([string]$interaction.preFrameReference)
                $postPath=Join-Path $fullOutput ([string]$interaction.postFrameReference)
                Invoke-HtsPassiveRecorderDependency $Context 'WriteJson' @($prePath,$preFrame)|Out-Null
                Invoke-HtsPassiveRecorderDependency $Context 'WriteJson' @($postPath,([ordered]@{samples=$postFrameArray}))|Out-Null
                $interactions.Add($interaction);$lastFrame=$postFrames[$postFrames.Count-1];$lastIdleAt=Invoke-HtsPassiveRecorderDependency $Context 'Now'
                Invoke-HtsPassiveRecorderDependency $Context 'WriteStatus' @("Observed interaction $sequence at $($pointer.x),$($pointer.y) -> $([string]$interaction.suggestion.inferredRole)")|Out-Null
                continue
            }
            if(($now-$lastIdleAt).TotalMilliseconds-ge$IdleSnapshotMilliseconds){$lastFrame=Invoke-HtsPassiveRecorderDependency $Context 'CaptureFrame' @($RootHwnd,$null,$regions);$lastIdleAt=$now}
            Invoke-HtsPassiveRecorderDependency $Context 'WaitMilliseconds' @(20)|Out-Null
        }
    }finally{Invoke-HtsPassiveRecorderDependency $Context 'StopObserver'|Out-Null}
    $completedAt=Invoke-HtsPassiveRecorderDependency $Context 'Now'
    $interactionArray=$interactions.ToArray()
    $zones = if ($interactionArray.Count -eq 0) { @() } else { @(Invoke-HtsPassiveRecorderDependency $Context 'ClusterInteractions' @($interactionArray,0.04)) }
    $regionCounts=@($interactions|Group-Object{$_.hitTarget.spatialRegion}|ForEach-Object{[ordered]@{region=$_.Name;interactionCount=$_.Count}})
    $session=[ordered]@{
        sessionId='passive-'+[Guid]::NewGuid().ToString('N');rootHwnd=$RootHwnd;processId=[int]$initial.processId
        startedAt=$startedAt;completedAt=$completedAt;durationSeconds=[Math]::Round(($completedAt-$startedAt).TotalSeconds,3);stopReason=$stopReason
        executionStatus=if($interactionArray.Count -eq 0){'NoInteractionsCaptured'}else{'Completed'}
        diagnosticCode=if($interactionArray.Count -eq 0){switch($stopReason){'MaximumDuration'{'PASSIVE_TIMEOUT_NO_INTERACTIONS'}'F10'{'PASSIVE_F10_NO_INTERACTIONS'}'ConsoleEnter'{'PASSIVE_ENTER_NO_INTERACTIONS'}default{'PASSIVE_NO_INTERACTIONS'}}}else{$null}
        diagnosticMessage=if($interactionArray.Count -eq 0){'Recorder waited for manual interaction and ended without a captured interaction.'}else{$null}
        interactionCount=$interactions.Count;uniqueTargetHwndCount=@($interactions.hitTarget.primaryHwnd|Sort-Object -Unique).Count
        ownerDrawnZoneCount=@($zones|Where-Object{[string]$_.className-match'^Afx|OwnerDrawn'}).Count;popupChangeCount=@($interactions|Where-Object{@($_.delta.popupCreatedHwnds).Count-gt0-or@($_.delta.popupClosedHwnds).Count-gt0}).Count
        selectionChangeCount=@($interactions|Where-Object{[bool]$_.delta.selectionEventObserved}).Count;stateChangeCount=@($interactions|Where-Object{[bool]$_.delta.stateFingerprintChanged}).Count
        ambiguousInteractionCount=@($interactions|Where-Object{[bool]$_.suggestion.ambiguous}).Count
        regionCounts=$regionCounts;rawScreenshotStored=$false;visualHashStored=$true;keyboardStringRecorded=$false
        uiActionCount=0;transactionalActionCount=0;automated=$false;testExecution=$false;verdictEligible=$false;resultEvaluatorInvoked=$false
    }
    $artifacts=New-HtsPassiveInteractionArtifactSet -Session $session -Interactions $interactionArray -Zones $zones
    foreach($entry in $artifacts.GetEnumerator()){
        [void](Assert-HtsPassiveRecorderArtifactSafety $entry.Value)
        Invoke-HtsPassiveRecorderDependency $Context 'WriteJson' @((Join-Path $fullOutput $entry.Key),$entry.Value)|Out-Null
    }
    [pscustomobject]@{OutputDirectory=$fullOutput;Session=$session;Interactions=$interactionArray;Zones=$zones;ArtifactFiles=[string[]]$artifacts.Keys;UiActionCount=0;TransactionalActionCount=0}
}




