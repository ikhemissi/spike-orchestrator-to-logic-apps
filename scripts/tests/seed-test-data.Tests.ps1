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
        $uploadPath = $Arguments[[Array]::IndexOf($Arguments, '-T') + 1]
        $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($uploadPath))
        $script:CurlCalls.Add([pscustomobject]@{
            Arguments = @($Arguments)
            Content = $content
        })
    }
}

Describe 'seed-test-data' {
    BeforeEach {
        $env:AZURE_RESOURCE_GROUP = 'test-rg'
        $env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
        $env:KEY_VAULT_NAME = 'test-vault'
        $env:PARTNER_VM_FQDN = 'partner-a.example.test'
        $env:PARTNER_FTP_PORT = '2021'
        $env:NAS_VM_NAME = 'nas-test'
        $env:NAS_SHARE_UNC = '\\nas01.corp.local\share'
        $script:CurlCalls.Clear()
        $script:AzCalls.Clear()
    }

    It 'uploads only the requested FTP scenario using passive curl -T' {
        $output = @(Invoke-SeedScenario -Scenario j2)

        $output.Count | Should -Be 0
        $script:CurlCalls.Count | Should -Be 2
        $script:CurlCalls[0].Arguments | Should -Contain '--ftp-pasv'
        $script:CurlCalls[0].Arguments | Should -Contain '-T'
        $script:CurlCalls[0].Arguments[-1] | Should -Be 'ftp://partner-a.example.test:2021/outbound/j2/'
        $script:CurlCalls[0].Arguments[-1] | Should -Not -Match 'fixture-password'
        foreach ($upload in $script:CurlCalls) {
            $uploadPath = $upload.Arguments[[Array]::IndexOf($upload.Arguments, '-T') + 1]
            $sourcePath = Join-Path $PSScriptRoot "../../test-data/j2/$(Split-Path -Leaf $uploadPath)"
            $expectedContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($sourcePath))
            $upload.Content | Should -Be $expectedContent
        }
    }

    It 'sends NAS files as base64 through the NAS VM run command' {
        Invoke-SeedScenario -Scenario j3-failure

        $call = $script:AzCalls | Where-Object { $_ -contains 'RunPowerShellScript' } | Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
        $scriptArgumentIndex = [Array]::IndexOf($call, '--scripts') + 1
        $remoteScript = $call[$scriptArgumentIndex]
        $entries = [regex]::Matches($remoteScript, "Path = '([^']+)'; Content = '([^']+)'")
        $entries.Count | Should -Be 3
        foreach ($entry in $entries) {
            $name = Split-Path -Leaf $entry.Groups[1].Value
            $sourcePath = Join-Path $PSScriptRoot "../../test-data/j3/$name"
            $expectedContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($sourcePath))
            $entry.Groups[2].Value | Should -Be $expectedContent
        }
        $script:CurlCalls.Count | Should -Be 0
    }

    It 'excludes the failure fixture from regular J3' {
        Invoke-SeedScenario -Scenario j3

        $call = $script:AzCalls | Where-Object { $_ -contains 'RunPowerShellScript' } | Select-Object -First 1
        $remoteScript = $call[[Array]::IndexOf($call, '--scripts') + 1]
        $entries = [regex]::Matches($remoteScript, "Path = '([^']+)'; Content = '([^']+)'")
        $entries.Count | Should -Be 2
        $entries.Value | Should -Not -Match 'FAIL_locked_file.csv'
        foreach ($entry in $entries) {
            $name = Split-Path -Leaf $entry.Groups[1].Value
            $sourcePath = Join-Path $PSScriptRoot "../../test-data/j3/$name"
            $expectedContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($sourcePath))
            $entry.Groups[2].Value | Should -Be $expectedContent
        }
    }

    It 'rejects a NAS file larger than the Run Command payload limit' {
        $script:OversizedSeedFile = Join-Path $TestDrive 'oversized.bin'
        [IO.File]::WriteAllBytes($script:OversizedSeedFile, [byte[]]::new(262145))
        Mock Get-SeedDataFile { return $script:OversizedSeedFile }

        { Invoke-SeedScenario -Scenario j3 } | Should -Throw '*NAS file exceeds the 256 KiB Run Command limit*'
        $script:AzCalls.Count | Should -Be 0
    }

    It 'rejects an encoded NAS script larger than the process argument limit' {
        $script:OversizedSeedFile = Join-Path $TestDrive 'encoded-oversized.bin'
        [IO.File]::WriteAllBytes($script:OversizedSeedFile, [byte[]]::new(200000))
        Mock Get-SeedDataFile { return $script:OversizedSeedFile }

        { Invoke-SeedScenario -Scenario j3 } | Should -Throw '*NAS Run Command script exceeds the 28 KiB process argument limit after base64 encoding*'
        $script:AzCalls.Count | Should -Be 0
    }
}
