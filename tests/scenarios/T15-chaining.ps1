function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j1 | Out-Null
}

function GetWorkflowName { 'wf-j1-partner-ftp-to-sftp' }

function Assert {
    param($Run)

    $script:ChainedReport = $null
    if ($Run.Status -ne 'Succeeded') {
        throw "Source workflow ended with '$($Run.Status)'."
    }
    $correlationId = $null
    foreach ($trackedProperties in $Run.TrackedProperties.Values) {
        if ($trackedProperties.correlationId) {
            $correlationId = [string]$trackedProperties.correlationId
            break
        }
    }
    if (-not $correlationId) {
        throw 'Source workflow run did not expose a correlationId.'
    }
    $reportAction = @($Run.Actions | Where-Object { $_.name -like 'Report_*' -and $_.properties.status -eq 'Succeeded' })
    if ($reportAction.Count -eq 0) {
        throw 'The child workflow report action did not succeed.'
    }
    $startTime = [datetime]::Parse($Run.Run.properties.startTime).ToUniversalTime()
    $datePrefix = $startTime.ToString('yyyy/MM/dd')
    $blobNames = @(Get-BlobFile -Environment $script:ScenarioEnvironment -Container 'run-reports' -Prefix "J1/$datePrefix")
    foreach ($blobName in $blobNames) {
        $bytes = Read-BlobFile -Environment $script:ScenarioEnvironment -Container 'run-reports' -BlobName $blobName
        $report = [Text.Encoding]::UTF8.GetString($bytes)
        if ($report -match [regex]::Escape($correlationId)) {
            $script:ChainedReport = $blobName
            return $true
        }
    }
    throw "No child run report blob contained correlationId '$correlationId'."
}

function GetEvidence {
    param($Run)

    $null = $Run
    return @{ FileListings = @{ 'run-reports' = @($script:ChainedReport) } }
}

function Restore {}
