. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j3 | Out-Null
}

function GetWorkflowName { 'wf-j3-convert-onprem' }

function Assert {
    param($Run)

    $script:CorrelationEvidence = $null
    if ($Run.Status -ne 'Succeeded') {
        throw "J3 correlation-trace run ended with '$($Run.Status)'."
    }
    $correlationId = Get-ScenarioCorrelationId -Run $Run
    # VERIFY: LogicAppWorkflowRuntime and AzureDiagnostics fields follow the workbook query contract.
    $query = @"
let SelectedCorrelationId = '$correlationId';
let WorkflowRuns = LogicAppWorkflowRuntime
| where tostring(TrackedProperties.correlationId) == SelectedCorrelationId
| count;
let AutomationJobs = AzureDiagnostics
| where Category == 'JobLogs'
| where tostring(CorrelationId) == SelectedCorrelationId
| count;
print WorkflowRuns = toscalar(WorkflowRuns), AutomationJobs = toscalar(AutomationJobs)
"@
    $response = (Invoke-AzCommand -Arguments @(
        'monitor', 'log-analytics', 'query', '--workspace', $script:ScenarioEnvironment.LOG_ANALYTICS_WORKSPACE_ID,
        '--analytics-query', $query, '--output', 'json'
    )) -join "`n"
    $result = ConvertFrom-Json -InputObject $response -AsHashtable
    $table = $result.tables[0]
    $workflowColumn = @($table.columns | ForEach-Object { $_.name }).IndexOf('WorkflowRuns')
    $automationColumn = @($table.columns | ForEach-Object { $_.name }).IndexOf('AutomationJobs')
    if ($workflowColumn -lt 0 -or $automationColumn -lt 0 -or
        [int]$table.rows[0][$workflowColumn] -lt 1 -or [int]$table.rows[0][$automationColumn] -lt 1) {
        throw "Workbook query did not return both workflow and Automation evidence for '$correlationId'."
    }
    $script:CorrelationEvidence = $correlationId
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = "Log Analytics trace checked for correlationId $script:CorrelationEvidence." }
}

function Restore {}
