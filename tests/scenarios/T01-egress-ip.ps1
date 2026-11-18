function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {}

function GetWorkflowName { 'wf-diag-egress-ip' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "Egress diagnostic run ended with '$($Run.Status)'."
    }
    $runJson = ConvertTo-Json -InputObject $Run -Depth 100 -Compress
    if ($runJson -notmatch [regex]::Escape($script:ScenarioEnvironment.NAT_PUBLIC_IP)) {
        throw 'Egress diagnostic output did not contain NAT_PUBLIC_IP.'
    }
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = "Expected egress IP: $($script:ScenarioEnvironment.NAT_PUBLIC_IP)" }
}

function Restore {}
