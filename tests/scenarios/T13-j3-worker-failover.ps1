function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j3 | Out-Null
}

function InjectFault {
    $workers = @($script:ScenarioEnvironment.WORKER_VM_NAMES -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $script:SecondWorkerEnabled = $workers.Count -gt 1
    if ($script:SecondWorkerEnabled) {
        # VERIFY: the first name in WORKER_VM_NAMES is vm-hw01 and `az vm stop` stops only that worker.
        Invoke-AzCommand -Arguments @(
            'vm', 'stop', '--resource-group', $script:ScenarioEnvironment.AZURE_RESOURCE_GROUP,
            '--subscription', $script:ScenarioEnvironment.AZURE_SUBSCRIPTION_ID,
            '--name', $workers[0], '--output', 'none'
        ) | Out-Null
    }
}

function GetWorkflowName {
    if ($script:SecondWorkerEnabled) {
        return 'wf-j3-convert-onprem'
    }
    return 'wf-diag-egress-ip'
}

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "Failover scenario run ended with '$($Run.Status)'."
    }
    if (-not $script:SecondWorkerEnabled) {
        return $true
    }
    $runJson = ConvertTo-Json -InputObject $Run -Depth 100 -Compress
    if ($runJson -notmatch 'vm-hw02|hw02') {
        throw 'J3 did not report vm-hw02 as the worker.'
    }
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    if (-not $script:SecondWorkerEnabled) {
        return @{ Details = 'Not applicable: a second hybrid worker is not enabled.' }
    }
    return @{ Details = 'Expected J3 to complete on vm-hw02 while vm-hw01 is stopped.' }
}

function Restore {
    if ($script:SecondWorkerEnabled) {
        # The scenario stops the first worker itself (the worker-stop fault stops them all), so it starts it again.
        $firstWorker = ($script:ScenarioEnvironment.WORKER_VM_NAMES -split ',')[0].Trim()
        Invoke-AzCommand -Arguments @(
            'vm', 'start', '--resource-group', $script:ScenarioEnvironment.AZURE_RESOURCE_GROUP,
            '--subscription', $script:ScenarioEnvironment.AZURE_SUBSCRIPTION_ID,
            '--name', $firstWorker, '--output', 'none'
        ) | Out-Null
    }
}
