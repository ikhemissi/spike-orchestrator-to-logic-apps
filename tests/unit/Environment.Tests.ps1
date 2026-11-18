BeforeAll {
    . (Join-Path $PSScriptRoot '../lib/Environment.ps1')
}

AfterAll {
    Remove-Item Env:RUNNER_TEST_SETTING -ErrorAction SilentlyContinue
    Remove-Item Env:PARTNER_FTP_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:PARTNER_SFTP_PORT -ErrorAction SilentlyContinue
}

Describe 'Get-TestEnvironment' {
    BeforeEach {
        Remove-Item Env:RUNNER_TEST_SETTING -ErrorAction SilentlyContinue
        Remove-Item Env:PARTNER_FTP_PORT -ErrorAction SilentlyContinue
        Remove-Item Env:PARTNER_SFTP_PORT -ErrorAction SilentlyContinue
    }

    It 'loads a missing value from azd env get-values' {
        Mock Invoke-AzdGetValue { 'RUNNER_TEST_SETTING="loaded from azd"' }

        $environment = Get-TestEnvironment -RequiredNames @('RUNNER_TEST_SETTING')

        $environment.RUNNER_TEST_SETTING | Should -Be 'loaded from azd'
        Should -Invoke Invoke-AzdGetValue -Times 1
    }

    It 'prefers values already present in the environment' {
        $env:RUNNER_TEST_SETTING = 'already set'
        Mock Invoke-AzdGetValue { throw 'azd should not be called' }

        $environment = Get-TestEnvironment -RequiredNames @('RUNNER_TEST_SETTING')

        $environment.RUNNER_TEST_SETTING | Should -Be 'already set'
        Should -Invoke Invoke-AzdGetValue -Times 0
    }

    It 'reports every required value still missing after loading azd values' {
        Mock Invoke-AzdGetValue { @('RUNNER_MISSING_ONE=', 'RUNNER_MISSING_TWO=""') }

        { Get-TestEnvironment -RequiredNames @('RUNNER_MISSING_ONE', 'RUNNER_MISSING_TWO') } |
            Should -Throw '*RUNNER_MISSING_ONE, RUNNER_MISSING_TWO*'
    }

    It 'does not require SHAREPOINT_SITE_ID when ENABLE_SHAREPOINT is false' {
        $script:contractLines = @($script:TestEnvironmentNames | ForEach-Object { "$_=`"value`"" })
        $script:contractLines += 'ENABLE_SHAREPOINT="false"'
        Mock Invoke-AzdGetValue { $script:contractLines }

        $environment = Get-TestEnvironment

        $environment.ENABLE_SHAREPOINT | Should -Be 'false'
        $environment.ContainsKey('SHAREPOINT_SITE_ID') | Should -BeFalse
    }

    It 'requires SHAREPOINT_SITE_ID when azd sets ENABLE_SHAREPOINT to true' {
        Mock Invoke-AzdGetValue { 'ENABLE_SHAREPOINT="true"' }

        { Get-TestEnvironment -RequiredNames @('ENABLE_SHAREPOINT') } | Should -Throw '*SHAREPOINT_SITE_ID*'
    }

    It 'uses the default partner ports when azd does not provide them' {
        $script:contractLines = @(
            $script:TestEnvironmentNames |
                Where-Object { $_ -notin 'PARTNER_FTP_PORT', 'PARTNER_SFTP_PORT' } |
                ForEach-Object { "$_=`"value`"" }
        )
        $script:contractLines += 'ENABLE_SHAREPOINT="false"'
        Mock Invoke-AzdGetValue { $script:contractLines }

        $environment = Get-TestEnvironment

        $environment.PARTNER_FTP_PORT | Should -Be '2121'
        $environment.PARTNER_SFTP_PORT | Should -Be '2222'
    }
}
