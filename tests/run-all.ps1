param(
    [string[]]$Only,
    [switch]$IncludeAlerts
)

$script:TestRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib/Environment.ps1')
. (Join-Path $PSScriptRoot 'lib/Workflows.ps1')
. (Join-Path $PSScriptRoot 'lib/Files.ps1')
. (Join-Path $PSScriptRoot 'lib/Report.ps1')

$script:MandatoryScenarioNames = @(
    'T01', 'T02', 'T03', 'T04', 'T05', 'T06',
    'T07', 'T08', 'T09', 'T10', 'T11', 'T12', 'T15'
)

function Invoke-ScenarioStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Arguments = @()
    )

    $step = Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue
    if (-not $step) {
        throw "Scenario must define a '$Name' function."
    }

    $output = & $step.Name @Arguments
    if ($output -is [System.Collections.IDictionary]) {
        return $output
    }
    if ($output -is [array]) {
        if ($output.Count -gt 0) {
            return $output[-1]
        }
        return
    }
    if ($output.Count -gt 0) {
        return $output
    }
}

function Invoke-OneScenario {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$ScenarioFile,
        [Parameter(Mandatory)][hashtable]$Environment
    )

    $scenarioName = [IO.Path]::GetFileNameWithoutExtension($ScenarioFile.Name)
    $result = [ordered]@{
        Name = $scenarioName
        Result = 'Failed'
        RunId = ''
        Status = ''
        Actions = @()
        TrackedProperties = @{}
        FileListings = @{}
        Details = ''
    }
    $run = $null
    $scenarioLoaded = $false

    try {
        . $ScenarioFile.FullName
        $scenarioLoaded = $true
        $script:ScenarioEnvironment = $Environment

        foreach ($requiredStep in @('Reset', 'Seed', 'GetWorkflowName', 'Assert', 'GetEvidence', 'Restore')) {
            if (-not (Get-Command -Name $requiredStep -CommandType Function -ErrorAction SilentlyContinue)) {
                throw "Scenario must define a '$requiredStep' function."
            }
        }

        Invoke-ScenarioStep -Name 'Reset' | Out-Null
        Invoke-ScenarioStep -Name 'Seed' | Out-Null
        if (Get-Command -Name 'InjectFault' -CommandType Function -ErrorAction SilentlyContinue) {
            Invoke-ScenarioStep -Name 'InjectFault' | Out-Null
        }

        $workflowName = [string](Invoke-ScenarioStep -Name 'GetWorkflowName')
        $triggerName = 'Recurrence'
        if (Get-Command -Name 'GetTriggerName' -CommandType Function -ErrorAction SilentlyContinue) {
            $triggerName = [string](Invoke-ScenarioStep -Name 'GetTriggerName')
        }
        $startedRun = Start-Workflow -Environment $Environment -WorkflowName $workflowName -TriggerName $triggerName
        $result.RunId = $startedRun.RunId
        $run = Wait-WorkflowRun -Environment $Environment -Run $startedRun
        $result.Status = $run.Status
        $result.Actions = $run.Actions
        $result.TrackedProperties = $run.TrackedProperties

        $assertionError = $null
        try {
            $assertion = Invoke-ScenarioStep -Name 'Assert' -Arguments @($run)
            if ($assertion -is [bool] -and -not $assertion) {
                $assertionError = 'The scenario assertion returned false.'
            }
        }
        catch {
            $assertionError = $_.Exception.Message
        }

        $evidence = Invoke-ScenarioStep -Name 'GetEvidence' -Arguments @($run)
        if ($evidence -is [System.Collections.IDictionary]) {
            if ($evidence.Contains('FileListings')) {
                $result.FileListings = $evidence.FileListings
            }
            if ($evidence.Contains('Details')) {
                $result.Details = [string]$evidence.Details
            }
        }
        if ($assertionError) {
            throw $assertionError
        }
        $result.Result = 'Passed'
    }
    catch {
        $result.Details = $_.Exception.Message
        if ($run) {
            $result.Status = $run.Status
        }
    }
    finally {
        if ($scenarioLoaded -and (Get-Command -Name 'Restore' -CommandType Function -ErrorAction SilentlyContinue)) {
            try {
                Invoke-ScenarioStep -Name 'Restore' | Out-Null
            }
            catch {
                if ($result.Details) {
                    $result.Details += " Restore failed: $($_.Exception.Message)"
                }
                else {
                    $result.Details = "Restore failed: $($_.Exception.Message)"
                }
                $result.Result = 'Failed'
            }
        }
    }

    return [pscustomobject]$result
}

function Get-TestScenarioFile {
    param(
        [Parameter(Mandatory)][string]$ScenarioRoot,
        [switch]$IncludeAlerts,
        [string[]]$Only
    )

    $files = @()
    if (Test-Path -LiteralPath $ScenarioRoot -PathType Container) {
        $files += @(Get-ChildItem -LiteralPath $ScenarioRoot -Filter 'T*.ps1' -File | Sort-Object Name)
    }
    if ($IncludeAlerts) {
        $alertRoot = Join-Path $ScenarioRoot 'alerts'
        if (Test-Path -LiteralPath $alertRoot -PathType Container) {
            $files += @(Get-ChildItem -LiteralPath $alertRoot -Filter 'T*.ps1' -File | Sort-Object Name)
        }
    }
    if ($Only) {
        $selected = @($Only | ForEach-Object { $_.Trim().ToUpperInvariant() })
        $files = @($files | Where-Object {
            $scenarioId = ([regex]::Match($_.BaseName, '^T\d{2}')).Value
            $selected -contains $scenarioId
        })
    }
    return $files
}

function Invoke-TestRunner {
    param(
        [string[]]$Only,
        [switch]$IncludeAlerts,
        [string]$ScenarioRoot = (Join-Path $script:TestRoot 'scenarios'),
        [string]$ReportPath = (Join-Path (Split-Path -Parent $script:TestRoot) 'docs/TEST-REPORT.md'),
        [string[]]$RequiredEnvironmentNames = $null
    )

    try {
        if ($RequiredEnvironmentNames) {
            $environment = Get-TestEnvironment -RequiredNames $RequiredEnvironmentNames
        }
        else {
            $environment = Get-TestEnvironment
        }
        $scenarioFiles = @(Get-TestScenarioFile -ScenarioRoot $ScenarioRoot -IncludeAlerts:$IncludeAlerts -Only $Only)
        if ($scenarioFiles.Count -eq 0) {
            throw 'No scenario scripts matched the requested selection.'
        }
        if ($Only) {
            $found = @($scenarioFiles | ForEach-Object { ([regex]::Match($_.BaseName, '^T\d{2}')).Value })
            $missing = @($Only | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $found -notcontains $_ })
            if ($missing.Count -gt 0) {
                throw "Scenario(s) not found: $($missing -join ', ')"
            }
        }

        $results = @()
        foreach ($scenarioFile in $scenarioFiles) {
            $results += Invoke-OneScenario -ScenarioFile $scenarioFile -Environment $environment
        }

        $report = Format-TestSummary -Results $results
        Write-Information $report -InformationAction Continue
        Write-TestReport -Results $results -Path $ReportPath | Out-Null

        $mandatoryFailures = @($results | Where-Object {
            $scenarioId = ([regex]::Match($_.Name, '^T\d{2}')).Value
            $script:MandatoryScenarioNames -contains $scenarioId -and $_.Result -ne 'Passed'
        })
        if ($mandatoryFailures.Count -gt 0) {
            return 1
        }
        return 0
    }
    catch {
        Write-Error $_.Exception.Message
        return 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = Invoke-TestRunner -Only $Only -IncludeAlerts:$IncludeAlerts
    exit $exitCode
}
