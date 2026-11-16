BeforeAll {
    . (Join-Path $PSScriptRoot '../lib/Environment.ps1')
}

AfterAll {
    Remove-Item Env:RUNNER_TEST_SETTING -ErrorAction SilentlyContinue
}

Describe 'Get-TestEnvironment' {
    BeforeEach {
        Remove-Item Env:RUNNER_TEST_SETTING -ErrorAction SilentlyContinue
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
}
