function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j1 | Out-Null
}

function InjectFault {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') bad-ftp-password | Out-Null
}

function GetWorkflowName { 'wf-j1-partner-ftp-to-sftp' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Failed') {
        throw "J1 wrong-password run ended with '$($Run.Status)' instead of Failed."
    }
    $runJson = ConvertTo-Json -InputObject $Run -Depth 100 -Compress
    if ($runJson -notmatch '(?i)auth|credential|password') {
        throw 'J1 failure did not report an authentication error.'
    }
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = 'The fault is restored after the run; run history is checked for an authentication error.' }
}

function Restore {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/inject-fault.ps1') restore-all | Out-Null
}
