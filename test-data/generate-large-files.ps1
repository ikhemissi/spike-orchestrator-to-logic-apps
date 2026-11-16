$ErrorActionPreference = 'Stop'

$scriptDirectory = $PSScriptRoot
$outputFile = Join-Path $scriptDirectory 'j1/large_partner_extract.csv'
$temporaryFile = "$outputFile.tmp"
$null = New-Item -ItemType Directory -Path (Split-Path $outputFile) -Force
$encoding = [System.Text.UTF8Encoding]::new($false)
$writer = [System.IO.StreamWriter]::new($temporaryFile, $false, $encoding)

try {
    $writer.Write("invoiceId,partnerId,amount,currency,date`n")
    for ($rowNumber = 1; $rowNumber -le 400000; $rowNumber++) {
        $partnerNumber = ($rowNumber % 20) + 1
        $writer.Write(("INV{0:D10},PARTNER{1:D4},1234.56,EUR,2026-11-24`n" -f $rowNumber, $partnerNumber))
    }
}
finally {
    $writer.Dispose()
}

Move-Item -LiteralPath $temporaryFile -Destination $outputFile -Force
