. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j1 | Out-Null
}

function GetWorkflowName { 'wf-j1-partner-ftp-to-sftp' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "J1 duplicate run ended with '$($Run.Status)'."
    }
    $report = (Get-ScenarioRunReport -Run $Run -Job 'J1').Body
    if ([int]$report.filesSkipped -ne 3) {
        throw 'J1 did not report three skipped duplicate files.'
    }
    if ([int]$report.filesProcessed -ne 0) {
        throw 'J1 reported new deliveries during the duplicate run.'
    }
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = 'This scenario re-seeds the output of T02 without resetting partner state.' }
}

function Restore {}
