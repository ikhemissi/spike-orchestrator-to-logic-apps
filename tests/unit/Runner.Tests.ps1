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

    It 'fails a full run when a mandatory scenario has no script' {
        $scenarioRoot = Join-Path $TestDrive 'partial-scenarios'
        New-Item -ItemType Directory -Path $scenarioRoot | Out-Null
        $passingScenario = @'
function Reset {}
function Seed {}
function GetWorkflowName { 'wf-egress' }
function Assert { param($Run) return $true }
function GetEvidence { param($Run) return @{} }
function Restore {}
'@
        Set-Content -LiteralPath (Join-Path $scenarioRoot 'T01-egress-ip.ps1') -Value $passingScenario
        $reportPath = Join-Path $TestDrive 'partial-report.md'
        Mock Get-TestEnvironment { return @{} }
        Mock Start-Workflow { return [pscustomobject]@{ WorkflowName = 'wf-egress'; RunId = 'run-1' } }
        Mock Wait-WorkflowRun { return [pscustomobject]@{ RunId = 'run-1'; Status = 'Succeeded'; Actions = @(); TrackedProperties = @{} } }

        $exitCode = Invoke-TestRunner -ScenarioRoot $scenarioRoot -ReportPath $reportPath

        $exitCode | Should -Be 1
        $report = Get-Content -LiteralPath $reportPath -Raw
        $report | Should -Match '\| T01-egress-ip \| Passed \|'
        $report | Should -Match '\| T15 \| Failed \|.*No scenario script found'
    }

    It 'accepts -Only T01,T02 as one comma-separated string, as pwsh -File passes it' {
        $scenarioRoot = Join-Path $TestDrive 'comma-scenarios'
        New-Item -ItemType Directory -Path $scenarioRoot | Out-Null
        $passingScenario = @'
function Reset {}
function Seed {}
function GetWorkflowName { 'wf-example' }
function Assert { param($Run) return $true }
function GetEvidence { param($Run) return @{} }
function Restore {}
'@
        foreach ($fileName in @('T01-egress-ip.ps1', 'T02-ftp.ps1', 'T03-sftp.ps1')) {
            Set-Content -LiteralPath (Join-Path $scenarioRoot $fileName) -Value $passingScenario
        }
        Mock Get-TestEnvironment { return @{} }
        Mock Start-Workflow { return [pscustomobject]@{ WorkflowName = 'wf-example'; RunId = 'run-1' } }
        Mock Wait-WorkflowRun { return [pscustomobject]@{ RunId = 'run-1'; Status = 'Succeeded'; Actions = @(); TrackedProperties = @{} } }

        $exitCode = Invoke-TestRunner -ScenarioRoot $scenarioRoot -ReportPath (Join-Path $TestDrive 'comma-report.md') -Only 'T01, t02'

        $exitCode | Should -Be 0
        Should -Invoke Start-Workflow -Times 2
    }
}
