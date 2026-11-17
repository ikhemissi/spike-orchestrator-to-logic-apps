# Exercise the runbook with the real conversion tool of infra/scripts/vm/tools/ against temporary folders.
Describe 'Invoke-ConvertAndMove' {
BeforeAll {
    $script:runbook = Join-Path $PSScriptRoot '..' 'Invoke-ConvertAndMove.ps1'
    $script:tool = Join-Path $PSScriptRoot '..' '..' '..' 'infra' 'scripts' 'vm' 'tools' 'Convert-Extract.ps1'
    $script:testData = Join-Path $PSScriptRoot '..' '..' '..' 'test-data' 'j3'

    function Write-PayrollExtract([string] $Path, [string] $GrossAmount = '4200.00') {
        Set-Content -LiteralPath $Path -Value @('employeeId,period,grossAmount,currency', "EMP-001,2026-11,$GrossAmount,EUR")
    }
}

BeforeEach {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $source = Join-Path $root 'source'
    $target = Join-Path $root 'target'
    $archive = Join-Path $root 'archive'
    foreach ($directory in @($source, $target, $archive)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $script:parameters = @{
        CorrelationId = 'test-correlation'
        SourcePath = $source
        TargetPath = $target
        ArchivePath = $archive
        ToolPath = $tool
    }
}

    It 'converts the J3 extracts to the expected JSON, writes sidecar hashes and archives the sources' {
        $names = @('hr_movements_202611', 'payroll_extract_202611')
        foreach ($name in $names) {
            Copy-Item -LiteralPath (Join-Path $testData "$name.csv") -Destination $source
        }

        $output = @(& $runbook @parameters)
        $result = $output[0] | ConvertFrom-Json

        $output.Count | Should -Be 1
        $result.correlationId | Should -Be 'test-correlation'
        $result.status | Should -Be 'Succeeded'
        $result.filesProcessed | Should -Be 2
        @($result.items.result) | Should -Be @('converted', 'converted')
        foreach ($name in $names) {
            $expectedHash = (Get-FileHash -LiteralPath (Join-Path $testData 'expected' "$name.json")).Hash
            (Get-FileHash -LiteralPath (Join-Path $target "$name.json")).Hash | Should -Be $expectedHash
            $sourceHash = (Get-FileHash -LiteralPath (Join-Path $testData "$name.csv")).Hash
            Get-Content -Raw -LiteralPath (Join-Path $target "$name.json.sha256") | Should -Be $sourceHash
            @(Get-ChildItem -LiteralPath $archive -Filter "*_$name.csv").Count | Should -Be 1
        }
        @(Get-ChildItem -LiteralPath $source).Count | Should -Be 0
    }

    It 'skips an existing target with the same sidecar hash and archives the source' {
        $sourceFile = Join-Path $source 'payroll.csv'
        Write-PayrollExtract $sourceFile
        $null = & $runbook @parameters
        $convertedFile = Join-Path $target 'payroll.json'
        $firstWriteTime = (Get-Item -LiteralPath $convertedFile).LastWriteTimeUtc
        # Avoid an archive collision when the two runs occur in the same second.
        Get-ChildItem -LiteralPath $archive | Remove-Item
        Write-PayrollExtract $sourceFile

        $result = & $runbook @parameters | ConvertFrom-Json

        $result.filesSkipped | Should -Be 1
        $result.filesProcessed | Should -Be 0
        $result.items[0].result | Should -Be 'skipped'
        (Get-Item -LiteralPath $convertedFile).LastWriteTimeUtc | Should -Be $firstWriteTime
        @(Get-ChildItem -LiteralPath $archive).Count | Should -Be 1
    }

    It 'reports FAIL_locked_file.csv as INVALID_INPUT, keeps it and processes the other files' {
        Copy-Item -LiteralPath (Join-Path $testData 'FAIL_locked_file.csv') -Destination $source
        Write-PayrollExtract (Join-Path $source 'payroll.csv')

        $output = @(& $runbook @parameters)
        $result = $output[0] | ConvertFrom-Json

        $output.Count | Should -Be 1
        $result.status | Should -Be 'PartialFailure'
        $result.filesFailed | Should -Be 1
        $result.filesProcessed | Should -Be 1
        $result.errors[0].code | Should -Be 'INVALID_INPUT'
        $result.errors[0].file | Should -Be 'FAIL_locked_file.csv'
        $result.errors[0].message | Should -BeLike "*Unknown header 'recordId,status'*"
        $result.items[0].result | Should -Be 'failed'
        $result.items[0].sha256 | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $source 'FAIL_locked_file.csv') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'payroll.json') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $target -Force -Filter 'FAIL_locked_file*').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $target -Force -Filter '*.tmp').Count | Should -Be 0
    }

    It 'has no name-based failure rule: a valid file named FAIL is converted' {
        Write-PayrollExtract (Join-Path $source 'FAIL_but_valid.csv')

        $result = & $runbook @parameters | ConvertFrom-Json

        $result.status | Should -Be 'Succeeded'
        $result.filesProcessed | Should -Be 1
    }

    It 'reports every file as failed when SimulateFailure is set' {
        Write-PayrollExtract (Join-Path $source 'one.csv')
        Write-PayrollExtract (Join-Path $source 'two.csv')

        $result = & $runbook @parameters -SimulateFailure | ConvertFrom-Json

        $result.status | Should -Be 'PartialFailure'
        $result.filesFailed | Should -Be 2
        $result.filesProcessed | Should -Be 0
        @($result.errors | Where-Object code -eq 'SIMULATED_FAILURE').Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $source).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0
    }

    It 'throws when the source directory is missing' {
        $parameters.SourcePath = Join-Path $root 'missing'
        { & $runbook @parameters } | Should -Throw
    }

    It 'throws when the conversion tool is not installed, before moving any source file' {
        $sourceFile = Join-Path $source 'payroll.csv'
        Write-PayrollExtract $sourceFile
        $parameters.ToolPath = Join-Path $root 'missing-tool.ps1'

        { & $runbook @parameters } | Should -Throw '*conversion tool is not installed*'

        Test-Path -LiteralPath $sourceFile | Should -BeTrue
    }

    It 'processes only MaxFiles in name order' {
        foreach ($name in @('c.csv', 'a.csv', 'b.csv')) {
            Write-PayrollExtract (Join-Path $source $name)
        }

        $result = & $runbook @parameters -MaxFiles 2 | ConvertFrom-Json

        $result.filesProcessed | Should -Be 2
        @($result.items.name) | Should -Be @('a.csv', 'b.csv')
        Test-Path -LiteralPath (Join-Path $source 'c.csv') | Should -BeTrue
    }

    It 'processes hidden source files' {
        $hiddenFile = Join-Path $source '.hidden.csv'
        Write-PayrollExtract $hiddenFile
        if ($IsWindows) {
            (Get-Item -LiteralPath $hiddenFile -Force).Attributes = [System.IO.FileAttributes]::Hidden
        }

        $result = & $runbook @parameters | ConvertFrom-Json

        $result.filesProcessed | Should -Be 1
        Test-Path -LiteralPath (Join-Path $target '.hidden.json') | Should -BeTrue
    }

    It 'accepts paths relative to the PowerShell location' {
        Write-PayrollExtract (Join-Path $source 'payroll.csv')
        Push-Location $root
        try {
            $parameters.SourcePath = 'source'
            $parameters.TargetPath = 'target'
            $parameters.ArchivePath = 'archive'

            $result = & $runbook @parameters | ConvertFrom-Json
        }
        finally {
            Pop-Location
        }

        $result.filesProcessed | Should -Be 1
        Test-Path -LiteralPath (Join-Path $target 'payroll.json') | Should -BeTrue
    }

    It 'emits one compressed JSON line with identity and worker under 1 MiB' {
        Write-PayrollExtract (Join-Path $source 'payroll.csv')

        $output = @(& $runbook @parameters -Verbose)
        $result = $output[0] | ConvertFrom-Json

        $output.Count | Should -Be 1
        $output[0] | Should -Not -Match '[\r\n]'
        [System.Text.Encoding]::UTF8.GetByteCount($output[0]) | Should -BeLessThan 1MB
        $result.runAs | Should -Not -BeNullOrEmpty
        $result.worker | Should -Not -BeNullOrEmpty
        $result.startedAt | Should -Not -BeNullOrEmpty
        $result.completedAt | Should -Not -BeNullOrEmpty
    }

    It 'rejects a potentially oversized result before moving any source files' {
        $sourceFile = Join-Path $source 'payroll.csv'
        Write-PayrollExtract $sourceFile
        $parameters.CorrelationId = 'x' * 1MB

        { & $runbook @parameters } | Should -Throw '*1 MiB*'

        Test-Path -LiteralPath $sourceFile | Should -BeTrue
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $archive -Force).Count | Should -Be 0
    }

    It 're-converts when the source hash differs from the sidecar' {
        $sourceFile = Join-Path $source 'payroll.csv'
        Write-PayrollExtract $sourceFile '100.00'
        $null = & $runbook @parameters
        Get-ChildItem -LiteralPath $archive | Remove-Item
        Write-PayrollExtract $sourceFile '200.00'

        $result = & $runbook @parameters | ConvertFrom-Json

        $result.filesProcessed | Should -Be 1
        $result.filesSkipped | Should -Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $target 'payroll.json') | ConvertFrom-Json).grossAmount | Should -Be 200
    }

    It 'records FILE_PROCESSING_FAILED for a locked file, keeps that source and processes the other files' {
        $lockedFile = Join-Path $source 'a-locked.csv'
        Write-PayrollExtract $lockedFile
        Write-PayrollExtract (Join-Path $source 'b-ok.csv')
        # Pester 6 neither falls back to the real command when a filter does not match nor lets a mock call it,
        # so the default mock computes the same SHA-256 with .NET.
        Mock Get-FileHash {
            $hashBytes = [System.Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($LiteralPath))
            [pscustomobject]@{ Hash = [System.Convert]::ToHexString($hashBytes) }
        }
        Mock Get-FileHash { throw [System.IO.IOException]::new('The file is locked by another process.') } -ParameterFilter { $LiteralPath -like '*a-locked.csv' }

        $output = @(& $runbook @parameters)
        $result = $output[0] | ConvertFrom-Json

        $output.Count | Should -Be 1
        $result.status | Should -Be 'PartialFailure'
        $result.filesFailed | Should -Be 1
        $result.filesProcessed | Should -Be 1
        $failedItems = @($result.items | Where-Object result -eq 'failed')
        $failedItems.Count | Should -Be 1
        $failedItems[0].name | Should -Be 'a-locked.csv'
        $failedItems[0].sha256 | Should -BeNullOrEmpty
        $failedItems[0].error | Should -Be 'The file is locked by another process.'
        $result.errors[0].code | Should -Be 'FILE_PROCESSING_FAILED'
        $result.errors[0].file | Should -Be 'a-locked.csv'
        Test-Path -LiteralPath $lockedFile | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'b-ok.json') | Should -BeTrue
    }

    It 'throws when access to the share is denied' {
        Write-PayrollExtract (Join-Path $source 'payroll.csv')
        Mock Get-FileHash { throw [System.UnauthorizedAccessException]::new('Access to the path is denied.') }

        { & $runbook @parameters } | Should -Throw '*Access to the path is denied*'

        Test-Path -LiteralPath (Join-Path $source 'payroll.csv') | Should -BeTrue
    }

    It 'does not leave a stale sidecar if writing the replacement sidecar fails' {
        $sourceFile = Join-Path $source 'payroll.csv'
        Write-PayrollExtract $sourceFile '100.00'
        $null = & $runbook @parameters
        Write-PayrollExtract $sourceFile '200.00'
        Mock Set-Content { throw 'Sidecar write failed' } -ParameterFilter { $LiteralPath -like '*.sha256' }

        $result = & $runbook @parameters | ConvertFrom-Json

        $result.status | Should -Be 'PartialFailure'
        $result.errors[0].code | Should -Be 'FILE_PROCESSING_FAILED'
        Test-Path -LiteralPath (Join-Path $target 'payroll.json.sha256') | Should -BeFalse
        Test-Path -LiteralPath $sourceFile | Should -BeTrue
    }
}
