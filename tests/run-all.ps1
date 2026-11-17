# Runs the SPEC section 8 scenarios: reset, seed, fault, trigger, wait, assert, evidence, restore; writes docs/TEST-REPORT.md.
# Exits 1 when a mandatory scenario (T01-T12, T15) fails.
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

# Each scenario file defines these steps as functions; InjectFault and GetTriggerName are optional.
$script:RequiredScenarioSteps = @('Reset', 'Seed', 'GetWorkflowName', 'Assert', 'GetEvidence', 'Restore')

function Test-ScenarioStep {
    param([Parameter(Mandatory)][string]$Name)

    return [bool](Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue)
}

function Invoke-ScenarioStep {
    # Steps may write stray output to the pipeline; only their last value is their answer.
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Arguments = @()
    )

    if (-not (Test-ScenarioStep -Name $Name)) {
        throw "Scenario must define a '$Name' function."
    }

    $output = @(& $Name @Arguments)
    if ($output.Count -eq 0) {
        return $null
    }
    return , $output[-1]
}

function Invoke-ScenarioSetup {
    foreach ($requiredStep in $script:RequiredScenarioSteps) {
        if (-not (Test-ScenarioStep -Name $requiredStep)) {
            throw "Scenario must define a '$requiredStep' function."
        }
    }

    Invoke-ScenarioStep -Name 'Reset' | Out-Null
    Invoke-ScenarioStep -Name 'Seed' | Out-Null
    if (Test-ScenarioStep -Name 'InjectFault') {
        Invoke-ScenarioStep -Name 'InjectFault' | Out-Null
    }
}

function Invoke-ScenarioWorkflow {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result
    )

    $workflowName = [string](Invoke-ScenarioStep -Name 'GetWorkflowName')
    $triggerName = 'Recurrence'
    if (Test-ScenarioStep -Name 'GetTriggerName') {
        $triggerName = [string](Invoke-ScenarioStep -Name 'GetTriggerName')
    }

    $startedRun = Start-Workflow -Environment $Environment -WorkflowName $workflowName -TriggerName $triggerName
    $Result.RunId = $startedRun.RunId
    $run = Wait-WorkflowRun -Environment $Environment -Run $startedRun
    $Result.Status = $run.Status
    $Result.Actions = $run.Actions
    $Result.TrackedProperties = $run.TrackedProperties
    return $run
}

function Get-ScenarioAssertionError {
    # Returns the reason the assertion failed, or nothing, so evidence is still collected on failure.
    param([Parameter(Mandatory)][object]$Run)

    try {
        $assertion = Invoke-ScenarioStep -Name 'Assert' -Arguments @($Run)
    }
    catch {
        return $_.Exception.Message
    }
    if ($assertion -is [bool] -and -not $assertion) {
        return 'The scenario assertion returned false.'
    }
    return $null
}

function Add-ScenarioEvidence {
    param(
        [Parameter(Mandatory)][object]$Run,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result
    )

    $evidence = Invoke-ScenarioStep -Name 'GetEvidence' -Arguments @($Run)
    if ($evidence -isnot [System.Collections.IDictionary]) {
        return
    }
    if ($evidence.Contains('FileListings')) {
        $Result.FileListings = $evidence.FileListings
    }
    if ($evidence.Contains('Details')) {
        $Result.Details = [string]$evidence.Details
    }
}

function Invoke-ScenarioRestore {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Result)

    if (-not (Test-ScenarioStep -Name 'Restore')) {
        return
    }
    try {
        Invoke-ScenarioStep -Name 'Restore' | Out-Null
    }
    catch {
        $Result.Details = ("$($Result.Details) Restore failed: $($_.Exception.Message)").Trim()
        $Result.Result = 'Failed'
    }
}

function Get-EmptyScenarioResult {
    param([Parameter(Mandatory)][string]$Name)

    return [ordered]@{
        Name = $Name
        Result = 'Failed'
        RunId = ''
        Status = ''
        Actions = @()
        TrackedProperties = @{}
        FileListings = @{}
        Details = ''
    }
}

function Invoke-OneScenario {
    # The scenario is dot-sourced here, so its step functions live only for this call
    # and cannot leak into the next scenario.
    param(
        [Parameter(Mandatory)][IO.FileInfo]$ScenarioFile,
        [Parameter(Mandatory)][hashtable]$Environment
    )

    $result = Get-EmptyScenarioResult -Name ([IO.Path]::GetFileNameWithoutExtension($ScenarioFile.Name))
    $isScenarioLoaded = $false
    try {
        . $ScenarioFile.FullName
        $isScenarioLoaded = $true
        $script:ScenarioEnvironment = $Environment

        Invoke-ScenarioSetup
        $run = Invoke-ScenarioWorkflow -Environment $Environment -Result $result
        $assertionError = Get-ScenarioAssertionError -Run $run
        Add-ScenarioEvidence -Run $run -Result $result
        if ($assertionError) {
            throw $assertionError
        }
        $result.Result = 'Passed'
    }
    catch {
        $result.Details = $_.Exception.Message
    }
    finally {
        if ($isScenarioLoaded) {
            Invoke-ScenarioRestore -Result $result
        }
    }

    return [pscustomobject]$result
}

function ConvertTo-ScenarioIdList {
    # `pwsh -File run-all.ps1 -Only T01,T02` passes one string "T01,T02", so entries are split here.
    param([string[]]$Only)

    return @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
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
        $selected = ConvertTo-ScenarioIdList -Only $Only
        $files = @($files | Where-Object {
            $selected -contains (Get-ScenarioId -Name $_.BaseName)
        })
    }
    return $files
}

function Get-ScenarioId {
    param([Parameter(Mandatory)][string]$Name)

    return ([regex]::Match($Name, '^T\d{2}')).Value
}

function Assert-RequestedScenarioFound {
    param(
        [Parameter(Mandatory)][object[]]$ScenarioFiles,
        [string[]]$Only
    )

    if (-not $Only) {
        return
    }
    $foundIds = @($ScenarioFiles | ForEach-Object { Get-ScenarioId -Name $_.BaseName })
    $missingIds = @(ConvertTo-ScenarioIdList -Only $Only | Where-Object { $foundIds -notcontains $_ })
    if ($missingIds.Count -gt 0) {
        throw "Scenario(s) not found: $($missingIds -join ', ')"
    }
}

function Get-MissingMandatoryResult {
    # A full run must cover every mandatory scenario: one without a script counts as failed.
    param([Parameter(Mandatory)][object[]]$Results)

    $ranIds = @($Results | ForEach-Object { Get-ScenarioId -Name $_.Name })
    foreach ($mandatoryId in $script:MandatoryScenarioNames) {
        if ($ranIds -contains $mandatoryId) {
            continue
        }
        $missingResult = Get-EmptyScenarioResult -Name $mandatoryId
        $missingResult.Details = 'No scenario script found for this mandatory scenario.'
        [pscustomobject]$missingResult
    }
}

function Test-MandatoryScenarioFailed {
    param([Parameter(Mandatory)][object[]]$Results)

    $mandatoryFailures = @($Results | Where-Object {
        $script:MandatoryScenarioNames -contains (Get-ScenarioId -Name $_.Name) -and $_.Result -ne 'Passed'
    })
    return $mandatoryFailures.Count -gt 0
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
        Assert-RequestedScenarioFound -ScenarioFiles $scenarioFiles -Only $Only

        $results = @(foreach ($scenarioFile in $scenarioFiles) {
            Invoke-OneScenario -ScenarioFile $scenarioFile -Environment $environment
        })
        if (-not $Only) {
            $results += @(Get-MissingMandatoryResult -Results $results)
        }

        Write-Information (Format-TestSummary -Results $results) -InformationAction Continue
        Write-TestReport -Results $results -Path $ReportPath | Out-Null
        if (Test-MandatoryScenarioFailed -Results $results) {
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
