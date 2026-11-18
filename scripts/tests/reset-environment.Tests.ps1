BeforeAll {
    . (Join-Path $PSScriptRoot '../reset-environment.ps1')
    $script:AzCalls = [Collections.Generic.List[object]]::new()
    $script:CurlCalls = [Collections.Generic.List[object]]::new()
    $script:RestoreCalls = 0
    $script:NasRunOutput = 'NAS_RESET_COMPLETE'
    $script:SftpKeyPath = $null
    $script:SftpKeyMode = $null

    Mock Invoke-AzCli {
        $script:AzCalls.Add(@($Arguments))
        if ($Arguments -contains 'sftp-partner-b-private-key') {
            return 'fixture-private-key'
        }
        if ($Arguments -contains 'value[0].message') {
            return $script:NasRunOutput
        }
        if ($Arguments -contains 'value') {
            return 'fixture-password'
        }
        return ''
    }
    Mock Invoke-Curl {
        $script:CurlCalls.Add(@($Arguments))
        if ($Arguments -contains '--key') {
            $keyIndex = [Array]::IndexOf($Arguments, '--key')
            $script:SftpKeyPath = $Arguments[$keyIndex + 1]
            $script:SftpKeyContent = [IO.File]::ReadAllText($script:SftpKeyPath)
            if (-not $IsWindows) {
                $script:SftpKeyMode = [IO.File]::GetUnixFileMode($script:SftpKeyPath)
            }
        }
        if ($Arguments -contains '--list-only') {
            if (($Arguments -join ' ') -like '*sftp://*') {
                return @('partner-file.csv', 'incomplete.csv.partial')
            }
            return 'sample.txt'
        }
        return ''
    }
    Mock Invoke-RestoreAllFault {
        $script:RestoreCalls++
    }
}

Describe 'reset-environment' {
    BeforeEach {
        $env:AZURE_RESOURCE_GROUP = 'test-rg'
        $env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
        $env:KEY_VAULT_NAME = 'test-vault'
        $env:PARTNER_VM_FQDN = 'partner-a.example.test'
        $env:PARTNER_FTP_PORT = '2021'
        $env:NAS_VM_NAME = 'nas-test'
        $env:NAS_SHARE_UNC = '\\nas01.corp.local\share'
        $env:DATA_STORAGE_ACCOUNT_NAME = 'teststorage'
        $script:AzCalls.Clear()
        $script:CurlCalls.Clear()
        $script:RestoreCalls = 0
        $script:NasRunOutput = 'NAS_RESET_COMPLETE'
        $script:SftpKeyPath = $null
        $script:SftpKeyMode = $null
        $script:SftpKeyContent = $null
    }

    It 'empties FTP and blob destinations, resets NAS folders, and restores faults' {
        Invoke-ResetEnvironment

        $ftpDeleteCalls = @($script:CurlCalls | Where-Object {
            $_ -contains '--quote' -and ($_[-1] -like 'ftp://*')
        })
        $sftpDeleteCalls = @($script:CurlCalls | Where-Object {
            $_ -contains '--quote' -and ($_[-1] -like 'sftp://*')
        })
        $ftpDeleteCalls.Count | Should -Be 4
        $sftpDeleteCalls.Count | Should -Be 2
        ($ftpDeleteCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match '/outbound/archive/sample.txt'
        ($sftpDeleteCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match 'rm /inbound/partner-file.csv'
        ($sftpDeleteCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match 'rm /inbound/incomplete.csv.partial'
        ($script:CurlCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match '--insecure'
        $script:SftpKeyContent | Should -Be 'fixture-private-key'
        if (-not $IsWindows) {
            $script:SftpKeyMode | Should -Be ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        (Test-Path -LiteralPath $script:SftpKeyPath) | Should -BeFalse
        ($script:CurlCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match 'ftp://partner-a.example.test:2021/'
        ($script:AzCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match 'sharepoint-sim'
        ($script:AzCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match 'run-reports'
        ($script:AzCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match 'RunPowerShellScript'
        $runCommand = @($script:AzCalls | Where-Object { $_ -contains 'RunPowerShellScript' })[0]
        $remoteScript = $runCommand[[Array]::IndexOf($runCommand, '--scripts') + 1]
        $remoteScript | Should -Match "Get-SmbShare -Name 'share'\)\.Path"
        $remoteScript | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $remoteScript | Should -Match 'Get-ChildItem -LiteralPath'
        foreach ($folder in @(
            'j3\in', 'j3\out', 'j3\archive', 'j4\finance', 'j4\documents',
            'j4\integration', 'j4\quarantine', 'folderwatch\in', 'folderwatch\processed'
        )) {
            $remoteScript | Should -Match ([regex]::Escape("'$folder'"))
        }
        $remoteScript | Should -Not -Match 'folderwatch\\out'
        $remoteScript | Should -Not -Match 'New-Item'
        $remoteScript | Should -Match 'NAS_RESET_COMPLETE'
        $script:RestoreCalls | Should -Be 1
    }

    It 'fails when the NAS completion marker is missing' {
        $script:NasRunOutput = ''

        { Invoke-ResetEnvironment } | Should -Throw '*Resetting the NAS failed*'
        (Test-Path -LiteralPath $script:SftpKeyPath) | Should -BeFalse
    }
}
