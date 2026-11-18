function Reset {
    $script:J4FileListings = @{}
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j4 | Out-Null
}

function GetWorkflowName { 'wf-j4-ftp-sort-to-nas' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "J4 run ended with '$($Run.Status)'."
    }
    $environment = $script:ScenarioEnvironment
    $folders = @{
        'j4/finance' = @(Get-NasFile -Environment $environment -Path (Join-Path $environment.NAS_SHARE_UNC 'j4\finance'))
        'j4/documents' = @(Get-NasFile -Environment $environment -Path (Join-Path $environment.NAS_SHARE_UNC 'j4\documents'))
        'j4/integration' = @(Get-NasFile -Environment $environment -Path (Join-Path $environment.NAS_SHARE_UNC 'j4\integration'))
        'j4/quarantine' = @(Get-NasFile -Environment $environment -Path (Join-Path $environment.NAS_SHARE_UNC 'j4\quarantine'))
    }
    foreach ($expected in @{
            'j4/finance' = 'budget_q4.csv'
            'j4/documents' = 'contract_partner_x.pdf'
            'j4/integration' = 'order_000123.xml'
            'j4/quarantine' = 'unknown_payload.dat'
        }.GetEnumerator()) {
        if ($folders[$expected.Key] -notcontains $expected.Value) {
            throw "J4 did not place '$($expected.Value)' in '$($expected.Key)'."
        }
    }
    $script:J4FileListings = $folders
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ FileListings = $script:J4FileListings }
}

function Restore {}
