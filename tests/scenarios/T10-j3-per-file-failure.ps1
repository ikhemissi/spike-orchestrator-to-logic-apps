. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j3-failure | Out-Null
}

function GetWorkflowName { 'wf-j3-convert-onprem' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Failed') {
        throw "J3 per-file failure run ended with '$($Run.Status)' instead of Failed."
    }
    $runJson = ConvertTo-Json -InputObject $Run -Depth 100 -Compress
    foreach ($expected in @('PartialFailure', '"filesFailed"\s*:\s*1', 'RUNBOOK_REPORTED_FAILURE')) {
        if ($runJson -notmatch $expected) {
            throw "J3 failure output did not include '$expected'."
        }
    }
    if ($runJson -notmatch 'payroll_extract_202611\.json|hr_movements_202611\.json') {
        throw 'J3 did not report a successfully processed file alongside the failed file.'
    }
    $startedAt = [datetime]::Parse($Run.Run.properties.startTime).ToUniversalTime()
    $null = Wait-ScenarioAlert -RuleName 'alert-workflow-failed' -NotBefore $startedAt
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = 'Workflow-failed alert observed; the other J3 input was processed.' }
}

function Restore {}
