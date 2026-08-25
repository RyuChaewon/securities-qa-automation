<#
.SYNOPSIS Failure-safe rule-suite resource cleanup.
.DESCRIPTION Stops injected runtime resources while preserving evidence and never changing business verdicts.
#>

# Attempts injected bridge cleanup and records cleanup facts without clearing action evidence.
function Invoke-HtsRuleSuiteCleanup {
    param(
        [Parameter(Mandatory = $true)]$RunServices,
        [Parameter(Mandatory = $true)]$RunState
    )

    $RunState.CleanupAttempted = $true
    try {
        if ($RunServices.SessionContext -and $RunServices.Cleanup -and $RunServices.Cleanup.StopBridge) {
            & $RunServices.Cleanup.StopBridge $RunServices.SessionContext
        }
        $RunState.CleanupSucceeded = $true
    } catch {
        $RunState.CleanupSucceeded = $false
        $RunState.CleanupErrors.Add((Protect-Text $_.Exception.Message))
    } finally {
        if ($RunServices.AutomationMetrics) { $RunState.UiActionCount = [int]$RunServices.AutomationMetrics.FlaUiActionAttempts }
    }
    $RunState
}
