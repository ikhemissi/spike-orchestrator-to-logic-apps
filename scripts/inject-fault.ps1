function Get-AzdValue {
    if ($script:AzdValues) {
        return
    }
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
        throw 'azd is required to load missing settings'
    }
    $script:AzdValues = @{}
    foreach ($line in (& azd env get-values)) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') {
            $value = $Matches[2]
            if ($value.StartsWith('"') -and $value.EndsWith('"')) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $script:AzdValues[$Matches[1]] = $value
        }
    }
}

function Get-Setting {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) {
        Get-AzdValue
        $value = $script:AzdValues[$Name]
    }
    if (-not $value) {
        throw "$Name is required"
    }
    return $value
}

function Invoke-AzCli {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments)
    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments[0]) failed with exit code $LASTEXITCODE"
    }
    return $result
}

function Get-PartnerNsgRule {
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $nsgName = Get-Setting PARTNER_NSG_NAME
    $result = Invoke-AzCli -Arguments @(
        'network', 'nsg', 'rule', 'list', '--resource-group', $resourceGroup,
        '--subscription', $subscription, '--nsg-name', $nsgName, '--output', 'json'
    )
    return @($result | ConvertFrom-Json)
}

function Invoke-PartnerNsgRuleUpdate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Prefixes,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Description
    )
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $nsgName = Get-Setting PARTNER_NSG_NAME
    $arguments = @(
        'network', 'nsg', 'rule', 'update', '--resource-group', $resourceGroup,
        '--subscription', $subscription, '--nsg-name', $nsgName, '--name', $Name,
        '--source-address-prefixes'
    ) + $Prefixes + @('--description', $Description, '--output', 'none')
    # VERIFY: confirm the CLI update preserves all partner NSG rule fields not explicitly supplied here.
    $null = Invoke-AzCli -Arguments $arguments
}

function Invoke-PartnerIpBlock {
    $natAddress = Get-Setting NAT_PUBLIC_IP
    # Azure stores the address with or without its /32 suffix.
    $natForms = @($natAddress, "$natAddress/32")
    $matchingRules = foreach ($rule in (Get-PartnerNsgRule)) {
        if ($rule.name -ne 'Allow-FTP-SFTP-From-NAT-And-Deployer') {
            continue
        }
        $prefixes = if ($rule.sourceAddressPrefixes) {
            @($rule.sourceAddressPrefixes)
        }
        elseif ($rule.sourceAddressPrefix) {
            @($rule.sourceAddressPrefix)
        }
        else {
            @()
        }
        if (@($prefixes | Where-Object { $_ -in $natForms }).Count -gt 0) {
            [PSCustomObject]@{ Rule = $rule; Prefixes = $prefixes }
        }
    }
    if (@($matchingRules).Count -ne 1) {
        throw "Expected exactly one rule named Allow-FTP-SFTP-From-NAT-And-Deployer containing NAT_PUBLIC_IP; found $(@($matchingRules).Count)"
    }
    $match = @($matchingRules)[0]
    $state = @{ description = [string]$match.Rule.description; prefixes = @($match.Prefixes) } | ConvertTo-Json -Compress
    $encodedState = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($state))
    $description = "fault-restore:$encodedState"
    if ($description.Length -gt 140) {
        throw 'Partner NSG rule description is too long to store restore state'
    }
    $remaining = @($match.Prefixes | Where-Object { $_ -notin $natForms })
    if ($remaining.Count -eq 0) {
        $remaining = @('0.0.0.0/32')
    }
    Invoke-PartnerNsgRuleUpdate -Name $match.Rule.name -Prefixes $remaining -Description $description
}

function Restore-PartnerIpBlock {
    foreach ($rule in (Get-PartnerNsgRule)) {
        if (-not $rule.description -or -not $rule.description.StartsWith('fault-restore:')) {
            continue
        }
        $encodedState = $rule.description.Substring('fault-restore:'.Length)
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedState))
        $state = $json | ConvertFrom-Json
        Invoke-PartnerNsgRuleUpdate -Name $rule.name -Prefixes @($state.prefixes) -Description ([string]$state.description)
    }
}

function Invoke-PartnerService {
    param([Parameter(Mandatory)][ValidateSet('stop', 'start')][string]$Action)
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $vmName = Get-Setting PARTNER_VM_NAME
    if ($Action -eq 'stop') {
        # VERIFY: partner VM runs Linux with vsftpd; ssh is stopped with it so the partner is unavailable.
        $script = 'state=/var/tmp/fault-partner-services; if [ -e "$state" ]; then echo "partner-down state already exists" >&2; exit 1; fi; : > "$state"; if systemctl is-active --quiet vsftpd; then echo vsftpd >> "$state"; fi; if systemctl is-active --quiet ssh; then echo ssh >> "$state"; fi; systemctl stop vsftpd ssh'
    }
    else {
        # VERIFY: restore only services that were active before fault injection.
        $script = 'state=/var/tmp/fault-partner-services; if [ -f "$state" ]; then while read -r service; do systemctl start "$service"; done < "$state"; rm -f "$state"; fi'
    }
    $null = Invoke-AzCli -Arguments @(
        'vm', 'run-command', 'invoke', '--resource-group', $resourceGroup, '--subscription', $subscription,
        '--name', $vmName, '--command-id', 'RunShellScript', '--scripts', $script, '--output', 'none'
    )
}

function Invoke-NasBlock {
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $nsgName = Get-Setting SERVERS_NSG_NAME
    $logicApp = Get-Setting LOGIC_APP_NAME
    $nasVmName = Get-Setting NAS_VM_NAME
    # VERIFY: confirm Logic Apps Standard reports its VNet integration subnet through `az logicapp show`.
    $subnetId = Invoke-AzCli -Arguments @(
        'logicapp', 'show', '--resource-group', $resourceGroup, '--subscription', $subscription,
        '--name', $logicApp, '--query', 'virtualNetworkSubnetId', '--output', 'tsv'
    )
    if (-not $subnetId -or $subnetId -eq 'None') {
        throw 'Logic app has no VNet integration subnet'
    }
    # VERIFY: confirm the subnet and NAS private-address queries match this environment's Azure CLI response shape.
    $subnetPrefix = Invoke-AzCli -Arguments @(
        'network', 'vnet', 'subnet', 'show', '--ids', "$subnetId",
        '--query', 'addressPrefix', '--output', 'tsv'
    )
    $nasIp = Invoke-AzCli -Arguments @(
        'vm', 'list-ip-addresses', '--resource-group', $resourceGroup, '--subscription', $subscription,
        '--name', $nasVmName, '--query', '[0].virtualMachine.network.privateIpAddresses[0]', '--output', 'tsv'
    )
    if (-not $subnetPrefix -or $subnetPrefix -eq 'None' -or -not $nasIp -or $nasIp -eq 'None') {
        throw 'Could not resolve the Logic App subnet or NAS private IP'
    }
    $rules = Invoke-AzCli -Arguments @(
        'network', 'nsg', 'rule', 'list', '--resource-group', $resourceGroup,
        '--subscription', $subscription, '--nsg-name', $nsgName, '--output', 'json'
    ) | ConvertFrom-Json
    if (@($rules | Where-Object { $_.name -eq 'fault-nas-block' }).Count -gt 0) {
        throw 'NAS block rule already exists; restore it before injecting again'
    }
    $usedPriorities = @($rules | ForEach-Object { [int]$_.priority })
    $priority = 100
    while ($priority -le 4096 -and $usedPriorities -contains $priority) {
        $priority++
    }
    if ($priority -gt 4096) {
        throw 'No free NSG rule priority is available'
    }
    $null = Invoke-AzCli -Arguments @(
        'network', 'nsg', 'rule', 'create', '--resource-group', $resourceGroup,
        '--subscription', $subscription, '--nsg-name', $nsgName, '--name', 'fault-nas-block',
        '--priority', "$priority", '--direction', 'Inbound', '--access', 'Deny', '--protocol', 'Tcp',
        '--source-address-prefixes', "$subnetPrefix",
        '--destination-address-prefixes', "$nasIp/32", '--destination-port-ranges', '445', '--output', 'none'
    )
    Restart-NasSmbServer
}

function Restart-NasSmbServer {
    # NSGs are stateful and the platform keeps the share mounted across app restarts, so the NAS restarts its
    # SMB server, which drops the open connections (closing only the SMB sessions keeps them): the client has to
    # reconnect, and the new rule blocks that.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if (-not $PSCmdlet.ShouldProcess((Get-Setting NAS_VM_NAME), 'Restart the SMB server')) {
        return
    }
    $null = Invoke-AzCli -Arguments @(
        'vm', 'run-command', 'invoke', '--resource-group', (Get-Setting AZURE_RESOURCE_GROUP),
        '--subscription', (Get-Setting AZURE_SUBSCRIPTION_ID), '--name', (Get-Setting NAS_VM_NAME),
        '--command-id', 'RunPowerShellScript', '--scripts', 'Restart-Service -Name LanmanServer -Force', '--output', 'none'
    )
}

function Restart-LogicAppForNasMount {
    # The NAS is a file-share mount of the Logic App: after the block is lifted, the app restarts to mount it again.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if (-not $PSCmdlet.ShouldProcess((Get-Setting LOGIC_APP_NAME), 'Restart')) {
        return
    }
    $null = Invoke-AzCli -Arguments @(
        'logicapp', 'restart', '--name', (Get-Setting LOGIC_APP_NAME), '--resource-group', (Get-Setting AZURE_RESOURCE_GROUP),
        '--subscription', (Get-Setting AZURE_SUBSCRIPTION_ID), '--output', 'none'
    )
}


function Get-WorkerName {
    $workers = @((Get-Setting WORKER_VM_NAMES) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($workers.Count -eq 0) {
        throw 'WORKER_VM_NAMES is empty'
    }
    return $workers
}

function Set-WorkerRunningState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][ValidateSet('stop', 'restore')][string]$Action)
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    foreach ($worker in (Get-WorkerName)) {
        $vm = Invoke-AzCli -Arguments @(
            'vm', 'show', '--resource-group', $resourceGroup, '--subscription', $subscription,
            '--name', $worker, '--output', 'json'
        ) | ConvertFrom-Json
        if ($Action -eq 'stop') {
            $state = Invoke-AzCli -Arguments @(
                'vm', 'get-instance-view', '--resource-group', $resourceGroup, '--subscription', $subscription,
                '--name', $worker, '--query', "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]",
                '--output', 'tsv'
            )
            if ($state -eq 'PowerState/running') {
                if ($vm.tags.'fault-was-running') {
                    throw "VM $worker already has the fault-was-running tag; refusing to overwrite it"
                }
                # VERIFY: Azure resource tags persist prior power state in Azure for restore-all.
                if ($PSCmdlet.ShouldProcess($worker, 'Stop worker and save its prior state')) {
                    $null = Invoke-AzCli -Arguments @(
                        'tag', 'update', '--resource-id', $vm.id, '--operation', 'Merge',
                        '--tags', 'fault-was-running=true', '--output', 'none'
                    )
                    $null = Invoke-AzCli -Arguments @(
                        'vm', 'stop', '--resource-group', $resourceGroup, '--subscription', $subscription,
                        '--name', $worker, '--output', 'none'
                    )
                }
            }
        }
        elseif ($vm.tags.'fault-was-running' -eq 'true') {
            if ($PSCmdlet.ShouldProcess($worker, 'Restore worker to its prior running state')) {
                $null = Invoke-AzCli -Arguments @(
                    'vm', 'start', '--resource-group', $resourceGroup, '--subscription', $subscription,
                    '--name', $worker, '--output', 'none'
                )
                $null = Invoke-AzCli -Arguments @(
                    'tag', 'update', '--resource-id', $vm.id, '--operation', 'Delete',
                    '--tags', 'fault-was-running', '--output', 'none'
                )
            }
        }
    }
}

function Get-WorkerGroupUrl {
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $account = Get-Setting AUTOMATION_ACCOUNT_NAME
    $group = Get-Setting HYBRID_WORKER_GROUP
    return "https://management.azure.com/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Automation/automationAccounts/$account/hybridRunbookWorkerGroups/${group}?api-version=2024-10-23"
}

function Set-WorkerSystemAccount {
    # The worker group keeps no tags, so the run-as credential to restore is the one Terraform creates
    # (infra/automation.tf).
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][ValidateSet('inject', 'restore')][string]$Action)
    $url = Get-WorkerGroupUrl
    $credential = if ($Action -eq 'inject') { $null } else { @{ name = 'cred-svc-azauto' } }
    $body = @{ properties = @{ credential = $credential } } | ConvertTo-Json -Depth 5 -Compress
    if ($PSCmdlet.ShouldProcess($url, "Set worker credential for $Action")) {
        $null = Invoke-AzCli -Arguments @(
            'rest', '--method', 'patch', '--url', $url, '--headers', 'Content-Type=application/json',
            '--body', $body, '--output', 'none'
        )
    }
}

function Restore-NasBlock {
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $nsgName = Get-Setting SERVERS_NSG_NAME
    $rules = Invoke-AzCli -Arguments @(
        'network', 'nsg', 'rule', 'list', '--resource-group', $resourceGroup,
        '--subscription', $subscription, '--nsg-name', $nsgName, '--output', 'json'
    ) | ConvertFrom-Json
    if (@($rules | Where-Object { $_.name -eq 'fault-nas-block' }).Count -eq 0) {
        return
    }
    $null = Invoke-AzCli -Arguments @(
        'network', 'nsg', 'rule', 'delete', '--resource-group', $resourceGroup,
        '--subscription', $subscription, '--nsg-name', $nsgName, '--name', 'fault-nas-block', '--output', 'none'
    )
    Restart-LogicAppForNasMount
}

# The Logic App reads the partner password through a Key Vault reference, which it caches: changing the secret has no
# effect until the reference is resolved again. The fault points the app setting at another secret with a wrong value
# (changing a setting makes the app resolve it); restoring sets back the reference Terraform writes
# (logicapp-connections.tf).
$script:FtpPasswordSetting = 'FTP_PARTNER_A_PASSWORD'
$script:FaultSecretName = 'ftp-partner-a-password-fault'

function Set-FtpPasswordSetting {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$SecretName)
    $reference = "@Microsoft.KeyVault(VaultName=$(Get-Setting KEY_VAULT_NAME);SecretName=$SecretName)"
    if (-not $PSCmdlet.ShouldProcess((Get-Setting LOGIC_APP_NAME), "Point $script:FtpPasswordSetting at $SecretName")) {
        return
    }
    $null = Invoke-AzCli -Arguments @(
        'logicapp', 'config', 'appsettings', 'set', '--name', (Get-Setting LOGIC_APP_NAME),
        '--resource-group', (Get-Setting AZURE_RESOURCE_GROUP), '--subscription', (Get-Setting AZURE_SUBSCRIPTION_ID),
        '--settings', "$script:FtpPasswordSetting=$reference", '--output', 'none'
    )
}

function Restore-BadPassword {
    $current = Invoke-AzCli -Arguments @(
        'logicapp', 'config', 'appsettings', 'list', '--name', (Get-Setting LOGIC_APP_NAME),
        '--resource-group', (Get-Setting AZURE_RESOURCE_GROUP), '--subscription', (Get-Setting AZURE_SUBSCRIPTION_ID),
        '--query', "[?name=='$script:FtpPasswordSetting'].value | [0]", '--output', 'tsv'
    )
    if ("$current" -notlike "*$script:FaultSecretName*") {
        return
    }
    Set-FtpPasswordSetting -SecretName 'ftp-partner-a-password'
}

function Invoke-BadPassword {
    $null = Invoke-AzCli -Arguments @(
        'keyvault', 'secret', 'set', '--vault-name', (Get-Setting KEY_VAULT_NAME),
        '--subscription', (Get-Setting AZURE_SUBSCRIPTION_ID), '--name', $script:FaultSecretName,
        '--value', 'invalid-test-password', '--output', 'none'
    )
    Set-FtpPasswordSetting -SecretName $script:FaultSecretName
}

function Invoke-Fault {
    param([Parameter(Mandatory)][string]$Fault)
    switch ($Fault) {
        'partner-ip-block' { Invoke-PartnerIpBlock }
        'partner-down' { Invoke-PartnerService stop }
        'bad-ftp-password' { Invoke-BadPassword }
        'nas-block' { Invoke-NasBlock }
        'worker-stop' { Set-WorkerRunningState stop }
        'worker-system-account' { Set-WorkerSystemAccount inject }
        'restore-all' {
            Restore-PartnerIpBlock
            Invoke-PartnerService start
            Restore-BadPassword
            Restore-NasBlock
            Set-WorkerRunningState restore
            Set-WorkerSystemAccount restore
        }
        default { throw "Unknown fault: $Fault" }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    # A failed step must stop the script: restore-all would otherwise report success with a fault still in place.
    $ErrorActionPreference = 'Stop'
    if ($args.Count -ne 1) {
        throw 'Usage: inject-fault.ps1 <partner-ip-block|partner-down|bad-ftp-password|nas-block|worker-stop|worker-system-account|restore-all>'
    }
    Invoke-Fault -Fault $args[0]
    Write-Output "Applied fault $($args[0])."
}
