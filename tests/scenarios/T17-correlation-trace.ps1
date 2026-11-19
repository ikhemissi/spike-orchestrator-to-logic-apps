. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j3 | Out-Null
}

function InjectFault {}

function GetWorkflowName { 'wf-j3-convert-onprem' }

function Get-TraceQuery {
    # The test runs the workbook's own "Trace by correlation ID" query, so the workbook is what gets tested.
    param([Parameter(Mandatory)][string]$CorrelationId)

    $workbookPath = Join-Path (Split-Path -Parent $script:TestRoot) 'infra/workbook.json'
    $workbook = Get-Content -LiteralPath $workbookPath -Raw | ConvertFrom-Json
    $query = @($workbook.items | ForEach-Object { $_.content.query } | Where-Object { $_ -like '*SelectedCorrelationId*' })[0]
    if (-not $query) {
        throw 'The workbook has no trace query by correlation ID.'
    }
    return $query.Replace('{CorrelationId}', $CorrelationId)
}

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "J3 run ended with '$($Run.Status)' instead of Succeeded."
    }
    $correlationId = Get-ScenarioCorrelationId -Run $Run
    $query = Get-TraceQuery -CorrelationId $correlationId
    # Log Analytics ingests Logic Apps and Automation logs a few minutes after the run.
    $deadline = [datetime]::UtcNow.AddMinutes(20)
    $sources = @()
    while ([datetime]::UtcNow -lt $deadline) {
        $rows = Invoke-AzCommand -Arguments @(
            'monitor', 'log-analytics', 'query', '--workspace', $script:ScenarioEnvironment.LOG_ANALYTICS_WORKSPACE_ID,
            '--analytics-query', $query, '--timespan', 'P1D', '--output', 'json'
        ) | ConvertFrom-Json
        $sources = @($rows | ForEach-Object { $_.Source } | Sort-Object -Unique)
        if ($sources -contains 'Logic Apps' -and $sources -contains 'Automation job') {
            $script:TraceRowCount = @($rows).Count
            return $true
        }
        Start-Sleep -Seconds 60
    }
    throw "The trace for correlation ID $correlationId returned only: $($sources -join ', ')."
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ Details = "The workbook trace query returned $script:TraceRowCount rows from both Logic Apps and the Automation job." }
}

function Restore {}
