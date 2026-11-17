BeforeAll {
    . (Join-Path $PSScriptRoot '../seed-test-data.ps1')
    $script:CurlCalls = [Collections.Generic.List[object]]::new()
    $script:AzCalls = [Collections.Generic.List[object]]::new()

    Mock Invoke-AzCli {
        $script:AzCalls.Add(@($Arguments))
        if ($Arguments -contains 'value') {
            return 'fixture-password'
        }
        return ''
    }
    Mock Invoke-Curl {
        $script:CurlCalls.Add(@($Arguments))
    }
}

Describe 'seed-test-data' {
    BeforeEach {
        $env:AZURE_RESOURCE_GROUP = 'test-rg'
        $env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
        $env:KEY_VAULT_NAME = 'test-vault'
        $env:PARTNER_VM_FQDN = 'partner-a.example.test'
        $env:NAS_VM_NAME = 'nas-test'
        $env:NAS_SHARE_UNC = '\\nas01.corp.local\share'
        $script:CurlCalls.Clear()
        $script:AzCalls.Clear()
    }

    It 'uploads only the requested FTP scenario using passive curl -T' {
        $output = @(Invoke-SeedScenario -Scenario j2)

        $output.Count | Should -Be 0
        $script:CurlCalls.Count | Should -Be 2
        $script:CurlCalls[0] | Should -Contain '--ftp-pasv'
        $script:CurlCalls[0] | Should -Contain '-T'
        ($script:CurlCalls[0] -join ' ') | Should -Match 'outbound/j2/'
        $script:CurlCalls[0][-1] | Should -Not -Match 'fixture-password'
    }

    It 'sends NAS files as base64 through the NAS VM run command' {
        Invoke-SeedScenario -Scenario j3-failure

        $call = $script:AzCalls | Where-Object { $_ -contains 'RunPowerShellScript' } | Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
        ($call -join ' ') | Should -Match 'FAIL_locked_file.csv'
        ($call -join ' ') | Should -Match 'FromBase64String'
        $script:CurlCalls.Count | Should -Be 0
    }
}
