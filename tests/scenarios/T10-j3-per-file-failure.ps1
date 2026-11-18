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
    $report = (Get-ScenarioRunReport -Run $Run -Job 'J3').Body
    $details = ConvertFrom-ScenarioReportDetail -Report $report
    if ($report.outcome -ne 'Failed' -or [int]$report.filesFailed -ne 1 -or $details.status -ne 'PartialFailure') {
        throw 'J3 report did not record one per-file failure and a PartialFailure runbook status.'
    }
    if (@($details.items | Where-Object { $_.result -eq 'converted' }).Count -lt 1) {
        throw 'J3 did not report a successfully processed file alongside the failed file.'
    }
    $startedAt = [datetime]::Parse($Run.Run.properties.startTime).ToUniversalTime()
    $script:WorkflowFailedAlertObserved = Wait-ScenarioAlertIfEnabled -RuleName 'alert-workflow-failed' -NotBefore $startedAt
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = "Workflow-failed alert observed: $script:WorkflowFailedAlertObserved; the other J3 input was processed." }
}

function Restore {}
