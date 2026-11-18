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

function Get-OptionalSetting {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DefaultValue
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value -and (Get-Command azd -ErrorAction SilentlyContinue)) {
        Get-AzdValue
        $value = $script:AzdValues[$Name]
    }
    if (-not $value) {
        return $DefaultValue
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
        [Parameter(Mandatory)][string]$Fqdn,
        [Parameter(Mandatory)][string]$FtpPort
    )

    $listing = Invoke-Curl -User $FtpCredential -Arguments @(
        '--ftp-pasv', '--fail', '--silent', '--show-error',
        '--list-only', "ftp://$Fqdn`:$FtpPort/outbound/$Path/"
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
                    '--quote', "-DELE /outbound/$relativePath", "ftp://$Fqdn`:$FtpPort/"
                )
            }
            catch {
                $parameters = @{ Path = $relativePath; FtpCredential = $FtpCredential; Fqdn = $Fqdn; FtpPort = $FtpPort }
                Clear-FtpDirectory @parameters
                $null = Invoke-Curl -User $FtpCredential -Arguments @(
                    '--ftp-pasv', '--fail', '--silent', '--show-error',
                    '--quote', "-RMD /outbound/$relativePath", "ftp://$Fqdn`:$FtpPort/"
                )
            }
        }
    }
}

function Invoke-SftpCleanup {
    param(
        [Parameter(Mandatory)][string]$Fqdn,
        [Parameter(Mandatory)][string]$SftpPort,
        [Parameter(Mandatory)][string]$KeyVault,
        [Parameter(Mandatory)][string]$Subscription
    )

    $privateKey = Invoke-AzCli -Arguments @(
        'keyvault', 'secret', 'show', '--vault-name', $KeyVault, '--name', 'sftp-partner-b-private-key',
        '--subscription', $Subscription, '--query', 'value', '--output', 'tsv'
    )
    if (-not $privateKey) {
        throw 'Key Vault returned an empty SFTP private key'
    }

    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    $keyPath = Join-Path $temporaryDirectory 'sftp-key'
    $null = New-Item -ItemType Directory -Path $temporaryDirectory
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
        [IO.File]::WriteAllText($keyPath, (@($privateKey) -join [Environment]::NewLine))
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($keyPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $url = "sftp://$Fqdn`:$SftpPort/inbound/"
        # The simulated partner's SSH host key is not pinned.
        $listing = Invoke-Curl -Arguments @(
            '--insecure', '--key', $keyPath, '--user', 'partner-b:', '--fail', '--silent', '--show-error',
            '--list-only', $url
        )
        foreach ($entry in $listing) {
            $filename = "$entry".Trim()
            if (-not $filename -or $filename -in '.', '..') {
                continue
            }
            if ($filename -notmatch '^[A-Za-z0-9._~-]+$') {
                throw 'Unsafe SFTP filename in /inbound'
            }
            # VERIFY: confirm the SFTP server accepts absolute rm paths and --list-only returns file names.
            $null = Invoke-Curl -Arguments @(
                '--insecure', '--key', $keyPath, '--user', 'partner-b:', '--fail', '--silent', '--show-error',
                '--quote', "rm /inbound/$filename", "sftp://$Fqdn`:$SftpPort/"
            )
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ResetEnvironment {
    Invoke-RestoreAllFault
    $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
    $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
    $keyVault = Get-Setting KEY_VAULT_NAME
    $fqdn = Get-Setting PARTNER_VM_FQDN
    $ftpPort = Get-OptionalSetting PARTNER_FTP_PORT -DefaultValue '2121'
    $sftpPort = Get-OptionalSetting PARTNER_SFTP_PORT -DefaultValue '2222'
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
            $parameters = @{ Path = $directory; FtpCredential = $ftpCredential; Fqdn = $fqdn; FtpPort = $ftpPort }
            Clear-FtpDirectory @parameters
        }
    }
    finally {
        $ftpCredential.Dispose()
    }

    Invoke-SftpCleanup -Fqdn $fqdn -SftpPort $sftpPort -KeyVault $keyVault -Subscription $subscription

    # VERIFY: confirm the NAS VM supports RunPowerShellScript and the share name resolves to its local folder.
    $shareName = ($nasShare -split '\\')[-1]
    $shareNameLiteral = "'" + $shareName.Replace("'", "''") + "'"
    $remoteScript = "`$ErrorActionPreference = 'Stop'; `$share = (Get-SmbShare -Name $shareNameLiteral).Path; if (-not `$share) { throw 'NAS share path was not found' }; @('j3\in','j3\out','j3\archive','j4\finance','j4\documents','j4\integration','j4\quarantine','folderwatch\in','folderwatch\processed') | ForEach-Object { `$path = Join-Path `$share `$_; Get-ChildItem -LiteralPath `$path -Force | Remove-Item -Recurse -Force }; 'NAS_RESET_COMPLETE'"
    $nasOutput = Invoke-AzCli -Arguments @(
        'vm', 'run-command', 'invoke', '--resource-group', $resourceGroup, '--subscription', $subscription,
        '--name', $nasVmName, '--command-id', 'RunPowerShellScript', '--scripts', $remoteScript,
        '--query', 'value[0].message', '--output', 'tsv'
    )
    if ("$nasOutput" -notlike '*NAS_RESET_COMPLETE*') {
        throw "Resetting the NAS failed: $nasOutput"
    }
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
