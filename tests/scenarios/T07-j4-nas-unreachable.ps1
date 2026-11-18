. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j4 | Out-Null
}

function InjectFault {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') nas-block | Out-Null
}

function GetWorkflowName { 'wf-j4-ftp-sort-to-nas' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Failed') {
        throw "J4 NAS-block run ended with '$($Run.Status)' instead of Failed."
    }
    $startedAt = [datetime]::Parse($Run.Run.properties.startTime).ToUniversalTime()
    $script:WorkflowFailedAlertObserved = Wait-ScenarioAlertIfEnabled -RuleName 'alert-workflow-failed' -NotBefore $startedAt
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = "Workflow-failed alert observed: $script:WorkflowFailedAlertObserved." }
}

function Restore {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') restore-all | Out-Null
}
