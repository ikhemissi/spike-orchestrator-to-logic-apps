BeforeAll {
    . (Join-Path $PSScriptRoot '../lib/Workflows.ps1')
}

Describe 'Wait-WorkflowRun' {
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

    It 'returns Aborted and Faulted runs as terminal statuses' {
        $environment = @{
            AZURE_SUBSCRIPTION_ID = 'subscription'
            AZURE_RESOURCE_GROUP = 'resource-group'
            LOGIC_APP_NAME = 'logic-app'
        }
        $run = [pscustomobject]@{ WorkflowName = 'workflow'; TriggerName = 'Recurrence'; RunId = 'run-1' }
        $script:terminalWorkflowStatus = ''
        Mock Get-WorkflowRun { return @{ properties = @{ status = $script:terminalWorkflowStatus } } }
        Mock Get-WorkflowRunAction { return @() }

        foreach ($terminalStatus in @('Aborted', 'Faulted')) {
            $script:terminalWorkflowStatus = $terminalStatus
            $result = Wait-WorkflowRun -Environment $environment -Run $run
            $result.Status | Should -Be $terminalStatus
        }
    }

    It 'requests a recurrence trigger through az rest' {
        Mock Invoke-AzCommand { return '{"name":"run-2"}' }
        $environment = @{
            AZURE_SUBSCRIPTION_ID = 'subscription'
            AZURE_RESOURCE_GROUP = 'resource-group'
            LOGIC_APP_NAME = 'logic-app'
        }

        $started = Start-Workflow -Environment $environment -WorkflowName 'wf-example' -TriggerName 'Recurrence'

        $started.RunId | Should -Be 'run-2'
        Should -Invoke Invoke-AzCommand -Times 1 -ParameterFilter {
            $Arguments -contains '--method' -and
            $Arguments -contains 'post' -and
            ($Arguments -join ' ') -match 'triggers/Recurrence/run'
        }
    }
}
