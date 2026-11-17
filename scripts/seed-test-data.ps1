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

function Write-SeedFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Content
    )
    $path = Join-Path $Directory $Name
    if ($PSCmdlet.ShouldProcess($path, 'Write synthetic test data')) {
        [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
    }
    return $path
}

function New-SeedData {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Scenario,
        [Parameter(Mandatory)][string]$Directory
    )
    $files = [Collections.Generic.List[string]]::new()
    switch ($Scenario) {
        'j1' {
            if (-not $PSCmdlet.ShouldProcess($Directory, 'Create synthetic seed files')) { return }
            $null = $files.Add((Write-SeedFile $Directory 'invoices_20261124_001.csv' "invoiceId,partnerId,amount,currency,date`nINV-001,PARTNER-A,125.50,EUR,2026-11-24`n"))
            $null = $files.Add((Write-SeedFile $Directory 'invoices_20261124_002.csv' "invoiceId,partnerId,amount,currency,date`nINV-002,PARTNER-A,240.00,EUR,2026-11-24`n"))
            $null = $files.Add((Write-SeedFile $Directory '~lock_invoices.csv' "locked,ignored`n"))
            $largeFile = Join-Path $Directory 'large_partner_extract.csv'
            $writer = [IO.StreamWriter]::new($largeFile, $false, [Text.UTF8Encoding]::new($false))
            try {
                for ($row = 0; $row -lt 500000; $row++) {
                    $writer.WriteLine("INV-{0:D6},PARTNER-A,1.00,EUR,2026-11-24" -f $row)
                }
            }
            finally {
                $writer.Dispose()
            }
            $null = $files.Add($largeFile)
        }
        'j2' {
            if (-not $PSCmdlet.ShouldProcess($Directory, 'Create synthetic seed files')) { return }
            $null = $files.Add((Write-SeedFile $Directory 'participants_salon_2026.csv' "participantId,event`nP-001,Salon-2026`n"))
            $null = $files.Add((Write-SeedFile $Directory 'brochure_export_fr.pdf' "%PDF-1.1`n1 0 obj`n<< /Type /Catalog >>`nendobj`ntrailer`n<< /Root 1 0 R >>`n%%EOF`n"))
        }
        { $_ -in 'j3', 'j3-failure' } {
            if (-not $PSCmdlet.ShouldProcess($Directory, 'Create synthetic seed files')) { return }
            $null = $files.Add((Write-SeedFile $Directory 'payroll_extract_202611.csv' "employeeId,period,amount`nEMP-001,2026-11,100.00`n"))
            $null = $files.Add((Write-SeedFile $Directory 'hr_movements_202611.csv' "employeeId,movement`nEMP-002,transfer`n"))
            if ($Scenario -eq 'j3-failure') {
                $null = $files.Add((Write-SeedFile $Directory 'FAIL_locked_file.csv' "employeeId,trigger`nEMP-003,FAIL`n"))
            }
        }
        'j4' {
            if (-not $PSCmdlet.ShouldProcess($Directory, 'Create synthetic seed files')) { return }
            $null = $files.Add((Write-SeedFile $Directory 'budget_q4.csv' "account,amount`nA-001,100`n"))
            $null = $files.Add((Write-SeedFile $Directory 'contract_partner_x.pdf' "%PDF-1.1`n1 0 obj`n<< /Type /Catalog >>`nendobj`ntrailer`n<< /Root 1 0 R >>`n%%EOF`n"))
            $null = $files.Add((Write-SeedFile $Directory 'order_000123.xml' '<order id="000123"></order>' + "`n"))
            $null = $files.Add((Write-SeedFile $Directory 'unknown_payload.dat' "synthetic unknown payload`n"))
        }
        'j5' {
            if (-not $PSCmdlet.ShouldProcess($Directory, 'Create synthetic seed files')) { return }
            $null = $files.Add((Write-SeedFile $Directory 'folderwatch_test.txt' "synthetic folder watch input`n"))
        }
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
    $directory = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $directory
    try {
        $files = New-SeedData -Scenario $Scenario -Directory $directory
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
            $shareLiteral = ConvertTo-PowerShellLiteral $share
            $entries = foreach ($file in $files) {
                $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
                $name = [IO.Path]::GetFileName($file)
                "@{ Path = '$relativeDirectory\$name'; Content = '$encoded' }"
            }
            $remoteScript = "`$share = $shareLiteral; `$files = @($($entries -join ',')); foreach (`$file in `$files) { `$path = Join-Path `$share `$file.Path; New-Item -ItemType Directory -Force -Path (Split-Path `$path) | Out-Null; [IO.File]::WriteAllBytes(`$path, [Convert]::FromBase64String(`$file.Content)) }"
            # VERIFY: confirm the NAS VM supports RunPowerShellScript and the share is reachable by the VM agent.
            $null = Invoke-AzCli -Arguments @(
                'vm', 'run-command', 'invoke', '--resource-group', $resourceGroup, '--subscription', $subscription,
                '--name', $vmName, '--command-id', 'RunPowerShellScript', '--scripts', $remoteScript, '--output', 'none'
            )
        }
    }
    finally {
        Remove-Item -Recurse -Force $directory -ErrorAction SilentlyContinue
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($args.Count -ne 2 -or $args[0] -ne '--scenario') {
        throw "Usage: $($MyInvocation.MyCommand.Name) --scenario <j1|j2|j3|j3-failure|j4|j5>"
    }
    Invoke-SeedScenario -Scenario $args[1]
    Write-Output "Seeded scenario $($args[1])."
}
