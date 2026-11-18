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
    param([Parameter(Mandatory)][string[]]$Arguments)
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
        [Parameter(Mandatory)][string]$Description
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
        if ($prefixes -contains $natAddress) {
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
    $remaining = @($match.Prefixes | Where-Object { $_ -ne $natAddress })
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
        '--name', $logicApp, '--query', 'properties.virtualNetworkSubnetId', '--output', 'tsv'
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
        '--source-address-prefixes', "$subnetPrefix", '--source-port-ranges', '*',
        '--destination-address-prefixes', "$nasIp/32", '--destination-port-ranges', '445', '--output', 'none'
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
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][ValidateSet('inject', 'restore')][string]$Action)
    $url = Get-WorkerGroupUrl
    # VERIFY: confirm the Hybrid Worker Group API version and `properties.credential` patch semantics before Azure use.
    $document = Invoke-AzCli -Arguments @('rest', '--method', 'get', '--url', $url) | ConvertFrom-Json
    $tags = @{}
    if ($document.tags) {
        foreach ($property in $document.tags.PSObject.Properties) {
            $tags[$property.Name] = $property.Value
        }
    }
    $properties = @{}
    if ($Action -eq 'inject') {
        if ($tags.ContainsKey('fault-original-credential')) {
            throw 'Worker system-account fault is already active'
        }
        if (-not $document.properties.credential.name) {
            throw 'Worker group has no custom credential to restore'
        }
        $tags['fault-original-credential'] = $document.properties.credential.name
        $properties.credential = $null
    }
    else {
        if (-not $tags.ContainsKey('fault-original-credential')) {
            return
        }
        $properties.credential = @{ name = $tags['fault-original-credential'] }
        $tags.Remove('fault-original-credential')
    }
    $body = @{ properties = $properties; tags = $tags } | ConvertTo-Json -Depth 10 -Compress
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
}

function Set-FtpPasswordSecret {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][SecureString]$Secret)
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $temporaryDirectory
    $secretPointer = [IntPtr]::Zero
    try {
        if ($IsWindows) {
            $acl = Get-Acl -Path $temporaryDirectory
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($accessRule in @($acl.Access)) {
                $acl.RemoveAccessRuleAll($accessRule)
            }
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $privateRule = [Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
            )
            $acl.AddAccessRule($privateRule)
            Set-Acl -Path $temporaryDirectory -AclObject $acl
        }
        else {
            [IO.File]::SetUnixFileMode(
                $temporaryDirectory,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute
            )
        }
        $secretFile = Join-Path $temporaryDirectory 'value'
        $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        $secretText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
        [IO.File]::WriteAllText($secretFile, $secretText, [Text.UTF8Encoding]::new($false))
        $secretText = $null
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode(
                $secretFile,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
            )
        }
        # VERIFY: confirm az keyvault secret set --file reads the secret value from a protected temporary file.
        $keyVault = Get-Setting KEY_VAULT_NAME
        $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
        if ($PSCmdlet.ShouldProcess('Key Vault', 'Restore the partner FTP password')) {
            $null = Invoke-AzCli -Arguments @(
                'keyvault', 'secret', 'set', '--vault-name', $keyVault, '--subscription', $subscription,
                '--name', 'ftp-partner-a-password', '--file', $secretFile, '--output', 'none'
            )
        }
    }
    finally {
        $secretText = $null
        if ($secretPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
        }
        Remove-Item -Recurse -Force $temporaryDirectory -ErrorAction SilentlyContinue
    }
}

function Restore-BadPassword {
    $keyVault = Get-Setting KEY_VAULT_NAME
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $version = Invoke-AzCli -Arguments @(
        'keyvault', 'secret', 'show', '--vault-name', $keyVault, '--subscription', $subscription,
        '--name', 'ftp-partner-a-password', '--query', 'tags.fault-restore-version', '--output', 'tsv'
    )
    if (-not $version -or $version -eq 'None') {
        return
    }
    $password = Invoke-AzCli -Arguments @(
        'keyvault', 'secret', 'show', '--vault-name', $keyVault, '--subscription', $subscription,
        '--name', 'ftp-partner-a-password', '--version', $version, '--query', 'value', '--output', 'tsv'
    )
    $securePassword = [Security.SecureString]::new()
    foreach ($character in "$password".ToCharArray()) {
        $securePassword.AppendChar($character)
    }
    $securePassword.MakeReadOnly()
    $secretArguments = @{ Secret = $securePassword }
    try {
        Set-FtpPasswordSecret @secretArguments
    }
    finally {
        $securePassword.Dispose()
    }
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $logicApp = Get-Setting LOGIC_APP_NAME
    # VERIFY: confirm the Logic Apps Standard restart command is available in the deployed az CLI.
    $null = Invoke-AzCli -Arguments @(
        'logicapp', 'restart', '--name', $logicApp, '--resource-group', $resourceGroup,
        '--subscription', $subscription, '--output', 'none'
    )
}

function Invoke-BadPassword {
    $keyVault = Get-Setting KEY_VAULT_NAME
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $existingRestoreVersion = Invoke-AzCli -Arguments @(
        'keyvault', 'secret', 'show', '--vault-name', $keyVault, '--subscription', $subscription,
        '--name', 'ftp-partner-a-password', '--query', 'tags.fault-restore-version', '--output', 'tsv'
    )
    if ($existingRestoreVersion -and $existingRestoreVersion -ne 'None') {
        throw 'Bad FTP password fault is already active; restore it first'
    }
    $currentId = Invoke-AzCli -Arguments @(
        'keyvault', 'secret', 'show', '--vault-name', $keyVault, '--subscription', $subscription,
        '--name', 'ftp-partner-a-password', '--query', 'id', '--output', 'tsv'
    )
    $currentVersion = ($currentId -split '/')[-1]
    # VERIFY: secret version tags are supported by the deployed Key Vault CLI/API.
    $null = Invoke-AzCli -Arguments @(
        'keyvault', 'secret', 'set', '--vault-name', $keyVault, '--subscription', $subscription,
        '--name', 'ftp-partner-a-password', '--value', 'invalid-test-password',
        '--tags', "fault-restore-version=$currentVersion", '--output', 'none'
    )
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $logicApp = Get-Setting LOGIC_APP_NAME
    # VERIFY: confirm the Logic Apps Standard restart command is available in the deployed az CLI.
    $null = Invoke-AzCli -Arguments @(
        'logicapp', 'restart', '--name', $logicApp, '--resource-group', $resourceGroup,
        '--subscription', $subscription, '--output', 'none'
    )
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
    if ($args.Count -ne 1) {
        throw 'Usage: inject-fault.ps1 <partner-ip-block|partner-down|bad-ftp-password|nas-block|worker-stop|worker-system-account|restore-all>'
    }
    Invoke-Fault -Fault $args[0]
    Write-Output "Applied fault $($args[0])."
}
