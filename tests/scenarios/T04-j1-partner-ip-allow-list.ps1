. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    $script:RestoredRetry = $null
    $script:AllowListRestored = $false
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j1 | Out-Null
}

function InjectFault {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') partner-ip-block | Out-Null
}

function GetWorkflowName { 'wf-j1-partner-ftp-to-sftp' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Failed') {
        throw "J1 partner-IP fault ended with '$($Run.Status)' instead of Failed."
    }
    $startedAt = [datetime]::Parse($Run.Run.properties.startTime).ToUniversalTime()
    $null = Wait-ScenarioAlert -RuleName 'alert-workflow-failed' -NotBefore $startedAt
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') restore-all | Out-Null
    $script:AllowListRestored = $true
    $retry = Start-Workflow -Environment $script:ScenarioEnvironment -WorkflowName (GetWorkflowName)
    $script:RestoredRetry = Wait-WorkflowRun -Environment $script:ScenarioEnvironment -Run $retry
    if ($script:RestoredRetry.Status -ne 'Succeeded') {
        throw "J1 retry after restoring the partner allow-list ended with '$($script:RestoredRetry.Status)'."
    }
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    $retryStatus = if ($script:RestoredRetry) { $script:RestoredRetry.Status } else { 'not run' }
    return @{ Details = "Workflow-failed alert observed; restored retry status: $retryStatus." }
}

function Restore {
    if (-not $script:AllowListRestored) {
        & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') restore-all | Out-Null
    }
}
