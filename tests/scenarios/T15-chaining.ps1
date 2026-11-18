. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j1 | Out-Null
}

function GetWorkflowName { 'wf-j1-partner-ftp-to-sftp' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "Source workflow ended with '$($Run.Status)'."
    }
    $runReport = Get-ScenarioRunReport -Run $Run -Job 'J1'
    if ($runReport.Body.job -ne 'J1' -or $runReport.Body.correlationId -ne $runReport.CorrelationId) {
        throw 'The child report does not match the source workflow correlationId.'
    }
    $script:ChainedReport = $runReport.BlobName
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ FileListings = @{ 'run-reports' = @($script:ChainedReport) } }
}

function Restore {}
