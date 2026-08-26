$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts/modules/hts-passive-interaction-recorder.ps1')
$now=[DateTimeOffset]::Parse('2026-01-01T00:00:00+09:00'); $script:ticks=0
$ctx=New-HtsPassiveInteractionRecorderContext -Dependencies ([pscustomobject]@{
  EnsureDirectory={param($p)}; CaptureFrame={param($h,$p,$r) [pscustomobject]@{rootHwnd=$h;processId=1;actionSentCount=0;transactionalActionCount=0;hitTarget=[pscustomobject]@{insideTarget=$true};observedAt=$now}}
  StartObserver={param($p)}; StopObserver={}; GetStopReason={'MaximumDuration'}; TryDequeuePointer={$null}; TryDequeueWindowEvent={$null}
  Now={$now.AddMilliseconds($script:ticks)}; WaitMilliseconds={param($m) $script:ticks += $m}; WriteStatus={param($m)}; WriteJson={param($p,$v)}; ClusterInteractions={param($i,$t) throw 'must not cluster empty'}
})
$out=Join-Path $env:TEMP ('passive-empty-'+[guid]::NewGuid().ToString('N'))
$r=Invoke-HtsPassiveInteractionRecording -Context $ctx -RootHwnd 1 -OutputDirectory $out -MaxDurationSeconds 1
if($r.Session.interactionCount -ne 0 -or $r.Session.executionStatus -ne 'NoInteractionsCaptured' -or $r.Session.diagnosticCode -ne 'PASSIVE_TIMEOUT_NO_INTERACTIONS'){throw 'empty recorder contract failed'}
'HTS_PASSIVE_INTERACTION_EMPTY_TESTS=PASS assertions=3'


