function Test-ScenarioAlertFired {
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][datetime]$NotBefore
    )

    # VERIFY: confirm the Alerts Management API version and fired-time response fields.
    $subscription = [uri]::EscapeDataString($script:ScenarioEnvironment.AZURE_SUBSCRIPTION_ID)
    $resourceGroup = [uri]::EscapeDataString($script:ScenarioEnvironment.AZURE_RESOURCE_GROUP)
    $url = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&targetResourceGroup=$resourceGroup&monitorCondition=Fired"
    $response = (Invoke-AzCommand -Arguments @('rest', '--method', 'get', '--url', $url)) -join "`n"
    $alerts = ConvertFrom-Json -InputObject $response -AsHashtable
    $matchingAlerts = @($alerts.value | Where-Object {
        $alertRule = $_.properties.essentials.alertRule
        if (-not $alertRule) {
            $alertRule = $_.properties.alertRule
        }
        $firedAt = $_.properties.essentials.firedDateTime
        if (-not $firedAt) {
            $firedAt = $_.properties.firedDateTime
        }
        $alertRule -eq $RuleName -and $firedAt -and
        [datetime]::Parse($firedAt).ToUniversalTime() -ge $NotBefore.ToUniversalTime()
    })
    return $matchingAlerts.Count -gt 0
}

function Wait-ScenarioAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][datetime]$NotBefore,
        [timespan]$Timeout = ([timespan]::FromMinutes(10)),
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
