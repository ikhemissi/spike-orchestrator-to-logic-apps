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
            $config | & curl --config - @Arguments
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($userPointer)
        }
    }
    else {
        & curl @Arguments
    }

    if ($LASTEXITCODE -ne 0) {
        throw "curl failed with exit code $LASTEXITCODE"
    }
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

function Get-SeedDataFile {
    param([Parameter(Mandatory)][string]$Scenario)
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $testDataDirectory = Join-Path $repositoryRoot 'test-data'
    $dataJob = if ($Scenario -eq 'j3-failure') { 'j3' } else { $Scenario }
    $scenarioDirectory = Join-Path $testDataDirectory $dataJob
    $largeFile = Join-Path $scenarioDirectory 'large_partner_extract.csv'
    if ($Scenario -eq 'j1' -and -not (Test-Path -LiteralPath $largeFile)) {
        & (Join-Path $testDataDirectory 'generate-large-files.ps1')
        if (-not (Test-Path -LiteralPath $largeFile)) {
            throw "The large J1 fixture was not generated: $largeFile"
        }
    }

    $files = @(Get-ChildItem -LiteralPath $scenarioDirectory -File | Where-Object {
        $Scenario -ne 'j3' -or $_.Name -ne 'FAIL_locked_file.csv'
    } | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($files.Count -eq 0) {
        throw "No test-data files found for scenario ${Scenario}: $scenarioDirectory"
    }
    return $files
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-SeedScenario {
    param([Parameter(Mandatory)][string]$Scenario)
    if ($Scenario -notin 'j1', 'j2', 'j3', 'j3-failure', 'j4', 'j5') {
        throw "Unknown scenario: $Scenario"
    }
    $files = Get-SeedDataFile -Scenario $Scenario
    if ($Scenario -in 'j1', 'j2', 'j4') {
        $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
        $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
        $keyVault = Get-Setting KEY_VAULT_NAME
        $fqdn = Get-Setting PARTNER_VM_FQDN
        $ftpPort = Get-OptionalSetting PARTNER_FTP_PORT -DefaultValue '2121'
        $password = Invoke-AzCli -Arguments @(
            'keyvault', 'secret', 'show', '--vault-name', $keyVault, '--name', 'ftp-partner-a-password',
            '--query', 'value', '--output', 'tsv', '--subscription', $subscription
        )
        if (-not $password) {
            throw 'Key Vault returned an empty FTP password'
        }
        $ftpCredential = ConvertTo-FtpSecureString -Value "partner-a:$password"
        try {
            foreach ($file in $files) {
                Invoke-Curl -User $ftpCredential -Arguments @(
                    '--ftp-pasv', '--fail', '--silent', '--show-error',
                    '-T', $file, "ftp://$fqdn`:$ftpPort/outbound/$Scenario/"
                )
            }
        }
        finally {
            $ftpCredential.Dispose()
        }
    }
    else {
        $resourceGroup = Get-Setting AZURE_RESOURCE_GROUP
        $subscription = Get-Setting AZURE_SUBSCRIPTION_ID
        $vmName = Get-Setting NAS_VM_NAME
        $share = Get-Setting NAS_SHARE_UNC
        $relativeDirectory = if ($Scenario -in 'j3', 'j3-failure') { 'j3\in' } else { 'folderwatch\in' }

        $entries = foreach ($file in $files) {
            $fileSize = (Get-Item -LiteralPath $file).Length
            if ($fileSize -gt 262144) {
                throw "NAS file exceeds the 256 KiB Run Command limit: $file ($fileSize bytes)"
            }
            $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
            $name = [IO.Path]::GetFileName($file)
            "@{ Path = '$relativeDirectory\$name'; Content = '$encoded' }"
        }
        # On the NAS VM itself, run command runs as Local System, which has no rights on the share: write to the share's
        # local folder instead, found from the share name (the last part of NAS_SHARE_UNC).
        $shareName = ($share -split '\\')[-1]
        $shareNameLiteral = ConvertTo-PowerShellLiteral -Value $shareName
        $remoteScript = "`$ErrorActionPreference = 'Stop'; `$share = (Get-SmbShare -Name $shareNameLiteral).Path; `$files = @($($entries -join ',')); foreach (`$file in `$files) { `$path = Join-Path `$share `$file.Path; New-Item -ItemType Directory -Force -Path (Split-Path `$path) | Out-Null; [IO.File]::WriteAllBytes(`$path, [Convert]::FromBase64String(`$file.Content)) }; 'SEEDED'"
        $scriptSize = [Text.Encoding]::UTF8.GetByteCount($remoteScript)
        if ($scriptSize -gt 28672) {
            throw "NAS Run Command script exceeds the 28 KiB process argument limit after base64 encoding ($scriptSize bytes)"
        }
        # Run command reports success even when the script fails: check that the script reached its end.
        $runOutput = Invoke-AzCli -Arguments @(
            'vm', 'run-command', 'invoke', '--resource-group', $resourceGroup, '--subscription', $subscription,
            '--name', $vmName, '--command-id', 'RunPowerShellScript', '--scripts', $remoteScript,
            '--query', 'value[0].message', '--output', 'tsv'
        )
        if (-not ("$runOutput" -like '*SEEDED*')) {
            throw "Seeding the NAS failed: $runOutput"
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($args.Count -ne 2 -or $args[0] -ne '--scenario') {
        throw "Usage: $($MyInvocation.MyCommand.Name) --scenario <j1|j2|j3|j3-failure|j4|j5>"
    }
    Invoke-SeedScenario -Scenario $args[1]
    Write-Output "Seeded scenario $($args[1])."
}
