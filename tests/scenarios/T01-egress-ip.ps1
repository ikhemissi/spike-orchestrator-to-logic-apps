function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {}

function GetWorkflowName { 'wf-diag-egress-ip' }

function GetTriggerName { 'manual' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "Egress diagnostic run ended with '$($Run.Status)'."
    }
    $output = Get-WorkflowActionOutput -Environment $script:ScenarioEnvironment -WorkflowName $Run.WorkflowName -RunId $Run.RunId -ActionName 'Get_egress_IP'
    $script:EgressIp = [string]$output.body.ip
    if ($script:EgressIp -ne $script:ScenarioEnvironment.NAT_PUBLIC_IP) {
        throw "Egress IP '$($script:EgressIp)' is not NAT_PUBLIC_IP '$($script:ScenarioEnvironment.NAT_PUBLIC_IP)'."
    }
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = "Egress IP $($script:EgressIp), NAT IP $($script:ScenarioEnvironment.NAT_PUBLIC_IP)" }
}

function Restore {}
