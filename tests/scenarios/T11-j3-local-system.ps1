. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    $script:RestoredRetry = $null
    $script:FaultRestored = $false
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j3 | Out-Null
}

function InjectFault {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') worker-system-account | Out-Null
}

function GetWorkflowName { 'wf-j3-convert-onprem' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Failed') {
        throw "J3 Local System run ended with '$($Run.Status)' instead of Failed."
    }
    $report = (Get-ScenarioRunReport -Run $Run -Job 'J3').Body
    $reportJson = ConvertTo-Json -InputObject $report -Depth 100 -Compress
    if ($reportJson -notmatch 'ACCESS_DENIED') {
        throw 'J3 Local System run did not report access denied.'
    }
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') restore-all | Out-Null
    $script:FaultRestored = $true
    $retry = Start-Workflow -Environment $script:ScenarioEnvironment -WorkflowName (GetWorkflowName)
    $script:RestoredRetry = Wait-WorkflowRun -Environment $script:ScenarioEnvironment -Run $retry
    if ($script:RestoredRetry.Status -ne 'Succeeded') {
        throw "J3 retry after restoring the custom worker credential ended with '$($script:RestoredRetry.Status)'."
    }
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    $retryStatus = if ($script:RestoredRetry) { $script:RestoredRetry.Status } else { 'not run' }
    return @{ Details = "Expected access denied as Local System; restored retry status: $retryStatus." }
}

function Restore {
    if (-not $script:FaultRestored) {
        & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') restore-all | Out-Null
    }
}
