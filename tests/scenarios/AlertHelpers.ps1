function Test-ScenarioAlertFired {
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][datetime]$NotBefore
    )

    # Log alerts often resolve within minutes, so resolved alerts count too. The alert names its rule by resource ID.
    $subscription = [uri]::EscapeDataString($script:ScenarioEnvironment.AZURE_SUBSCRIPTION_ID)
    $resourceGroup = [uri]::EscapeDataString($script:ScenarioEnvironment.AZURE_RESOURCE_GROUP)
    $url = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&targetResourceGroup=$resourceGroup&timeRange=1d"
    $response = (Invoke-AzCommand -Arguments @('rest', '--method', 'get', '--url', $url)) -join "`n"
    $alerts = ConvertFrom-Json -InputObject $response -AsHashtable
    $matchingAlerts = @($alerts.value | Where-Object {
        $essentials = $_.properties.essentials
        $ruleId = [string]$essentials.alertRule
        $ruleId.Split('/')[-1] -eq $RuleName -and $essentials.startDateTime -and
        ([datetime]$essentials.startDateTime).ToUniversalTime() -ge $NotBefore.ToUniversalTime()
    })
    return $matchingAlerts.Count -gt 0
}

function Wait-ScenarioAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][datetime]$NotBefore,
        # Log rules run every 5 minutes on logs ingested a few minutes late: alerts fired 15-20 minutes after the failure.
        [timespan]$Timeout = ([timespan]::FromMinutes(25)),
        [timespan]$PollInterval = ([timespan]::FromSeconds(30))
    )

    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (Test-ScenarioAlertFired -RuleName $RuleName -NotBefore $NotBefore) {
            return $true
        }
        if ($clock.Elapsed -ge $Timeout) {
            throw "Alert '$RuleName' did not fire within $Timeout."
        }
        Start-Sleep -Milliseconds ([Math]::Min($PollInterval.TotalMilliseconds, ($Timeout - $clock.Elapsed).TotalMilliseconds))
    } while ($true)
}

function Wait-ScenarioAlertIfEnabled {
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][datetime]$NotBefore
    )

    if (-not $script:IncludeAlerts) {
        return $false
    }
    return Wait-ScenarioAlert -RuleName $RuleName -NotBefore $NotBefore
}

function Get-ScenarioCorrelationId {
    param([Parameter(Mandatory)][object]$Run)

    foreach ($action in $Run.Actions) {
        $trackedProperties = $action.properties.trackedProperties
        if ($trackedProperties -is [string]) {
            try {
                $trackedProperties = ConvertFrom-Json -InputObject $trackedProperties -AsHashtable -ErrorAction Stop
            }
            catch {
                continue
            }
        }
        if ($trackedProperties.correlationId) {
            return [string]$trackedProperties.correlationId
        }
    }
    # The action list omits tracked properties; a single action's GET returns them. The workflows record them on
    # Compose actions named Track_* or Compose_summary.
    $trackingActions = @($Run.Actions | Where-Object { $_.name -like 'Track_*' -or $_.name -eq 'Compose_summary' } |
            Where-Object { $_.properties.status -eq 'Succeeded' })
    $runUrl = Get-WorkflowManagementUrl -Environment $script:ScenarioEnvironment -WorkflowName $Run.WorkflowName -RunId $Run.RunId
    foreach ($action in $trackingActions) {
        $details = Invoke-WorkflowManagementRequest -Method get -Url "$runUrl/actions/$($action.name)?api-version=$script:LogicAppsManagementApiVersion"
        $correlationId = $details.properties.trackedProperties.correlationId
        if ($correlationId) {
            return [string]$correlationId
        }
    }
    throw "Workflow '$($Run.WorkflowName)' run '$($Run.RunId)' did not expose a tracked correlationId."
}

function Get-ScenarioRunReport {
    param(
        [Parameter(Mandatory)][object]$Run,
        [Parameter(Mandatory)][string]$Job
    )

    $correlationId = Get-ScenarioCorrelationId -Run $Run
    $startedAt = ConvertTo-UtcTime -Value $Run.Run.properties.startTime
    $reportDates = @(
        $startedAt.AddDays(-1),
        $startedAt,
        $startedAt.AddDays(1)
    )
    foreach ($reportDate in $reportDates) {
        $datePrefix = $reportDate.ToString('yyyy/MM/dd')
        $blobName = "$Job/$datePrefix/$correlationId.json"
        $blobNames = @(Get-BlobFile -Environment $script:ScenarioEnvironment `
                -Container 'run-reports' -Prefix "$Job/$datePrefix/")
        if ($blobNames -notcontains $blobName) {
            continue
        }
        $bytes = Read-BlobFile -Environment $script:ScenarioEnvironment -Container 'run-reports' -BlobName $blobName
        $json = [Text.Encoding]::UTF8.GetString($bytes)
        try {
            $report = ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
        }
        catch {
            throw "Run report '$blobName' contains invalid JSON: $($_.Exception.Message)"
        }
        return [pscustomobject]@{
            BlobName = $blobName
            CorrelationId = $correlationId
            Body = $report
        }
    }
    throw "No run report blob found for '$Job' correlationId '$correlationId'."
}

function ConvertFrom-ScenarioReportDetail {
    param([Parameter(Mandatory)][object]$Report)

    $details = $Report.details
    if ($details -is [string] -and $details.TrimStart().StartsWith('{')) {
        try {
            return ConvertFrom-Json -InputObject $details -AsHashtable -ErrorAction Stop
        }
        catch {
            throw "Run report details contain invalid JSON: $($_.Exception.Message)"
        }
    }
    return $details
}
