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

function Invoke-Curl {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Security.SecureString]$User
    )
    if ($PSBoundParameters.ContainsKey('User')) {
        $userPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($User)
        try {
            $userText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($userPointer)
            if ($userText.Contains("`n") -or $userText.Contains("`r")) {
                throw 'FTP password contains a newline'
            }
            $escapedUser = $userText.Replace('\', '\\').Replace('"', '\"')
            $config = "user = `"$escapedUser`"`n"
            $result = $config | & curl --config - @Arguments
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($userPointer)
        }
    }
    else {
        $result = & curl @Arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed with exit code $LASTEXITCODE"
    }
    return $result
}

function ConvertTo-FtpSecureString {
    param([Parameter(Mandatory)][string]$Value)
    $credential = [Security.SecureString]::new()
    foreach ($character in $Value.ToCharArray()) {
        $credential.AppendChar($character)
    }
    $credential.MakeReadOnly()
    return $credential
}

function Invoke-RestoreAllFault {
    & (Join-Path $PSScriptRoot 'inject-fault.ps1') restore-all | Out-Null
}

function Clear-FtpDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Security.SecureString]$FtpCredential,
        [Parameter(Mandatory)][string]$Fqdn
    )

    $listing = Invoke-Curl -User $FtpCredential -Arguments @(
        '--ftp-pasv', '--fail', '--silent', '--show-error',
        '--list-only', "ftp://$Fqdn/outbound/$Path/"
    )
    foreach ($entry in $listing) {
        $filename = "$entry".Trim()
        if (-not $filename) {
            continue
        }
        if ($filename -in '.', '..') {
            continue
        }
        if ($filename -notmatch '^[A-Za-z0-9._~-]+$') {
            throw "Unsafe FTP filename in $Path"
        }
        $relativePath = "$Path/$filename"
        # VERIFY: confirm the FTP server accepts absolute DELE/RMD paths and NLST directory entries.
        if ($PSCmdlet.ShouldProcess($relativePath, 'Delete FTP file')) {
            try {
                $null = Invoke-Curl -User $FtpCredential -Arguments @(
                    '--ftp-pasv', '--fail', '--silent', '--show-error',
                    '--quote', "-DELE /outbound/$relativePath", "ftp://$Fqdn/"
                )
            }
            catch {
                $parameters = @{ Path = $relativePath; FtpCredential = $FtpCredential; Fqdn = $Fqdn }
                Clear-FtpDirectory @parameters
                $null = Invoke-Curl -User $FtpCredential -Arguments @(
                    '--ftp-pasv', '--fail', '--silent', '--show-error',
                    '--quote', "-RMD /outbound/$relativePath", "ftp://$Fqdn/"
                )
            }
        }
    }
}

function Invoke-ResetEnvironment {
    Invoke-RestoreAllFault
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $keyVault = Get-Setting KEY_VAULT_NAME
    $fqdn = Get-Setting PARTNER_VM_FQDN
    $nasVmName = Get-Setting NAS_VM_NAME
    $nasShare = Get-Setting NAS_SHARE_UNC
    $storageAccount = Get-Setting DATA_STORAGE_ACCOUNT_NAME
    $password = Invoke-AzCli -Arguments @(
        'keyvault', 'secret', 'show', '--vault-name', $keyVault, '--name', 'ftp-partner-a-password',
        '--subscription', $subscription, '--query', 'value', '--output', 'tsv'
    )
    if (-not $password) {
        throw 'Key Vault returned an empty FTP password'
    }
    $ftpCredential = ConvertTo-FtpSecureString -Value "partner-a:$password"
    try {
        foreach ($directory in 'j1', 'j2', 'j4', 'archive') {
            $parameters = @{ Path = $directory; FtpCredential = $ftpCredential; Fqdn = $fqdn }
            Clear-FtpDirectory @parameters
        }
    }
    finally {
        $ftpCredential.Dispose()
    }

    $shareLiteral = "'" + $nasShare.Replace("'", "''") + "'"
    # VERIFY: confirm the NAS VM supports RunPowerShellScript and the share is reachable by the VM agent.
    $remoteScript = "`$share = $shareLiteral; @('j3','j4','folderwatch') | ForEach-Object { `$path = Join-Path `$share `$_; if (Test-Path `$path) { Remove-Item -Recurse -Force `$path } }; @('j3\in','j3\out','j3\archive','j4\finance','j4\documents','j4\integration','j4\quarantine','folderwatch\in','folderwatch\out') | ForEach-Object { New-Item -ItemType Directory -Force -Path (Join-Path `$share `$_) | Out-Null }"
    $null = Invoke-AzCli -Arguments @(
        'vm', 'run-command', 'invoke', '--resource-group', $resourceGroup, '--subscription', $subscription,
        '--name', $nasVmName, '--command-id', 'RunPowerShellScript', '--scripts', $remoteScript, '--output', 'none'
    )
    foreach ($container in 'sharepoint-sim', 'run-reports') {
        # VERIFY: the deployer identity has Storage Blob Data Contributor on the test data account.
        $null = Invoke-AzCli -Arguments @(
            'storage', 'blob', 'delete-batch', '--account-name', $storageAccount,
            '--auth-mode', 'login', '--source', $container, '--subscription', $subscription, '--output', 'none'
        )
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($args.Count -ne 0) {
        throw 'Usage: reset-environment.ps1'
    }
    Invoke-ResetEnvironment
    Write-Output 'Environment reset; all injected faults restored.'
}
