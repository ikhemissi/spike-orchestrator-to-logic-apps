# Workflow control for the test runner: trigger, poll, read and resubmit runs through the Logic App management API.

$script:LogicAppsManagementApiVersion = '2018-11-01' # VERIFY: confirm the Standard workflow management API version and URL shape.

$script:TerminalRunStatuses = @('Succeeded', 'Failed', 'Cancelled', 'TimedOut', 'Aborted', 'Faulted', 'Skipped', 'Ignored')

function Invoke-ExternalCommand {
    # stderr goes to a file, not into the output: az and curl print warnings there,
    # which would corrupt the JSON or file listings parsed from stdout.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$InputText
    )

    $errorPath = [IO.Path]::GetTempFileName()
    try {
        if ($InputText) {
            $output = $InputText | & $Name @Arguments 2> $errorPath
        }
        else {
            $output = & $Name @Arguments 2> $errorPath
        }
        if ($LASTEXITCODE -ne 0) {
            $errorText = "$(Get-Content -LiteralPath $errorPath -Raw)".Trim()
            throw "$Name command failed with exit code $($LASTEXITCODE): $errorText"
        }
        return $output
    }
    finally {
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AzCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    return Invoke-ExternalCommand -Name 'az' -Arguments $Arguments
}

function Get-WorkflowManagementUrl {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$WorkflowName,
        [string]$RunId,
        [string]$TriggerName,
        [switch]$RunList
    )

    $subscription = [uri]::EscapeDataString($Environment.AZURE_SUBSCRIPTION_ID)
    $resourceGroup = [uri]::EscapeDataString($Environment.AZURE_RESOURCE_GROUP)
    $logicApp = [uri]::EscapeDataString($Environment.LOGIC_APP_NAME)
    $workflow = [uri]::EscapeDataString($WorkflowName)
    $baseUrl = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$logicApp/hostruntime/runtime/webhooks/workflow/api/management/workflows/$workflow"

    if ($TriggerName) {
        $trigger = [uri]::EscapeDataString($TriggerName)
        return "$baseUrl/triggers/$trigger/run?api-version=$script:LogicAppsManagementApiVersion"
    }
    if ($RunId) {
        $run = [uri]::EscapeDataString($RunId)
        return "$baseUrl/runs/$run"
    }
    if ($RunList) {
        return "$baseUrl/runs?api-version=$script:LogicAppsManagementApiVersion"
    }

    throw 'A trigger name, a run ID or -RunList is required.'
}

function Invoke-WorkflowManagementRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('get', 'post')][string]$Method,
        [Parameter(Mandatory)][string]$Url
    )

    $response = Invoke-AzCommand -Arguments @(
        'rest',
        '--method', $Method,
        '--url', $Url,
        '--headers', 'Content-Type=application/json',
        '--output', 'json'
    )
    $json = ($response -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    try {
        return ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Logic Apps management API returned invalid JSON: $($_.Exception.Message)"
    }
}

function ConvertTo-UtcTime {
    # ConvertFrom-Json turns ISO 8601 strings into DateTime values; keep both forms working.
    param([Parameter(Mandatory)][object]$Value)

    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles)
}

function Find-WorkflowRunStartedSince {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][datetime]$TriggeredAtUtc
    )

    $url = Get-WorkflowManagementUrl -Environment $Environment -WorkflowName $WorkflowName -RunList
    $response = Invoke-WorkflowManagementRequest -Method get -Url $url
    $newRuns = @($response.value | Where-Object { $_ -and $_.properties.startTime } | Where-Object {
        (ConvertTo-UtcTime -Value $_.properties.startTime) -ge $TriggeredAtUtc
    })
    if ($newRuns.Count -eq 0) {
        return $null
    }
    $newestRun = $newRuns | Sort-Object { ConvertTo-UtcTime -Value $_.properties.startTime } -Descending | Select-Object -First 1
    return [string]$newestRun.name
}

function Start-Workflow {
    # The trigger call answers 202 with an empty body and the run ID only in a header that az rest
    # does not print, so the run is found afterwards: the newest one started since the call.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$WorkflowName,
        [string]$TriggerName = 'Recurrence',
        [timespan]$StartTimeout = ([timespan]::FromMinutes(2)),
        [timespan]$PollInterval = ([timespan]::FromSeconds(5))
    )

    $url = Get-WorkflowManagementUrl -Environment $Environment -WorkflowName $WorkflowName -TriggerName $TriggerName
    if (-not $PSCmdlet.ShouldProcess($WorkflowName, "Trigger '$TriggerName'")) {
        return
    }
    $triggeredAtUtc = [datetime]::UtcNow
    Invoke-WorkflowManagementRequest -Method post -Url $url | Out-Null

    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $runId = Find-WorkflowRunStartedSince -Environment $Environment -WorkflowName $WorkflowName -TriggeredAtUtc $triggeredAtUtc
        if ($runId) {
            return [pscustomobject]@{ WorkflowName = $WorkflowName; TriggerName = $TriggerName; RunId = $runId }
        }
        if ($clock.Elapsed -ge $StartTimeout) {
            throw "Timed out after $StartTimeout waiting for a run of '$WorkflowName' started by trigger '$TriggerName'."
        }
        Start-Sleep -Milliseconds ([Math]::Min($PollInterval.TotalMilliseconds, ($StartTimeout - $clock.Elapsed).TotalMilliseconds))
    } while ($true)
}

function Get-WorkflowRun {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$RunId
    )

    $url = Get-WorkflowManagementUrl -Environment $Environment -WorkflowName $WorkflowName -RunId $RunId
    return Invoke-WorkflowManagementRequest -Method get -Url "$url`?api-version=$script:LogicAppsManagementApiVersion"
}

function Get-WorkflowRunAction {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$RunId
    )

    $url = Get-WorkflowManagementUrl -Environment $Environment -WorkflowName $WorkflowName -RunId $RunId
    $actionsUrl = "$url/actions?api-version=$script:LogicAppsManagementApiVersion"
    $response = Invoke-WorkflowManagementRequest -Method get -Url $actionsUrl
    if ($null -eq $response) {
        return @()
    }
    return @($response.value)
}

function Get-WorkflowTrackedProperty {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actions)

    $trackedProperties = @{}
    foreach ($action in $Actions) {
        $properties = $action.properties
        if ($properties.trackedProperties) {
            $trackedProperties[$action.name] = $properties.trackedProperties
        }
    }
    return $trackedProperties
}

function Wait-WorkflowRun {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][object]$Run,
        [timespan]$Timeout = ([timespan]::FromMinutes(10)),
        [timespan]$PollInterval = ([timespan]::FromSeconds(5))
    )

    if ($Timeout -le [timespan]::Zero) {
        throw 'Timeout must be greater than zero.'
    }
    if ($PollInterval -le [timespan]::Zero) {
        throw 'PollInterval must be greater than zero.'
    }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $runStatus = Get-WorkflowRun -Environment $Environment -WorkflowName $Run.WorkflowName -RunId $Run.RunId
        $status = [string]$runStatus.properties.status
        if (-not $status) {
            $status = [string]$runStatus.status
        }
        if ($status -in $script:TerminalRunStatuses) {
            $actions = @(Get-WorkflowRunAction -Environment $Environment -WorkflowName $Run.WorkflowName -RunId $Run.RunId)
            return [pscustomobject]@{
                WorkflowName = $Run.WorkflowName
                RunId = $Run.RunId
                Status = $status
                Run = $runStatus
                Actions = $actions
                TrackedProperties = Get-WorkflowTrackedProperty -Actions $actions
            }
        }

        if ($clock.Elapsed -ge $Timeout) {
            throw "Timed out after $Timeout waiting for workflow '$($Run.WorkflowName)' run '$($Run.RunId)'. Last status: '$status'."
        }
        Start-Sleep -Milliseconds ([Math]::Min($PollInterval.TotalMilliseconds, ($Timeout - $clock.Elapsed).TotalMilliseconds))
    } while ($true)
}

function Submit-WorkflowRun {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$RunId
    )

    $url = Get-WorkflowManagementUrl -Environment $Environment -WorkflowName $WorkflowName -RunId $RunId
    $url = "$url/resubmit?api-version=$script:LogicAppsManagementApiVersion"
    return Invoke-WorkflowManagementRequest -Method post -Url $url
}
