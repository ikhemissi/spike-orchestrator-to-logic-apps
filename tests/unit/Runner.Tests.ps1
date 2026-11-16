BeforeAll {
    . (Join-Path $PSScriptRoot '../run-all.ps1')
}

Describe 'Invoke-TestRunner' {
    It 'returns a non-zero exit code when a mandatory scenario fails and restores it' {
        $scenarioRoot = Join-Path $TestDrive 'scenarios'
        New-Item -ItemType Directory -Path $scenarioRoot | Out-Null
        $scenarioPath = Join-Path $scenarioRoot 'T01-egress-ip.ps1'
        $restoreMarker = Join-Path $TestDrive 'restore-was-called'
        $scenarioContent = @'
function Reset {}
function Seed {}
function GetWorkflowName { 'wf-egress' }
function Assert { param($Run) return $false }
function GetEvidence { param($Run) return @{ FileListings = @{ inbound = @('sample.csv') } } }
function Restore { Set-Content -LiteralPath '__RESTORE_MARKER__' -Value 'restored' }
'@
        $scenarioContent.Replace('__RESTORE_MARKER__', $restoreMarker) | Set-Content -LiteralPath $scenarioPath
        $reportPath = Join-Path $TestDrive 'docs/TEST-REPORT.md'
        Mock Get-TestEnvironment { return @{} }
        Mock Start-Workflow { return [pscustomobject]@{ WorkflowName = 'wf-egress'; TriggerName = 'Recurrence'; RunId = 'run-1' } }
        Mock Wait-WorkflowRun {
            return [pscustomobject]@{
                WorkflowName = 'wf-egress'
                RunId = 'run-1'
                Status = 'Succeeded'
                Actions = @()
                TrackedProperties = @{}
            }
        }

        $exitCode = Invoke-TestRunner -ScenarioRoot $scenarioRoot -ReportPath $reportPath

        $exitCode | Should -Be 1
        Test-Path -LiteralPath $restoreMarker | Should -BeTrue
        Get-Content -LiteralPath $reportPath -Raw | Should -Match 'T01-egress-ip'
        Get-Content -LiteralPath $reportPath -Raw | Should -Match 'sample\.csv'
        Should -Invoke Start-Workflow -Times 1
        Should -Invoke Wait-WorkflowRun -Times 1
    }

    It 'fails without running anything when -Only names a scenario that does not exist' {
        $scenarioRoot = Join-Path $TestDrive 'only-scenarios'
        New-Item -ItemType Directory -Path $scenarioRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $scenarioRoot 'T02-ftp.ps1') -Value 'function Reset {}'
        Mock Get-TestEnvironment { return @{} }
        Mock Start-Workflow {}

        $exitCode = Invoke-TestRunner -ScenarioRoot $scenarioRoot -ReportPath (Join-Path $TestDrive 'r.md') -Only 'T02', 'T03' -ErrorAction SilentlyContinue

        $exitCode | Should -Be 1
        Should -Invoke Start-Workflow -Times 0
    }
}
