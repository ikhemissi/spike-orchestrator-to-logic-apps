. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {}

function Seed {}

function Set-J3WorkflowState {
    # Logic Apps Standard disables a workflow through its FlowState app setting (as scripts/pause-environment does).
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][ValidateSet('enable', 'disable')][string]$State)

    $environment = $script:ScenarioEnvironment
    $flowState = if ($State -eq 'enable') { 'Enabled' } else { 'Disabled' }
    if (-not $PSCmdlet.ShouldProcess($environment.LOGIC_APP_NAME, "Set wf-j3-convert-onprem to $flowState")) {
        return
    }
    Invoke-AzCommand -Arguments @(
        'logicapp', 'config', 'appsettings', 'set', '--name', $environment.LOGIC_APP_NAME,
        '--resource-group', $environment.AZURE_RESOURCE_GROUP, '--subscription', $environment.AZURE_SUBSCRIPTION_ID,
        '--settings', "Workflows.wf-j3-convert-onprem.FlowState=$flowState", '--output', 'none'
    ) | Out-Null
}

function InjectFault {
    $script:DeadlineAlertFired = $false
    $script:AlertStartTime = [datetime]::UtcNow
    $deadlineHours = [Environment]::GetEnvironmentVariable('CRITICAL_JOB_DEADLINE_HOURS')
    if (-not $deadlineHours) {
        $deadlineHours = 1
    }
    Set-J3WorkflowState -State disable
    $timeout = [timespan]::FromHours([double]$deadlineHours).Add([timespan]::FromMinutes(10))
    try {
        $script:DeadlineAlertFired = Wait-ScenarioAlert -RuleName 'alert-critical-job-did-not-succeed-by-deadline' `
            -NotBefore $script:AlertStartTime -Timeout $timeout
    }
    finally {
        Set-J3WorkflowState -State enable
    }
}

function GetWorkflowName { 'wf-j3-convert-onprem' }

function Assert {
    param($Run)

    $null = $Run
    if (-not $script:DeadlineAlertFired) {
        throw 'The critical-job did-not-succeed-by-deadline alert was not observed.'
    }
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = 'Observed alert-critical-job-did-not-succeed-by-deadline after disabling J3 for the alert window.' }
}

function Restore {
    Set-J3WorkflowState -State enable
}
