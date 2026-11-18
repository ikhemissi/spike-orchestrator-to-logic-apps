. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    $script:J2Files = $null
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j2 | Out-Null
}

function GetWorkflowName { 'wf-j2-ftp-to-sharepoint' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "J2 run ended with '$($Run.Status)'."
    }
    $report = (Get-ScenarioRunReport -Run $Run -Job 'J2').Body
    $details = ConvertFrom-ScenarioReportDetail -Report $report
    if ([int]$report.filesProcessed -ne 2) {
        throw 'J2 report did not record two processed files.'
    }
    $reportFileNames = @($details.files | ForEach-Object { $_.name })
    foreach ($fileName in @('participants_salon_2026.csv', 'brochure_export_fr.pdf')) {
        if ($reportFileNames -notcontains $fileName) {
            throw "J2 report did not include '$fileName'."
        }
    }
    if ($script:ScenarioEnvironment.ENABLE_SHAREPOINT -ne 'true') {
        $files = @(Get-BlobFile -Environment $script:ScenarioEnvironment -Container 'sharepoint-sim' -Prefix 'partner-a/')
        foreach ($fileName in @('participants_salon_2026.csv', 'brochure_export_fr.pdf')) {
            if ($files -notcontains "partner-a/$fileName") {
                throw "J2 did not write '$fileName' to the SharePoint simulation container."
            }
        }
        $script:J2Files = $files
    }
    return $true
}

function GetEvidence {
    param($Run)

    $report = Get-ScenarioRunReport -Run $Run -Job 'J2'
    if ($script:J2Files) {
        return @{
            FileListings = @{ 'sharepoint-sim/partner-a' = $script:J2Files }
            Details = "Run report: $($report.BlobName)"
        }
    }
    return @{ Details = "SharePoint output is verified in run report $($report.BlobName)." }
}

function Restore {}
