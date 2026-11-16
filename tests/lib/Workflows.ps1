$script:LogicAppsManagementApiVersion = '2018-11-01' # VERIFY: confirm the Standard workflow management API version and URL shape.

function Invoke-AzCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az command failed: $output"
    }

    return $output
}

function Get-WorkflowManagementUrl {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$WorkflowName,
        [string]$RunId,
        [string]$TriggerName
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

    throw 'A trigger name or run ID is required.'
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

function Start-Workflow {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$WorkflowName,
        [string]$TriggerName = 'Recurrence'
    )

    $url = Get-WorkflowManagementUrl -Environment $Environment -WorkflowName $WorkflowName -TriggerName $TriggerName
    if (-not $PSCmdlet.ShouldProcess($WorkflowName, "Trigger '$TriggerName'")) {
        return
    }
    $response = Invoke-WorkflowManagementRequest -Method post -Url $url
    $runId = $response.runId
    if (-not $runId) {
        $runId = $response.name
    }
    if (-not $runId -and $response.id) {
        $runId = [uri]::UnescapeDataString(([string]$response.id).TrimEnd('/').Split('/')[-1])
    }
    if (-not $runId) {
        throw "The trigger response for '$WorkflowName' did not include a run ID."
    }

    return [pscustomobject]@{
        WorkflowName = $WorkflowName
        TriggerName = $TriggerName
        RunId = [string]$runId
    }
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
        if ($status -in @('Succeeded', 'Failed', 'Cancelled', 'TimedOut', 'Aborted', 'Faulted')) {
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
