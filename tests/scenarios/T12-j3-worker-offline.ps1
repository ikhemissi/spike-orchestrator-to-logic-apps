. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j3 | Out-Null
}

function InjectFault {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') worker-stop | Out-Null
}

function GetWorkflowName { 'wf-j3-convert-onprem' }

function Assert {
    param($Run)

    # VERIFY: the deployed j3PollTimeout is configured below the runner's 10-minute wait timeout.
    if ($Run.Status -ne 'Failed') {
        throw "J3 worker-offline run ended with '$($Run.Status)' instead of Failed."
    }
    $runJson = ConvertTo-Json -InputObject $Run -Depth 100 -Compress
    if ($runJson -notmatch 'HYBRID_JOB_TIMEOUT') {
        throw 'J3 worker-offline run did not report HYBRID_JOB_TIMEOUT.'
    }
    $startedAt = [datetime]::Parse($Run.Run.properties.startTime).ToUniversalTime()
    $null = Wait-ScenarioAlert -RuleName 'alert-hybrid-job-stuck' -NotBefore $startedAt
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = 'Hybrid-job-stuck alert observed; the worker is restarted by Restore.' }
}

function Restore {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') restore-all | Out-Null
}
