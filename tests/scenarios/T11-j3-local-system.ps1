function Reset {
    $script:RestoredRetry = $null
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
    $runJson = ConvertTo-Json -InputObject $Run -Depth 100 -Compress
    if ($runJson -notmatch '(?i)access denied') {
        throw 'J3 Local System run did not report access denied.'
    }
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') restore-all | Out-Null
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
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') restore-all | Out-Null
}
