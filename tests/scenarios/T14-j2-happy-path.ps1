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
    $runJson = ConvertTo-Json -InputObject $Run -Depth 100 -Compress
    foreach ($fileName in @('participants_salon_2026.csv', 'brochure_export_fr.pdf')) {
        if ($runJson -notmatch [regex]::Escape($fileName)) {
            throw "J2 output did not include '$fileName'."
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

    $null = $Run
    if ($script:J2Files) {
        return @{ FileListings = @{ 'sharepoint-sim/partner-a' = $script:J2Files } }
    }
    return @{ Details = 'SharePoint output was checked through workflow run evidence.' }
}

function Restore {}
