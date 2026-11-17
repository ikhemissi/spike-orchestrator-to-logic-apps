# Run the local conversion tool as its own process, as the runbook does, against the J3 test data and temporary files.
Describe 'Convert-Extract' {
    BeforeAll {
        $script:tool = Join-Path $PSScriptRoot '..' 'tools' 'Convert-Extract.ps1'
        $script:testData = Join-Path $PSScriptRoot '..' '..' '..' '..' 'test-data' 'j3'
        $script:powerShell = (Get-Process -Id $PID).Path

        function Invoke-ConvertExtract([string] $SourcePath, [string] $OutputPath) {
            $errorFile = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).err"
            $standardOutput = & $powerShell -NoProfile -NonInteractive -File $tool -SourcePath $SourcePath -OutputPath $OutputPath 2> $errorFile
            return @{
                ExitCode = $LASTEXITCODE
                StandardOutput = $standardOutput
                StandardError = [string](Get-Content -LiteralPath $errorFile -Raw)
            }
        }

        function Write-SourceFile([string] $Name, [string[]] $Lines) {
            $path = Join-Path $TestDrive $Name
            [System.IO.File]::WriteAllText($path, ($Lines -join "`n") + "`n")
            return $path
        }
    }

    BeforeEach {
        $script:outputFile = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).json"
    }

    It 'converts <Name>.csv to the expected JSON byte for byte' -TestCases @(
        @{ Name = 'payroll_extract_202611' },
        @{ Name = 'hr_movements_202611' }
    ) {
        $expectedFile = Join-Path $testData 'expected' "$Name.json"

        $run = Invoke-ConvertExtract (Join-Path $testData "$Name.csv") $outputFile

        $run.ExitCode | Should -Be 0
        $run.StandardOutput | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $outputFile).Hash | Should -Be (Get-FileHash -LiteralPath $expectedFile).Hash
    }

    It 'writes amounts as numbers, ISO 8601 dates and keys in header order' {
        $source = Write-SourceFile 'payroll.csv' @('employeeId,period,grossAmount,currency', 'EMP-001,2026-11,4200.50,EUR')

        $null = Invoke-ConvertExtract $source $outputFile
        $text = [System.IO.File]::ReadAllText($outputFile)
        $rows = @($text | ConvertFrom-Json)

        $text | Should -Match '"grossAmount":4200.50,'
        $rows[0].grossAmount | Should -BeOfType [double]
        $rows[0].period | Should -Be '2026-11'
        @($rows[0].PSObject.Properties.Name) | Should -Be @('employeeId', 'period', 'grossAmount', 'currency')
    }

    It 'writes UTF-8 without byte order mark and LF line ends, also from a CRLF source' {
        $source = Join-Path $TestDrive 'movements-crlf.csv'
        $crlfLines = "movementId,employeeId,movementType,effectiveDate`r`nMOV-001,EMP-001,role-change,2026-11-02`r`n"
        [System.IO.File]::WriteAllText($source, $crlfLines, [System.Text.UTF8Encoding]::new($true))

        $null = Invoke-ConvertExtract $source $outputFile
        $bytes = [System.IO.File]::ReadAllBytes($outputFile)

        $bytes[0] | Should -Be ([byte][char]'[')
        $bytes | Should -Not -Contain ([byte]13)
        $bytes[-1] | Should -Be ([byte]10)
        ([System.IO.File]::ReadAllText($outputFile) | ConvertFrom-Json).effectiveDate | Should -Be '2026-11-02'
    }

    It 'writes an empty array for a header without rows' {
        $source = Write-SourceFile 'empty.csv' @('movementId,employeeId,movementType,effectiveDate')

        $run = Invoke-ConvertExtract $source $outputFile

        $run.ExitCode | Should -Be 0
        [System.IO.File]::ReadAllText($outputFile) | Should -Be "[]`n"
    }

    It 'rejects the unknown header of FAIL_locked_file.csv without writing an output' {
        $run = Invoke-ConvertExtract (Join-Path $testData 'FAIL_locked_file.csv') $outputFile

        $run.ExitCode | Should -Not -Be 0
        $run.StandardError | Should -BeLike "*Unknown header 'recordId,status'*"
        Test-Path -LiteralPath $outputFile | Should -BeFalse
    }

    It 'rejects a malformed row: <Case>' -TestCases @(
        @{ Case = 'missing field'; Row = 'EMP-001,2026-11,4200.00'; Message = '*Line 3: expected 4 fields, found 3*' },
        @{ Case = 'amount not a number'; Row = 'EMP-001,2026-11,12abc,EUR'; Message = "*Line 3: invalid grossAmount '12abc'*" },
        @{ Case = 'amount with a leading zero'; Row = 'EMP-001,2026-11,0042.00,EUR'; Message = '*Line 3: invalid grossAmount*' },
        @{ Case = 'period not a month'; Row = 'EMP-001,2026-13,4200.00,EUR'; Message = "*Line 3: invalid period '2026-13'*" },
        @{ Case = 'currency in lower case'; Row = 'EMP-001,2026-11,4200.00,eur'; Message = "*Line 3: invalid currency 'eur'*" },
        @{ Case = 'quoted identifier'; Row = '"EMP-001",2026-11,4200.00,EUR'; Message = '*Line 3: invalid employeeId*' }
    ) {
        $source = Write-SourceFile 'malformed.csv' @('employeeId,period,grossAmount,currency', 'EMP-000,2026-11,1.00,EUR', $Row)

        $run = Invoke-ConvertExtract $source $outputFile

        $run.ExitCode | Should -Not -Be 0
        $run.StandardError | Should -BeLike $Message
        Test-Path -LiteralPath $outputFile | Should -BeFalse
    }

    It 'rejects an invalid effective date' {
        $source = Write-SourceFile 'movements.csv' @('movementId,employeeId,movementType,effectiveDate', 'MOV-001,EMP-001,role-change,2026-02-30')

        $run = Invoke-ConvertExtract $source $outputFile

        $run.ExitCode | Should -Not -Be 0
        $run.StandardError | Should -BeLike "*Line 2: invalid effectiveDate '2026-02-30'*"
    }

    It 'fails with a message when the source file does not exist' {
        $run = Invoke-ConvertExtract (Join-Path $TestDrive 'missing.csv') $outputFile

        $run.ExitCode | Should -Not -Be 0
        $run.StandardError | Should -BeLike 'Convert-Extract:*'
    }
}
