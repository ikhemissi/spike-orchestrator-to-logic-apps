BeforeAll {
    . (Join-Path $PSScriptRoot '../reset-environment.ps1')
    $script:AzCalls = [Collections.Generic.List[object]]::new()
    $script:CurlCalls = [Collections.Generic.List[object]]::new()
    $script:RestoreCalls = 0

    Mock Invoke-AzCli {
        $script:AzCalls.Add(@($Arguments))
        if ($Arguments -contains 'value') {
            return 'fixture-password'
        }
        return ''
    }
    Mock Invoke-Curl {
        $script:CurlCalls.Add(@($Arguments))
        if ($Arguments -contains '--list-only') {
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
        $env:NAS_VM_NAME = 'nas-test'
        $env:NAS_SHARE_UNC = '\\nas01.corp.local\share'
        $env:DATA_STORAGE_ACCOUNT_NAME = 'teststorage'
        $script:AzCalls.Clear()
        $script:CurlCalls.Clear()
        $script:RestoreCalls = 0
    }

    It 'empties FTP and blob destinations, resets NAS folders, and restores faults' {
        Invoke-ResetEnvironment

        $deleteCalls = @($script:CurlCalls | Where-Object { $_ -contains '--quote' })
        $deleteCalls.Count | Should -Be 4
        ($deleteCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match '/outbound/archive/sample.txt'
        ($script:AzCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match 'sharepoint-sim'
        ($script:AzCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match 'run-reports'
        ($script:AzCalls | ForEach-Object { $_ -join ' ' } | Out-String) | Should -Match 'RunPowerShellScript'
        $script:RestoreCalls | Should -Be 1
    }
}
