. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j3 | Out-Null
}

function GetWorkflowName { 'wf-j3-convert-onprem' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "J3 duplicate run ended with '$($Run.Status)'."
    }
    $report = (Get-ScenarioRunReport -Run $Run -Job 'J3').Body
    if ([int]$report.filesSkipped -ne 2) {
        throw 'J3 did not report both files as skipped.'
    }
    $outputPath = Join-Path $script:ScenarioEnvironment.NAS_SHARE_UNC 'j3\out'
    $outputNames = @(Get-NasFile -Environment $script:ScenarioEnvironment -Path $outputPath)
    $jsonFiles = @($outputNames | Where-Object { $_ -like '*.json' -and $_ -notlike '*.json.sha256' })
    if ($jsonFiles.Count -ne 2) {
        throw "J3 duplicate run left $($jsonFiles.Count) JSON outputs instead of two."
    }
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = 'This scenario re-seeds T08 inputs without resetting the existing converted output.' }
}

function Restore {}
