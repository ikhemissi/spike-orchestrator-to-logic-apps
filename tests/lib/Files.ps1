function Invoke-CurlCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & curl @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "curl command failed: $output"
    }

    return $output
}

function Get-PartnerFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [System.Management.Automation.PSCredential]$Credential
    )

    $arguments = @('--silent', '--show-error', '--list-only')
    if ($Url -match '^ftp://') {
        $arguments += '--ftp-pasv'
    }
    if ($Credential) {
        $arguments += @('--user', "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    }
    $arguments += $Url
    return @(Invoke-CurlCommand -Arguments $arguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Send-PartnerFile {
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$DestinationUrl,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        throw "Local file not found: $LocalPath"
    }

    $arguments = @('--silent', '--show-error', '--upload-file', $LocalPath)
    if ($Credential) {
        $arguments += @('--user', "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    }
    $arguments += $DestinationUrl
    Invoke-CurlCommand -Arguments $arguments | Out-Null
}

function Remove-PartnerFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Url,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (-not $PSCmdlet.ShouldProcess($Url, 'Delete remote file')) {
        return
    }

    $arguments = @('--silent', '--show-error')
    if ($Credential) {
        $arguments += @('--user', "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
    }
    if ($Url -match '^sftp://') {
        $arguments += @('--quote', "rm $([uri]::UnescapeDataString(([uri]$Url).AbsolutePath))")
    }
    else {
        $arguments += @('--quote', "DELE $([uri]::UnescapeDataString(([uri]$Url).AbsolutePath))")
    }
    $arguments += $Url
    Invoke-CurlCommand -Arguments $arguments | Out-Null
}

function Invoke-NasCommand {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Parameters = @()
    )

    # VERIFY: confirm Linux Run Command parameter passing and output envelope for the selected NAS VM image.
    $arguments = @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $Environment.AZURE_RESOURCE_GROUP,
        '--name', $Environment.NAS_VM_NAME,
        '--command-id', 'RunShellScript',
        '--scripts', $Script,
        '--output', 'json'
    )
    if ($Parameters.Count -gt 0) {
        $arguments += '--parameters'
        $arguments += $Parameters
    }

    $response = Invoke-AzCommand -Arguments $arguments
    $json = ($response -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        return ''
    }
    try {
        return ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "NAS command returned invalid JSON: $($_.Exception.Message)"
    }
}

function Get-NasCommandResult {
    param([Parameter(Mandatory)][hashtable]$Response)

    $messages = @($Response.value | ForEach-Object { $_.message })
    $resultLine = $messages -split "`n" | Where-Object { $_ -match '^RESULT:' } | Select-Object -Last 1
    if (-not $resultLine) {
        throw "NAS command did not return a RESULT line. $($messages -join "`n")"
    }
    return [string]$resultLine.Substring(7).Trim()
}

function Get-NasFile {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Path
    )

    $scriptText = 'set -eu; printf "RESULT:"; find "$1" -maxdepth 1 -type f -printf "%f\n" | base64 -w0; printf "\n"'
    $response = Invoke-NasCommand -Environment $Environment -Script $scriptText -Parameters @("path=$Path")
    $encoded = Get-NasCommandResult -Response $response
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    return @($decoded -split "`n" | Where-Object { $_ })
}

function Read-NasFile {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Path
    )

    $scriptText = 'set -eu; printf "RESULT:"; base64 -w0 "$1"; printf "\n"'
    $response = Invoke-NasCommand -Environment $Environment -Script $scriptText -Parameters @("path=$Path")
    $encoded = Get-NasCommandResult -Response $response
    return [Convert]::FromBase64String($encoded)
}

function Write-NasFile {
    param(
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Content
    )

    $contentBase64 = [Convert]::ToBase64String($Content)
    $scriptText = 'set -eu; mkdir -p "$(dirname "$1")"; printf "%s" "$2" | base64 -d > "$1"; printf "RESULT:written\n"'
    $response = Invoke-NasCommand -Environment $Environment -Script $scriptText -Parameters @("path=$Path", "content=$contentBase64")
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
    $response = Invoke-AzCommand -Arguments $arguments
    return @((($response -join "`n") | ConvertFrom-Json -AsHashtable).name)
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
