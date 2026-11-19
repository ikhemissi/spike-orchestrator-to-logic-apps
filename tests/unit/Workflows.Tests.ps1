BeforeAll {
    . (Join-Path $PSScriptRoot '../lib/Workflows.ps1')
    # Start-Workflow first waits for the runtime after possible restarts; these tests are about the trigger and the run.
    Mock Wait-WorkflowRuntime {}
}

Describe 'Wait-WorkflowRun' {
    It 'allows J4 runs up to 30 minutes by default' {
        $environment = @{
            AZURE_SUBSCRIPTION_ID = 'subscription'
            AZURE_RESOURCE_GROUP = 'resource-group'
            LOGIC_APP_NAME = 'logic-app'
        }
        $run = [pscustomobject]@{ WorkflowName = 'wf-j4-ftp-sort-to-nas'; TriggerName = 'Recurrence'; RunId = 'run-1' }
        $script:waitSleepMilliseconds = 0
        Mock Get-WorkflowRun { return @{ properties = @{ status = 'Running' } } }
        Mock Start-Sleep {
            $script:waitSleepMilliseconds = $Milliseconds
            throw 'stop after observing the timeout interval'
        }

        {
            Wait-WorkflowRun -Environment $environment -Run $run -PollInterval ([timespan]::FromDays(1))
        } | Should -Throw '*stop after observing*'

        ($script:waitSleepMilliseconds -gt 1790000) | Should -BeTrue
        ($script:waitSleepMilliseconds -le 1800000) | Should -BeTrue
    }

    It 'polls until the workflow run reaches a terminal status and returns action evidence' {
        $script:workflowPollCount = 0
        $environment = @{
            AZURE_SUBSCRIPTION_ID = 'subscription'
            AZURE_RESOURCE_GROUP = 'resource-group'
            LOGIC_APP_NAME = 'logic-app'
        }
        $run = [pscustomobject]@{ WorkflowName = 'workflow'; TriggerName = 'Recurrence'; RunId = 'run-1' }
        Mock Get-WorkflowRun {
            $script:workflowPollCount++
            $status = if ($script:workflowPollCount -eq 1) { 'Running' } else { 'Succeeded' }
            return @{ properties = @{ status = $status } }
        }
        Mock Get-WorkflowRunAction {
            return @(@{
                name = 'ProcessFile'
                properties = @{
                    status = 'Succeeded'
                    trackedProperties = @{ filesProcessed = 1 }
                }
            })
        }
        Mock Start-Sleep {}

        $result = Wait-WorkflowRun -Environment $environment -Run $run -Timeout ([timespan]::FromSeconds(5)) -PollInterval ([timespan]::FromMilliseconds(1))

        $result.Status | Should -Be 'Succeeded'
        $result.Actions[0].properties.status | Should -Be 'Succeeded'
        $result.TrackedProperties.ProcessFile.filesProcessed | Should -Be 1
        Should -Invoke Get-WorkflowRun -Times 2
    }

    It 'throws when a running workflow exceeds the timeout' {
        $environment = @{
            AZURE_SUBSCRIPTION_ID = 'subscription'
            AZURE_RESOURCE_GROUP = 'resource-group'
            LOGIC_APP_NAME = 'logic-app'
        }
        $run = [pscustomobject]@{ WorkflowName = 'workflow'; TriggerName = 'Recurrence'; RunId = 'run-1' }
        Mock Get-WorkflowRun { return @{ properties = @{ status = 'Running' } } }
        Mock Start-Sleep {}

        {
            Wait-WorkflowRun -Environment $environment -Run $run `
                -Timeout ([timespan]::FromMilliseconds(1)) -PollInterval ([timespan]::FromMilliseconds(1))
        } | Should -Throw '*Timed out*'
    }

    It 'returns Aborted, Faulted, Skipped and Ignored runs as terminal statuses' {
        $environment = @{
            AZURE_SUBSCRIPTION_ID = 'subscription'
            AZURE_RESOURCE_GROUP = 'resource-group'
            LOGIC_APP_NAME = 'logic-app'
        }
        $run = [pscustomobject]@{ WorkflowName = 'workflow'; TriggerName = 'Recurrence'; RunId = 'run-1' }
        $script:terminalWorkflowStatus = ''
        Mock Get-WorkflowRun { return @{ properties = @{ status = $script:terminalWorkflowStatus } } }
        Mock Get-WorkflowRunAction { return @() }
        Mock Start-Sleep { throw 'a terminal status must not be polled again' }

        foreach ($terminalStatus in @('Aborted', 'Faulted', 'Skipped', 'Ignored')) {
            $script:terminalWorkflowStatus = $terminalStatus
            $result = Wait-WorkflowRun -Environment $environment -Run $run
            $result.Status | Should -Be $terminalStatus
        }
    }
}

Describe 'Invoke-WorkflowManagementRequest' {
    It 'retries a ServiceUnavailable response after 15 seconds' {
        $script:managementRequestAttempts = 0
        Mock Invoke-AzCommand {
            $script:managementRequestAttempts++
            if ($script:managementRequestAttempts -eq 1) {
                throw 'ServiceUnavailable'
            }
            return '{"name":"run-1"}'
        }
        Mock Start-Sleep {}

        $response = Invoke-WorkflowManagementRequest -Method get -Url 'https://management.example/run'

        $response.name | Should -Be 'run-1'
        Should -Invoke Invoke-AzCommand -Times 2
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 15 }
    }

    It 'retries a RequestTimeout response after 15 seconds' {
        $script:managementRequestAttempts = 0
        Mock Invoke-AzCommand {
            $script:managementRequestAttempts++
            if ($script:managementRequestAttempts -eq 1) {
                throw 'RequestTimeout'
            }
            return '{"name":"run-1"}'
        }
        Mock Start-Sleep {}

        $response = Invoke-WorkflowManagementRequest -Method get -Url 'https://management.example/run'

        $response.name | Should -Be 'run-1'
        Should -Invoke Invoke-AzCommand -Times 2
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 15 }
    }
}

Describe 'Start-Workflow' {
    BeforeEach {
        $script:workflowEnvironment = @{
            AZURE_SUBSCRIPTION_ID = 'subscription'
            AZURE_RESOURCE_GROUP = 'resource-group'
            LOGIC_APP_NAME = 'logic-app'
        }
    }

    It 'finds the run ID by listing runs, since the trigger call answers 202 with an empty body' {
        $script:runListCount = 0
        Mock Invoke-WorkflowManagementRequest -ParameterFilter { $Method -eq 'post' } { return $null }
        Mock Invoke-WorkflowManagementRequest -ParameterFilter { $Method -eq 'get' } {
            $script:runListCount++
            $olderRun = @{ name = 'run-before-trigger'; properties = @{ startTime = [datetime]::UtcNow.AddHours(-1).ToString('o') } }
            if ($script:runListCount -eq 1) {
                return @{ value = @($olderRun) }
            }
            $triggeredRun = @{ name = 'run-from-trigger'; properties = @{ startTime = [datetime]::UtcNow.AddSeconds(1).ToString('o') } }
            return @{ value = @($triggeredRun, $olderRun) }
        }
        Mock Start-Sleep {}

        $started = Start-Workflow -Environment $script:workflowEnvironment -WorkflowName 'wf-example' -TriggerName 'Recurrence'

        $started.RunId | Should -Be 'run-from-trigger'
        Should -Invoke Invoke-WorkflowManagementRequest -Times 1 -ParameterFilter {
            $Method -eq 'post' -and $Url -match 'workflows/wf-example/triggers/Recurrence/run\?'
        }
        Should -Invoke Invoke-WorkflowManagementRequest -Times 2 -ParameterFilter {
            $Method -eq 'get' -and $Url -match 'workflows/wf-example/runs\?api-version='
        }
    }

    It 'throws when no run starts before the start timeout' {
        Mock Invoke-WorkflowManagementRequest -ParameterFilter { $Method -eq 'post' } { return $null }
        Mock Invoke-WorkflowManagementRequest -ParameterFilter { $Method -eq 'get' } { return @{ value = @() } }
        Mock Start-Sleep {}

        {
            Start-Workflow -Environment $script:workflowEnvironment -WorkflowName 'wf-example' `
                -StartTimeout ([timespan]::FromMilliseconds(1)) -PollInterval ([timespan]::FromMilliseconds(1))
        } | Should -Throw '*waiting for a run*'
    }
}

Describe 'Invoke-AzCommand' {
    It 'returns only stdout, so az warnings on stderr cannot break the parsed JSON' {
        Mock az {
            Write-Error 'WARNING: a newer version of az is available'
            '{"name":"run-1"}'
            $global:LASTEXITCODE = 0
        }

        $output = Invoke-AzCommand -Arguments @('rest')

        $output | Should -Be '{"name":"run-1"}'
    }

    It 'includes stderr in the error when az fails' {
        Mock az {
            Write-Error 'ERROR: authorization failed'
            $global:LASTEXITCODE = 1
        }

        { Invoke-AzCommand -Arguments @('rest') } | Should -Throw '*authorization failed*'
    }
}
