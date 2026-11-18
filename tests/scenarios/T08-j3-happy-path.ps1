. (Join-Path $script:TestRoot 'scenarios/AlertHelpers.ps1')

function Reset {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/reset-environment.ps1') | Out-Null
}

function Seed {
    & (Join-Path (Split-Path -Parent $script:TestRoot) 'scripts/seed-test-data.ps1') --scenario j3 | Out-Null
}

function GetWorkflowName { 'wf-j3-convert-onprem' }

function Assert {
    param($Run)

    if ($Run.Status -ne 'Succeeded') {
        throw "J3 run ended with '$($Run.Status)'."
    }
    $environment = $script:ScenarioEnvironment
    $outputPath = "$($environment.NAS_SHARE_UNC)\j3\out"
    $outputNames = @(Get-NasFile -Environment $environment -Path $outputPath)
    $expectedRoot = Join-Path (Split-Path -Parent $script:TestRoot) 'test-data/j3/expected'
    foreach ($expectedFile in Get-ChildItem -LiteralPath $expectedRoot -Filter '*.json' -File) {
        if ($outputNames -notcontains $expectedFile.Name) {
            throw "J3 did not create '$($expectedFile.Name)'."
        }
        $actual = Read-NasFile -Environment $environment -Path "$outputPath\$($expectedFile.Name)"
        $expected = [IO.File]::ReadAllBytes($expectedFile.FullName)
        if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$expected, [byte[]]$actual)) {
            throw "J3 output '$($expectedFile.Name)' differs from the checked-in expected file."
        }
        $sidecarName = "$($expectedFile.Name).sha256"
        if ($outputNames -notcontains $sidecarName) {
            throw "J3 did not create '$sidecarName'."
        }
        $sourceName = [IO.Path]::ChangeExtension($expectedFile.Name, '.csv')
        $sourcePath = Join-Path (Split-Path -Parent $script:TestRoot) "test-data/j3/$sourceName"
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        $actualHash = [Text.Encoding]::UTF8.GetString((Read-NasFile -Environment $environment `
                    -Path "$outputPath\$sidecarName")).Trim()
        if ($actualHash -ne $sourceHash) {
            throw "J3 sidecar '$sidecarName' does not contain the source SHA-256."
        }
    }
    $archivePath = "$($environment.NAS_SHARE_UNC)\j3\archive"
    $archiveNames = @(Get-NasFile -Environment $environment -Path $archivePath)
    if ($archiveNames.Count -lt 2) {
        throw 'J3 did not archive both source files.'
    }
    $report = (Get-ScenarioRunReport -Run $Run -Job 'J3').Body
    $details = ConvertFrom-ScenarioReportDetail -Report $report
    if ($details.runAs -ne 'hw01\svc-azauto') {
        throw 'J3 output did not report runAs as hw01\svc-azauto.'
    }
    if ($details.worker -notmatch 'hw01|vm-hw01') {
        throw "J3 report recorded unexpected worker '$($details.worker)'."
    }
    if ([int]$report.filesProcessed -ne 2 -or [int]$report.filesFailed -ne 0) {
        throw 'J3 report did not record two successfully processed files.'
    }
    $script:J3FileListings = @{ 'j3/out' = $outputNames; 'j3/archive' = $archiveNames }
    return $true
}

function GetEvidence {
    param($Run)

    $report = Get-ScenarioRunReport -Run $Run -Job 'J3'
    return @{
        FileListings = $script:J3FileListings
        Details = "Run report: $($report.BlobName)"
    }
}

function Restore {}
