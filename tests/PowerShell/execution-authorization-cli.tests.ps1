<# .SYNOPSIS Verifies additive execution-authorization CLI I/O without HTS, UI, or action calls. #>
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cli=Join-Path $root 'src/HtsQa.Cli/bin/Release/net8.0-windows/HtsQa.Cli.dll'
$script:assertions=0

function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT_TRUE failed: $Message"};$script:assertions++}
function Assert-Equal($Expected,$Actual,[string]$Message){if([string]$Expected-ne[string]$Actual){throw "ASSERT_EQUAL failed: $Message expected='$Expected' actual='$Actual'"};$script:assertions++}
function Invoke-Cli([string[]]$Arguments){
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName='dotnet';$info.UseShellExecute=$false
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$root
    [void]$info.ArgumentList.Add($cli);foreach($argument in $Arguments){[void]$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($info);$stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();$process.WaitForExit()
    [pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdout;StdErr=$stderr}
}

& dotnet build (Join-Path $root 'src/HtsQa.Cli/HtsQa.Cli.csproj') -c Release --no-restore | Out-Null
if($LASTEXITCODE-ne0){throw 'HtsQa.Cli Release build failed'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('htsqa-execution-auth-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $environment=[ordered]@{
        targetId='fixture-target';productClassification='synthetic-hts';executableFingerprint='fixture-exe-hash'
        installationFingerprint='fixture-install-hash';versionFingerprint='1.0';hostClassification='isolated-test-host'
        machineFingerprint='fixture-machine-hash';environmentClassification='Test';routingClassification='simulation-routing'
        accountClassification='Test';adapterVersion='fixture-adapter/1.0';executionPolicyVersion='fixture-policy/1.0'
    }
    $draft=[ordered]@{environment=$environment;scope=[ordered]@{
        schemaVersion='1.0';policyVersion='fixture-policy/1.0';targetIds=@('fixture-target');screens=@('F001');maps=@('FAKE-MAP')
        allowedActions=@('Observe');allowedRiskClasses=@('ObservationOnly');transactionalActionsAllowed=$false
        allowedOrderTypes=@();expiresAt='2026-09-25T09:00:00+09:00'
    }}
    $draftPath=Join-Path $temp 'draft.json';$approvalPath=Join-Path $temp 'approval.json';$authorizationPath=Join-Path $temp 'authorization.json'
    $draft|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $draftPath -Encoding utf8NoBOM
    $created=Invoke-Cli @('create-execution-authorization-approval','--request',$draftPath,'--out',$approvalPath)
    Assert-Equal 0 $created.ExitCode 'approval template exit code';Assert-Equal '' $created.StdErr 'approval template stderr'
    $overlay=Get-Content -LiteralPath $approvalPath -Raw|ConvertFrom-Json
    $overlay.status='Approved';$overlay|Add-Member -NotePropertyName approvedBy -NotePropertyValue 'fixture-reviewer'
    $overlay|Add-Member -NotePropertyName approvedAt -NotePropertyValue '2026-08-25T09:00:00+09:00';$overlay.evidenceRefs=@('fixture:classified-environment')
    $overlay|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $approvalPath -Encoding utf8NoBOM
    $applied=Invoke-Cli @('apply-execution-authorization-approval','--request',$draftPath,'--approval',$approvalPath,'--out',$authorizationPath)
    Assert-Equal 0 $applied.ExitCode 'authorization apply exit code';Assert-Equal '' $applied.StdErr 'authorization apply stderr'

    $authorization=Get-Content -LiteralPath $authorizationPath -Raw|ConvertFrom-Json
    Assert-Equal '2.0' $authorization.authorizationHashVersion 'authorization hash version'
    $originalExpiry=[DateTimeOffset]::Parse([string]$authorization.scope.expiresAt,[Globalization.CultureInfo]::InvariantCulture)
    $authorization.scope.expiresAt=$originalExpiry.UtcDateTime
    $requestPath=Join-Path $temp 'check.json';$decisionPath=Join-Path $temp 'decision.json'
    $request=[ordered]@{
        currentEnvironment=$environment;authorization=$authorization
        repository=[ordered]@{schemaVersion='1.0';repositoryId='empty-synthetic';targetProfileId='fixture-target';status='ConfigurationRequired';entries=@()}
        requirements=@();controlObservations=@();requestedCaseCount=1;planHash='plan-change-does-not-reapprove'
    }
    $request|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $requestPath -Encoding utf8NoBOM
    $requestJson=Get-Content -LiteralPath $requestPath -Raw
    Assert-True ($requestJson-match'"expiresAt"\s*:\s*"2026-09-25T00:00:00(?:\.0000000)?Z"') 'PowerShell JSON round-trip writes the same instant in UTC'
    $checked=Invoke-Cli @('check-execution-authorization','--request',$requestPath,'--checked-at','2026-08-25T09:05:00+09:00','--out',$decisionPath)
    $decision=Get-Content -LiteralPath $decisionPath -Raw|ConvertFrom-Json
    Assert-Equal 0 $checked.ExitCode 'authorization check exit code';Assert-Equal 'Authorized' $decision.status 'Core decision is preserved'
    Assert-Equal 0 $decision.actualActionCallCount 'CLI sends no action';Assert-True ([bool]$decision.isAuthorized) 'approved synthetic environment is authorized'

    $reporter=(Get-Content -LiteralPath (Join-Path $root 'tools/reporting/rule-results-loader.mjs') -Raw -Encoding UTF8)+
        (Get-Content -LiteralPath (Join-Path $root 'tools/reporting/rule-results-view-model.mjs') -Raw -Encoding UTF8)
    Assert-True ($reporter-notmatch'ExecutionAuthorizationService|ComputeHash|ControlContractHasher') 'reporter does not rejudge authorization'
}
finally {
    if(Test-Path -LiteralPath $temp){[IO.Directory]::Delete($temp,$true)}
}
Write-Output "EXECUTION_AUTHORIZATION_CLI_TESTS=PASS assertions=$script:assertions"
