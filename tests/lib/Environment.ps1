# Test settings: the azd values of the SPEC contract, from the environment or `azd env get-values`.

function Invoke-AzdGetValue {
    $output = & azd env get-values 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "azd env get-values failed: $output"
    }

    return $output
}

function ConvertFrom-AzdValue {
    param([string[]]$Lines)

    $values = @{}
    foreach ($line in $Lines) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)\s*$') {
            $name = $Matches[1]
            $value = $Matches[2]
            if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[-1] -eq '"') {
                try {
                    $value = ConvertFrom-Json -InputObject $value -ErrorAction Stop
                }
                catch {
                    throw "azd returned an invalid quoted value for '$name'."
                }
            }
            elseif ($value.Length -ge 2 -and $value[0] -eq "'" -and $value[-1] -eq "'") {
                $value = $value.Substring(1, $value.Length - 2).Replace("''", "'")
            }

            $values[$name] = [string]$value
        }
    }

    return $values
}

# The SPEC section 1 contract. SHAREPOINT_SITE_ID is not listed: it is required only when ENABLE_SHAREPOINT is true.
$script:TestEnvironmentNames = @(
    'AZURE_RESOURCE_GROUP',
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_LOCATION',
    'KEY_VAULT_NAME',
    'LOGIC_APP_NAME',
    'NAT_PUBLIC_IP',
    'PARTNER_VM_NAME',
    'PARTNER_VM_FQDN',
    'PARTNER_NSG_NAME',
    'NAS_VM_NAME',
    'NAS_SHARE_UNC',
    'WORKER_VM_NAMES',
    'SERVERS_NSG_NAME',
    'AUTOMATION_ACCOUNT_NAME',
    'HYBRID_WORKER_GROUP',
    'DATA_STORAGE_ACCOUNT_NAME',
    'LOG_ANALYTICS_WORKSPACE_ID',
    'ALERT_EMAIL',
    'DEPLOYER_IP',
    'ENABLE_SHAREPOINT'
)

function Get-RequiredTestName {
    param(
        [Parameter(Mandatory)][string[]]$RequiredNames,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $isSharePointEnabled = $Values['ENABLE_SHAREPOINT'] -eq 'true'
    if ($isSharePointEnabled -and $RequiredNames -notcontains 'SHAREPOINT_SITE_ID') {
        return @($RequiredNames) + 'SHAREPOINT_SITE_ID'
    }
    return @($RequiredNames)
}

function Add-AzdTestValue {
    # Fills only the names still missing; values already in the environment win.
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string[]]$Names
    )

    $azdValues = ConvertFrom-AzdValue -Lines @(Invoke-AzdGetValue)
    foreach ($name in $Names) {
        $isMissing = -not $Values.ContainsKey($name)
        if ($isMissing -and $azdValues.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace($azdValues[$name])) {
            $Values[$name] = $azdValues[$name]
        }
    }
}

function Get-TestEnvironment {
    param([string[]]$RequiredNames = $script:TestEnvironmentNames)

    $wantedNames = @((@($RequiredNames) + 'SHAREPOINT_SITE_ID') | Select-Object -Unique)
    $values = @{}
    foreach ($name in $wantedNames) {
        $environmentValue = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
            $values[$name] = $environmentValue
        }
    }

    $loadError = $null
    $missing = @(Get-RequiredTestName -RequiredNames $RequiredNames -Values $values | Where-Object { -not $values.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        try {
            Add-AzdTestValue -Values $values -Names $wantedNames
        }
        catch {
            $loadError = $_.Exception.Message
        }
    }

    # Checked again: ENABLE_SHAREPOINT itself may have come from azd.
    $missing = @(Get-RequiredTestName -RequiredNames $RequiredNames -Values $values | Where-Object { -not $values.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        $message = "Missing required azd environment values: $($missing -join ', ')"
        if ($loadError) {
            $message += " Could not load azd values: $loadError"
        }
        throw $message
    }

    return $values
}
