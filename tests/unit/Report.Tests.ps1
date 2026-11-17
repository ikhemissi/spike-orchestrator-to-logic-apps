BeforeAll {
    . (Join-Path $PSScriptRoot '../lib/Report.ps1')
}

Describe 'Write-TestReport' {
    It 'writes run status, action status, tracked properties, and file listings' {
        $reportPath = Join-Path $TestDrive 'docs/TEST-REPORT.md'
        $results = @(
            [pscustomobject]@{
                Name = 'T01'
                Result = 'Passed'
                RunId = 'run-1'
                Status = 'Succeeded'
                Actions = @(@{ name = 'CheckEgress'; properties = @{ status = 'Succeeded' } })
                TrackedProperties = @{ CheckEgress = @{ address = '192.0.2.1' } }
                FileListings = @{ inbound = @('one.csv') }
                Details = ''
            }
        )

        $report = Write-TestReport -Results $results -Path $reportPath

        $report | Should -Match '\| T01 \| Passed \| run-1 \| Succeeded \|'
        $report | Should -Match 'CheckEgress'
        $report | Should -Match '192\.0\.2\.1'
        $report | Should -Match 'one\.csv'
        Get-Content -LiteralPath $reportPath -Raw | Should -Be ("# Test report`n`n" + $report)

        Write-TestReport -Results $results -Path $reportPath | Out-Null
        (Get-Content -LiteralPath $reportPath -Raw | Select-String -AllMatches '\| T01 \|').Matches.Count |
            Should -Be 2
    }

    It 'writes the report heading once and one section per run' {
        $reportPath = Join-Path $TestDrive 'TEST-REPORT.md'
        $results = @([pscustomobject]@{ Name = 'T02'; Result = 'Failed'; Details = 'timeout' })

        Write-TestReport -Results $results -Path $reportPath | Out-Null
        Write-TestReport -Results $results -Path $reportPath | Out-Null

        $content = Get-Content -LiteralPath $reportPath -Raw
        ([regex]::Matches($content, '(?m)^# Test report$')).Count | Should -Be 1
        ([regex]::Matches($content, '(?m)^## Run ')).Count | Should -Be 2
    }
}
