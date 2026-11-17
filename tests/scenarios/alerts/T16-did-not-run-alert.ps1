. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {}

function Seed {}

function Set-J3WorkflowState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][ValidateSet('enable', 'disable')][string]$State)

    $workflowUrl = Get-WorkflowManagementUrl -Environment $script:ScenarioEnvironment `
        -WorkflowName 'wf-j3-convert-onprem'
    if (-not $PSCmdlet.ShouldProcess($workflowUrl, "Set workflow state to $State")) {
        return
    }
    # VERIFY: confirm the Standard workflow management API supports these enable/disable operations.
    Invoke-AzCommand -Arguments @(
        'rest', '--method', 'post', '--url', "$workflowUrl/$State`?api-version=2018-11-01"
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
    try {
        $timeout = [timespan]::FromHours([double]$deadlineHours).Add([timespan]::FromMinutes(10))
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
