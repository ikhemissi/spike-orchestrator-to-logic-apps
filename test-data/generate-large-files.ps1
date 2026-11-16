# Writes j1/large_partner_extract.csv (~20 MB of synthetic invoices), byte-identical to generate-large-files.sh.
# Values derive from the row number instead of a random generator, so Bash and PowerShell produce the same bytes.
$ErrorActionPreference = 'Stop'

$rowCount = 400000
$outputFile = Join-Path $PSScriptRoot 'j1/large_partner_extract.csv'
$temporaryFile = "$outputFile.tmp"
$null = New-Item -ItemType Directory -Path (Split-Path $outputFile) -Force
# No BOM and LF line endings, to match the Bash output byte for byte.
$encoding = [System.Text.UTF8Encoding]::new($false)
$writer = [System.IO.StreamWriter]::new($temporaryFile, $false, $encoding)

try {
    $writer.Write("invoiceId,partnerId,amount,currency,date`n")
    # [long] keeps the arithmetic integral: rowNumber * 7919 overflows Int32, and PowerShell would switch to double.
    for ([long]$rowNumber = 1; $rowNumber -le $rowCount; $rowNumber++) {
        $partnerNumber = ($rowNumber % 20) + 1
        $amountInCents = ($rowNumber * 7919 % 500000) + 100
        $dayOfMonth = ($rowNumber % 28) + 1
        $line = "INV{0:D10},PARTNER{1:D4},{2}.{3:D2},EUR,2026-11-{4:D2}`n" -f `
            $rowNumber, $partnerNumber, [long][math]::Truncate($amountInCents / 100), ($amountInCents % 100), $dayOfMonth
        $writer.Write($line)
    }
}
catch {
    $writer.Dispose()
    Remove-Item -LiteralPath $temporaryFile -Force
    throw
}
finally {
    $writer.Dispose()
}

Move-Item -LiteralPath $temporaryFile -Destination $outputFile -Force
