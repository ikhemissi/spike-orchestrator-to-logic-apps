. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j1 | Out-Null
}

function GetWorkflowName { 'wf-j1-partner-ftp-to-sftp' }

function Get-RemoteFileSize {
    param(
        [Parameter(Mandatory)][string]$Url,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$UserName,
        [string]$PrivateKeyPath
    )

    $nullDevice = if ($IsWindows) { 'NUL' } else { '/dev/null' }
    $arguments = @('--silent', '--show-error', '--write-out', '%{size_download}', '--output', $nullDevice)
    if ($Url -match '^ftp://') {
        $arguments += '--ftp-pasv'
    }
    $arguments += Get-CurlKeyArgument -UserName $UserName -PrivateKeyPath $PrivateKeyPath
    $arguments += $Url
    $size = (Invoke-CurlCommand -Arguments $arguments -Credential $Credential) -join ''
    if ($size -notmatch '^\d+$') {
        throw "Partner file transfer did not return a byte count for '$Url'."
    }
    return [long]$size
}

function Get-PartnerBListing {
    $environment = $script:ScenarioEnvironment
    $port = $environment.PARTNER_SFTP_PORT
    $key = (Invoke-AzCommand -Arguments @(
        'keyvault', 'secret', 'show', '--vault-name', $environment.KEY_VAULT_NAME,
        '--name', 'sftp-partner-b-private-key', '--subscription', $environment.AZURE_SUBSCRIPTION_ID,
        '--query', 'value', '--output', 'tsv'
    )) -join "`n"
    $keyPath = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($keyPath, $key)
        if ($IsLinux) {
            [IO.File]::SetUnixFileMode($keyPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $files = @(Get-PartnerFile -Url "sftp://$($environment.PARTNER_VM_FQDN):$port/inbound/" `
                -UserName 'partner-b' -PrivateKeyPath $keyPath)
        $sizes = @{}
        foreach ($fileName in @('invoices_20261124_001.csv', 'invoices_20261124_002.csv', 'large_partner_extract.csv')) {
            $url = "sftp://$($environment.PARTNER_VM_FQDN):$port/inbound/$fileName"
            $sizes[$fileName] = Get-RemoteFileSize -Url $url -UserName 'partner-b' -PrivateKeyPath $keyPath
        }
        return @{ Files = $files; Sizes = $sizes }
    }
    finally {
        Remove-Item -LiteralPath $keyPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-PartnerAArchiveListing {
    $environment = $script:ScenarioEnvironment
    $port = $environment.PARTNER_FTP_PORT
    $password = (Invoke-AzCommand -Arguments @(
        'keyvault', 'secret', 'show', '--vault-name', $environment.KEY_VAULT_NAME,
        '--name', 'ftp-partner-a-password', '--subscription', $environment.AZURE_SUBSCRIPTION_ID,
        '--query', 'value', '--output', 'tsv'
    )) -join "`n"
    $securePassword = [System.Security.SecureString]::new()
    foreach ($character in $password.ToCharArray()) {
        $securePassword.AppendChar($character)
    }
    $securePassword.MakeReadOnly()
    $credential = [System.Management.Automation.PSCredential]::new('partner-a', $securePassword)
    try {
        return @(Get-PartnerFile -Url "ftp://$($environment.PARTNER_VM_FQDN):$port/outbound/archive/" `
                -Credential $credential)
    }
    finally {
        $securePassword.Dispose()
    }
}

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "J1 run ended with '$($Run.Status)'."
    }
    $runReport = Get-ScenarioRunReport -Run $Run -Job 'J1'
    $report = $runReport.Body
    $details = ConvertFrom-ScenarioReportDetail -Report $report
    if ([int]$report.filesProcessed -ne 3) {
        throw 'J1 did not report three delivered CSV files.'
    }
    if (@($details.files | Where-Object { $_.name -like '~lock_*' }).Count -gt 0) {
        throw 'J1 included the locked file in its output.'
    }
    $partnerB = Get-PartnerBListing
    $script:J1PartnerBFiles = @($partnerB.Files)
    $sourceFiles = @('invoices_20261124_001.csv', 'invoices_20261124_002.csv', 'large_partner_extract.csv')
    $repositoryRoot = Split-Path -Parent $script:TestRoot
    foreach ($fileName in $sourceFiles) {
        if ($script:J1PartnerBFiles -notcontains $fileName) {
            throw "J1 did not deliver '$fileName' to partner B."
        }
        $sourcePath = Join-Path $repositoryRoot "test-data/j1/$fileName"
        $sourceSize = (Get-Item -LiteralPath $sourcePath).Length
        if ($partnerB.Sizes[$fileName] -ne $sourceSize) {
            throw "J1 delivery size for '$fileName' does not match the source."
        }
    }
    if ($script:J1PartnerBFiles -contains '~lock_invoices.csv') {
        throw 'J1 delivered the locked file to partner B.'
    }
    $partnerA = Get-PartnerAArchiveListing
    $script:J1PartnerAArchiveFiles = @($partnerA.Files)
    foreach ($fileName in $sourceFiles) {
        if (-not @($script:J1PartnerAArchiveFiles | Where-Object { $_ -like "*_$fileName" })) {
            throw "J1 did not archive '$fileName' on partner A."
        }
        $reportFile = @($details.files | Where-Object { $_.name -eq $fileName } | Select-Object -First 1)
        if ($reportFile.Count -ne 1 -or [long]$reportFile[0].sizeBytes -ne (Get-Item -LiteralPath (Join-Path $repositoryRoot "test-data/j1/$fileName")).Length) {
            throw "J1 report did not record the correct source size for '$fileName'."
        }
    }
    $script:J1Report = $runReport.BlobName
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{
        FileListings = @{
            'partner-b/inbound' = $script:J1PartnerBFiles
            'partner-a/archive' = $script:J1PartnerAArchiveFiles
        }
        Details = "Run report: $script:J1Report"
    }
}

function Restore {}
