function Reset {
    $scenarioRoot = Split-Path -Parent $script:TestRoot
    $workflowFile = Join-Path $scenarioRoot 'src/logicapp/wf-j5-nas-folderwatch/workflow.json'
    $script:FolderWatchEnabled = Test-Path -LiteralPath $workflowFile -PathType Leaf
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    if ($script:FolderWatchEnabled) {
        & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j5 | Out-Null
    }
}

function GetWorkflowName {
    if ($script:FolderWatchEnabled) {
        return 'wf-j5-nas-folderwatch'
    }
    return 'wf-diag-egress-ip'
}

function Assert {
    param($Run)

    if (-not $script:FolderWatchEnabled) {
        if ($Run.Status -ne 'Succeeded') {
            throw "Optional J5 check ended with '$($Run.Status)'."
        }
        return $true
    }
    if ($Run.Status -ne 'Succeeded') {
        throw "J5 run ended with '$($Run.Status)'."
    }
    $processedPath = Join-Path $script:ScenarioEnvironment.NAS_SHARE_UNC 'folderwatch\processed'
    $files = @(Get-NasFile -Environment $script:ScenarioEnvironment -Path $processedPath)
    if ($files -notcontains 'folderwatch_test.txt') {
        throw 'J5 did not move folderwatch_test.txt to the processed folder.'
    }
    $script:FolderWatchFiles = $files
    return $true
}

function GetEvidence {
    param($Run)

    $null = $Run
    if (-not $script:FolderWatchEnabled) {
        return @{ Details = 'Not applicable: J5 is not present in the Logic Apps source.' }
    }
    return @{ FileListings = @{ 'folderwatch/processed' = $script:FolderWatchFiles } }
}

function Restore {}
