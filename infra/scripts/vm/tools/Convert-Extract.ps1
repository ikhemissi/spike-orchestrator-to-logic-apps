# Convert a J3 CSV extract (payroll or HR movements) to a JSON array: the local tool of the workers, docs/SPEC.md section 5.9.
# Exits 1 with a message on standard error when the header is unknown or a row is malformed; nothing is written then.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SourcePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

# The JSON text is written by hand, not with ConvertTo-Json, because its number formatting differs between
# PowerShell versions and the output is compared byte-for-byte with test-data/j3/expected/.
$extractFormats = @(
    @{ Header = 'employeeId,period,grossAmount,currency'; FieldTypes = @('identifier', 'yearMonth', 'amount', 'currency') },
    @{ Header = 'movementId,employeeId,movementType,effectiveDate'; FieldTypes = @('identifier', 'identifier', 'identifier', 'date') }
)

function Test-ExactDate([string] $Value, [string] $Format) {
    $parsedDate = [datetime]::MinValue
    return [datetime]::TryParseExact($Value, $Format, [cultureinfo]::InvariantCulture, 'None', [ref] $parsedDate)
}

function ConvertTo-JsonValue([string] $Value, [string] $FieldType, [string] $FieldName, [int] $LineNumber) {
    # Each type accepts only values that need no JSON escaping, so they are written as they are.
    switch ($FieldType) {
        'amount' { if ($Value -match '^-?(0|[1-9][0-9]*)(\.[0-9]+)?$') { return $Value } }
        'date' { if (Test-ExactDate $Value 'yyyy-MM-dd') { return "`"$Value`"" } }
        'yearMonth' { if (Test-ExactDate $Value 'yyyy-MM') { return "`"$Value`"" } }
        'currency' { if ($Value -cmatch '^[A-Z]{3}$') { return "`"$Value`"" } }
        'identifier' { if ($Value -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return "`"$Value`"" } }
    }
    throw "Line ${LineNumber}: invalid $FieldName '$Value'."
}

function ConvertTo-JsonObjectText([string] $Line, [int] $LineNumber, [string[]] $FieldNames, [string[]] $FieldTypes) {
    $values = $Line.Split(',')
    if ($values.Count -ne $FieldNames.Count) {
        throw "Line ${LineNumber}: expected $($FieldNames.Count) fields, found $($values.Count)."
    }
    $members = for ($index = 0; $index -lt $FieldNames.Count; $index++) {
        $jsonValue = ConvertTo-JsonValue $values[$index] $FieldTypes[$index] $FieldNames[$index] $LineNumber
        "`"$($FieldNames[$index])`":$jsonValue"
    }
    return '{' + ($members -join ',') + '}'
}

function ConvertTo-ExtractJson([string] $SourceFile) {
    # ReadAllLines accepts LF and CRLF line ends and drops a UTF-8 byte order mark.
    $lines = [System.IO.File]::ReadAllLines($SourceFile)
    if ($lines.Count -eq 0) {
        throw 'The file is empty: no header.'
    }
    $format = $extractFormats | Where-Object { $_.Header -ceq $lines[0] } | Select-Object -First 1
    if (-not $format) {
        $knownHeaders = ($extractFormats | ForEach-Object { "'$($_.Header)'" }) -join ' or '
        throw "Unknown header '$($lines[0])'; expected $knownHeaders."
    }
    $fieldNames = $format.Header.Split(',')
    $objectTexts = @(for ($index = 1; $index -lt $lines.Count; $index++) {
            ConvertTo-JsonObjectText $lines[$index] ($index + 1) $fieldNames $format.FieldTypes
        })
    if ($objectTexts.Count -eq 0) {
        return "[]`n"
    }
    return "[`n  " + ($objectTexts -join ",`n  ") + "`n]`n"
}

try {
    # Resolved here because .NET resolves relative paths against the process directory, not the PowerShell location.
    $sourceFile = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($SourcePath)
    $outputFile = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $json = ConvertTo-ExtractJson $sourceFile
    [System.IO.File]::WriteAllText($outputFile, $json, [System.Text.UTF8Encoding]::new($false))
}
catch {
    [Console]::Error.WriteLine("Convert-Extract: $($_.Exception.Message)")
    exit 1
}
exit 0
