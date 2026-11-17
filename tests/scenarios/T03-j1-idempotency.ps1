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
    $runJson = ConvertTo-Json -InputObject $Run -Depth 100 -Compress
    if ($runJson -notmatch '"filesSkipped"\s*:\s*3') {
        throw 'J1 did not report three skipped duplicate files.'
    }
    if ($runJson -notmatch '"filesProcessed"\s*:\s*0') {
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
