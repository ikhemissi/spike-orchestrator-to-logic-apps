# Checks the synthetic test data of SPEC section 7: every file exists, CSV headers and row counts, PDF signatures, XML,
# and that the Bash and PowerShell generators write the same large file (same SHA-256).

BeforeAll {
    $script:repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:testDataRoot = Join-Path $script:repositoryRoot 'test-data'
    $script:largeFile = Join-Path $script:testDataRoot 'j1/large_partner_extract.csv'
    $script:largeFileGenerators = @(
        (Join-Path $script:testDataRoot 'generate-large-files.sh'),
        (Join-Path $script:testDataRoot 'generate-large-files.ps1')
    )

    & bash $script:largeFileGenerators[0]
    if ($LASTEXITCODE -ne 0) {
        throw 'The Bash large-file generator failed.'
    }
    $script:bashHash = (Get-FileHash -LiteralPath $script:largeFile -Algorithm SHA256).Hash

    & pwsh -NoProfile -File $script:largeFileGenerators[1]
    if ($LASTEXITCODE -ne 0) {
        throw 'The PowerShell large-file generator failed.'
    }
    $script:powershellHash = (Get-FileHash -LiteralPath $script:largeFile -Algorithm SHA256).Hash

    $script:expectedFiles = @(
        'j1/invoices_20261124_001.csv',
        'j1/invoices_20261124_002.csv',
        'j1/~lock_invoices.csv',
        'j1/large_partner_extract.csv',
        'j2/brochure_export_fr.pdf',
        'j2/participants_salon_2026.csv',
        'j3/payroll_extract_202611.csv',
        'j3/hr_movements_202611.csv',
        'j3/FAIL_locked_file.csv',
        'j4/budget_q4.csv',
        'j4/contract_partner_x.pdf',
        'j4/order_000123.xml',
        'j4/unknown_payload.dat',
        'j5/folderwatch_test.txt'
    )

    $script:csvExpectations = @(
        @{ Path = 'j1/invoices_20261124_001.csv'; Header = 'invoiceId,partnerId,amount,currency,date'; Rows = 20 },
        @{ Path = 'j1/invoices_20261124_002.csv'; Header = 'invoiceId,partnerId,amount,currency,date'; Rows = 20 },
        @{ Path = 'j1/~lock_invoices.csv'; Header = 'invoiceId,partnerId,amount,currency,date'; Rows = 20 },
        @{ Path = 'j1/large_partner_extract.csv'; Header = 'invoiceId,partnerId,amount,currency,date'; Rows = 400000 },
        @{ Path = 'j2/participants_salon_2026.csv'; Header = 'participantId,organization,registrationType'; Rows = 20 },
        @{ Path = 'j3/payroll_extract_202611.csv'; Header = 'employeeId,period,grossAmount,currency'; Rows = 20 },
        @{ Path = 'j3/hr_movements_202611.csv'; Header = 'movementId,employeeId,movementType,effectiveDate'; Rows = 20 },
        @{ Path = 'j3/FAIL_locked_file.csv'; Header = 'recordId,status'; Rows = 20 },
        @{ Path = 'j4/budget_q4.csv'; Header = 'costCenter,period,budget,currency'; Rows = 20 }
    )
}

Describe 'Synthetic test data' {
    It 'contains every fixture required by SPEC section 7' {
        foreach ($relativePath in $script:expectedFiles) {
            $path = Join-Path $script:testDataRoot $relativePath
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue -Because $relativePath
        }

        foreach ($generator in $script:largeFileGenerators) {
            Test-Path -LiteralPath $generator -PathType Leaf | Should -BeTrue -Because $generator
        }
    }

    It 'has the expected headers and data row counts in each CSV' {
        foreach ($expectation in $script:csvExpectations) {
            $path = Join-Path $script:testDataRoot $expectation.Path
            $reader = [System.IO.StreamReader]::new($path)

            try {
                $header = $reader.ReadLine()
                $dataRowCount = 0
                while ($null -ne $reader.ReadLine()) {
                    $dataRowCount++
                }
            }
            finally {
                $reader.Dispose()
            }

            $header | Should -Be $expectation.Header -Because $expectation.Path
            $dataRowCount | Should -Be $expectation.Rows -Because $expectation.Path
        }
    }

    It 'starts both PDFs with the PDF signature' {
        foreach ($relativePath in @('j2/brochure_export_fr.pdf', 'j4/contract_partner_x.pdf')) {
            $path = Join-Path $script:testDataRoot $relativePath
            $stream = [System.IO.File]::OpenRead($path)
            $signature = [byte[]]::new(5)

            try {
                $null = $stream.Read($signature, 0, $signature.Length)
            }
            finally {
                $stream.Dispose()
            }

            [System.Text.Encoding]::ASCII.GetString($signature) | Should -Be '%PDF-' -Because $relativePath
        }
    }

    It 'contains well-formed XML for the sample order' {
        $path = Join-Path $script:testDataRoot 'j4/order_000123.xml'
        { [xml](Get-Content -LiteralPath $path -Raw) } | Should -Not -Throw
    }

    It 'generates identical large CSV content from Bash and PowerShell' {
        $script:powershellHash | Should -Be $script:bashHash
    }
}
