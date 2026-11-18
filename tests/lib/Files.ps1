# File checks for the test runner: partner FTP/SFTP with curl, the Windows NAS with VM Run Command, blobs with Entra sign-in.

function ConvertTo-CurlUserConfig {
    # curl config syntax: a quoted value escapes backslashes and double quotes.
    param([Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential)

    $userAndPassword = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"
    $escapedValue = $userAndPassword.Replace('\', '\\').Replace('"', '\"')
    return "user = `"$escapedValue`""
}

function Invoke-CurlCommand {
    # A password travels on stdin (--config -), never on the command line where other processes can read it.
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (-not $Credential) {
        return Invoke-ExternalCommand -Name 'curl' -Arguments $Arguments
    }
    $userConfig = ConvertTo-CurlUserConfig -Credential $Credential
    return Invoke-ExternalCommand -Name 'curl' -Arguments (@('--config', '-') + $Arguments) -InputText $userConfig
}

function Get-CurlKeyArgument {
    # Partner A (FTP) signs in with a password, passed by Invoke-CurlCommand;
    # partner B (SFTP) with an SSH key (SPEC section 3).
    param(
        [string]$UserName,
        [string]$PrivateKeyPath
    )

    if ($PrivateKeyPath) {
        # The simulated partner's host key is created when it is provisioned and is not pinned here: the tests only
        # read and clean the test folders. A real partner's host key is pinned in the SFTP connection.
        return @('--user', "$($UserName):", '--key', $PrivateKeyPath, '--insecure')
    }
    return @()
}

function Get-PartnerFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$UserName,
        [string]$PrivateKeyPath
    )

    $arguments = @('--silent', '--show-error', '--list-only')
    if ($Url -match '^ftp://') {
        $arguments += '--ftp-pasv'
    }
    $arguments += Get-CurlKeyArgument -UserName $UserName -PrivateKeyPath $PrivateKeyPath
    $arguments += $Url
    return @(Invoke-CurlCommand -Arguments $arguments -Credential $Credential | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Send-PartnerFile {
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$DestinationUrl,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$UserName,
        [string]$PrivateKeyPath
    )

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        throw "Local file not found: $LocalPath"
    }

    $arguments = @('--silent', '--show-error', '--upload-file', $LocalPath)
    $arguments += Get-CurlKeyArgument -UserName $UserName -PrivateKeyPath $PrivateKeyPath
    $arguments += $DestinationUrl
    Invoke-CurlCommand -Arguments $arguments -Credential $Credential | Out-Null
}

function Remove-PartnerFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Url,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$UserName,
        [string]$PrivateKeyPath
    )

    if (-not $PSCmdlet.ShouldProcess($Url, 'Delete remote file')) {
        return
    }

    # The delete runs as a quote command against the parent folder: on the file URL itself,
    # curl would then try to download the file it has just deleted and fail.
    # VERIFY: vsftpd and OpenSSH accept the absolute URL path (FTP URL paths are relative to the login folder).
    $fileUri = [uri]$Url
    $filePath = [uri]::UnescapeDataString($fileUri.AbsolutePath)
    $folderUrl = $Url.Substring(0, $Url.LastIndexOf('/') + 1)
    $deleteCommand = if ($fileUri.Scheme -eq 'sftp') { "rm $filePath" } else { "DELE $filePath" }

    $arguments = @('--silent', '--show-error', '--list-only', '--quote', $deleteCommand)
    $arguments += Get-CurlKeyArgument -UserName $UserName -PrivateKeyPath $PrivateKeyPath
    $arguments += $folderUrl
    Invoke-CurlCommand -Arguments $arguments -Credential $Credential | Out-Null
}

function Invoke-NasCommand {
    # vm-nas01 is Windows Server 2022 (SPEC section 3), so the commands are PowerShell.
    # VERIFY: --parameters name=value binds to the script's param() and stdout comes back in value[].message.
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Parameters = @()
    )

    $arguments = @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $Environment.AZURE_RESOURCE_GROUP,
        '--name', $Environment.NAS_VM_NAME,
        '--command-id', 'RunPowerShellScript',
        '--scripts', $Script,
        '--output', 'json'
    )
    if ($Parameters.Count -gt 0) {
        $arguments += '--parameters'
        $arguments += $Parameters
    }

    $json = ((Invoke-AzCommand -Arguments $arguments) -join "`n").Trim()
    try {
        return ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "NAS command returned invalid JSON: $($_.Exception.Message)"
    }
}

function Get-NasCommandResult {
    # The NAS scripts print one 'RESULT:<value>' line so their answer can be told apart from other output.
    param([Parameter(Mandatory)][hashtable]$Response)

    $messages = @($Response.value | ForEach-Object { $_.message }) -join "`n"
    $resultLine = $messages -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like 'RESULT:*' } | Select-Object -Last 1
    if (-not $resultLine) {
        throw "NAS command did not return a RESULT line. $messages"
    }
    return $resultLine.Substring('RESULT:'.Length)
}

function Get-NasFile {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Path
    )

    $scriptText = @'
param([string]$Path)
$names = @(Get-ChildItem -LiteralPath $Path -File | ForEach-Object { $_.Name }) -join "`n"
'RESULT:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($names))
'@
    $response = Invoke-NasCommand -Environment $Environment -Script $scriptText -Parameters @("Path=$Path")
    $encodedNames = Get-NasCommandResult -Response $response
    $names = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedNames))
    return @($names -split "`n" | Where-Object { $_ })
}

function Read-NasFile {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Path
    )

    $scriptText = @'
param([string]$Path)
'RESULT:' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
'@
    $response = Invoke-NasCommand -Environment $Environment -Script $scriptText -Parameters @("Path=$Path")
    return [Convert]::FromBase64String((Get-NasCommandResult -Response $response))
}

function Write-NasFile {
    # VERIFY: the base64 content travels on the command line, so this suits small test files only.
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Content
    )

    $scriptText = @'
param([string]$Path, [string]$ContentBase64)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
[IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($ContentBase64))
'RESULT:written'
'@
    $contentBase64 = [Convert]::ToBase64String($Content)
    $response = Invoke-NasCommand -Environment $Environment -Script $scriptText -Parameters @("Path=$Path", "ContentBase64=$contentBase64")
    if ((Get-NasCommandResult -Response $response) -ne 'written') {
        throw "NAS command did not confirm writing '$Path'."
    }
}

function Get-BlobFile {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Container,
        [string]$Prefix
    )

    $arguments = @(
        'storage', 'blob', 'list',
        '--account-name', $Environment.DATA_STORAGE_ACCOUNT_NAME,
        '--container-name', $Container,
        '--auth-mode', 'login',
        '--output', 'json'
    )
    if ($Prefix) {
        $arguments += @('--prefix', $Prefix)
    }
    $json = (Invoke-AzCommand -Arguments $arguments) -join "`n"
    return @(ConvertFrom-Json -InputObject $json -AsHashtable | ForEach-Object { $_.name })
}

function Read-BlobFile {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobName
    )

    $temporaryPath = [IO.Path]::GetTempFileName()
    try {
        Invoke-AzCommand -Arguments @(
            'storage', 'blob', 'download',
            '--account-name', $Environment.DATA_STORAGE_ACCOUNT_NAME,
            '--container-name', $Container,
            '--name', $BlobName,
            '--file', $temporaryPath,
            '--auth-mode', 'login',
            '--output', 'none'
        ) | Out-Null
        return [IO.File]::ReadAllBytes($temporaryPath)
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}
