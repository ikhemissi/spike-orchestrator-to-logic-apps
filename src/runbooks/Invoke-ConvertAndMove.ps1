# Convert the CSV extracts of a folder to JSON with the worker's local tool, then archive the sources;
# contract in docs/SPEC.md section 5.9. The success stream carries one compressed JSON line only,
# because Logic Apps parses the job output.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $CorrelationId,

    # Mandatory although SPEC section 5.9 marks only CorrelationId so: none has a sensible default.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SourcePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $TargetPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ArchivePath,

    [ValidateNotNullOrEmpty()]
    [string] $ToolPath = 'C:\Tools\OrchestratorSpike\Convert-Extract.ps1',

    [ValidateRange(1, [int]::MaxValue)]
    [int] $MaxFiles = 100,

    [switch] $SimulateFailure
)

$ErrorActionPreference = 'Stop'
$outputLimitBytes = 1MB
# Bounds each error message, whatever the tool prints, so the output size check below holds.
$maxMessageLength = 1000

function Resolve-Directory([string] $Path) {
    # Absolute paths, because the tool process and .NET resolve relative paths against the process directory,
    # which differs from the PowerShell location.
    $directory = Get-Item -LiteralPath $Path
    if (-not $directory.PSIsContainer) {
        throw "Not a directory: $Path"
    }
    return $directory.FullName
}

function Resolve-ToolPath([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The conversion tool is not installed at $Path."
    }
    return (Get-Item -LiteralPath $Path).FullName
}

function Find-PowerShellPath {
    # VERIFY: on a Hybrid Worker, $PSHOME of the PowerShell 7 runtime holds pwsh.exe; PATH is the fallback.
    $executableName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
    $bundledPowerShell = Join-Path $PSHOME $executableName
    if (Test-Path -LiteralPath $bundledPowerShell -PathType Leaf) {
        return $bundledPowerShell
    }
    $pathCommand = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pathCommand) {
        return $pathCommand.Source
    }
    throw 'PowerShell 7 (pwsh) was not found to run the conversion tool.'
}

function Limit-MessageLength([string] $Message) {
    $singleLine = ($Message -replace '\s+', ' ').Trim()
    if ($singleLine.Length -le $maxMessageLength) {
        return $singleLine
    }
    return $singleLine.Substring(0, $maxMessageLength - 3) + '...'
}

function ConvertTo-ResultJson([hashtable] $Run, [object[]] $Items, [object[]] $Errors, [int] $Processed, [int] $Skipped) {
    $result = @{
        correlationId = $Run.CorrelationId
        status = if ($Errors.Count -gt 0) { 'PartialFailure' } else { 'Succeeded' }
        worker = $Run.Worker
        runAs = $Run.RunAs
        filesProcessed = $Processed
        filesSkipped = $Skipped
        filesFailed = $Errors.Count
        items = $Items
        errors = $Errors
        startedAt = $Run.StartedAt.ToString('o')
        completedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    return ConvertTo-Json -InputObject $result -Depth 5 -Compress
}

function Assert-OutputFitsLimit([hashtable] $Run, [System.IO.FileInfo[]] $Files) {
    # Checked before any file moves: a failure after archiving would lose the per-file report on retry.
    $longestMessage = 'x' * $maxMessageLength
    $largestItems = @($Files | ForEach-Object { @{ name = $_.Name; result = 'converted'; sha256 = ('F' * 64); error = $longestMessage } })
    $largestErrors = @($Files | ForEach-Object { @{ code = 'FILE_PROCESSING_FAILED'; message = $longestMessage; file = $_.Name } })
    $largestJson = ConvertTo-ResultJson $Run $largestItems $largestErrors $Files.Count $Files.Count
    if ([System.Text.Encoding]::UTF8.GetByteCount($largestJson) -ge $outputLimitBytes) {
        throw 'Runbook output could exceed the 1 MiB limit; reduce MaxFiles or the CorrelationId length.'
    }
}

function Test-AlreadyConverted([string] $Target, [string] $Sidecar, [string] $Hash) {
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Sidecar -PathType Leaf)) {
        return $false
    }
    $recordedHash = ([string](Get-Content -LiteralPath $Sidecar -Raw)).Trim()
    return $recordedHash -eq $Hash
}

function Invoke-ConversionTool([hashtable] $Settings, [string] $SourceFile, [string] $OutputFile) {
    # Run in its own process, like the local tools of the real jobs: its exit code and standard error are then
    # reliable, and nothing it prints reaches the runbook output parsed by Logic Apps.
    $errorFile = Join-Path ([System.IO.Path]::GetTempPath()) "convert-extract-$([guid]::NewGuid().ToString('N')).err"
    try {
        $toolOutput = & $Settings.PowerShellPath -NoProfile -NonInteractive -File $Settings.ToolPath -SourcePath $SourceFile -OutputPath $OutputFile 2> $errorFile
        $exitCode = $LASTEXITCODE
        foreach ($line in @($toolOutput)) {
            Write-Verbose -Message "Convert-Extract: $line" -Verbose
        }
        $standardError = Get-Content -LiteralPath $errorFile -Raw
        $toolMessage = if ($standardError) { $standardError.Trim() } else { '' }
        if (-not $toolMessage) {
            $toolMessage = "The conversion tool exited with code $exitCode."
        }
        return @{ IsSuccess = ($exitCode -eq 0); Message = $toolMessage }
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Publish-Target([string] $TemporaryTarget, [string] $Target, [string] $Sidecar, [string] $Hash) {
    # Remove the old sidecar first: a stale hash next to a new target would make a later run skip wrongly.
    if (Test-Path -LiteralPath $Sidecar) {
        Remove-Item -LiteralPath $Sidecar
    }
    [System.IO.File]::Move($TemporaryTarget, $Target, $true)
    Set-Content -LiteralPath $Sidecar -Value $Hash -NoNewline
}

function Move-ToArchive([System.IO.FileInfo] $File, [string] $ArchiveDirectory) {
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $archive = Join-Path $ArchiveDirectory "${timestamp}_$($File.Name)"
    # Move-Item refuses an existing destination, so an archive is never overwritten.
    Move-Item -LiteralPath $File.FullName -Destination $archive
}

function ConvertTo-FailedOutcome([string] $FileName, [string] $Code, [string] $Message) {
    $boundedMessage = Limit-MessageLength $Message
    return @{
        Item = @{ name = $FileName; result = 'failed'; sha256 = $null; error = $boundedMessage }
        Error = @{ code = $Code; message = $boundedMessage; file = $FileName }
    }
}

function Invoke-FileStep([hashtable] $Settings, [System.IO.FileInfo] $File) {
    Write-Verbose -Message "Processing $($File.Name)" -Verbose
    if ($Settings.SimulateFailure) {
        return ConvertTo-FailedOutcome $File.Name 'SIMULATED_FAILURE' 'Simulated failure.'
    }
    $hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    $target = Join-Path $Settings.TargetDirectory "$([System.IO.Path]::GetFileNameWithoutExtension($File.Name)).json"
    $sidecar = "$target.sha256"
    $result = 'skipped'
    if (-not (Test-AlreadyConverted $target $sidecar $hash)) {
        # Convert to a temporary file then rename, so a reader never sees a half-written target.
        $temporaryTarget = Join-Path $Settings.TargetDirectory ".$([guid]::NewGuid().ToString('N')).tmp"
        try {
            $conversion = Invoke-ConversionTool $Settings $File.FullName $temporaryTarget
            if (-not $conversion.IsSuccess) {
                Write-Verbose -Message "$($File.Name): invalid input: $($conversion.Message)" -Verbose
                return ConvertTo-FailedOutcome $File.Name 'INVALID_INPUT' $conversion.Message
            }
            Publish-Target $temporaryTarget $target $sidecar $hash
        }
        finally {
            Remove-Item -LiteralPath $temporaryTarget -Force -ErrorAction SilentlyContinue
        }
        $result = 'converted'
    }
    Move-ToArchive $File $Settings.ArchiveDirectory
    Write-Verbose -Message "$($File.Name): $result" -Verbose
    return @{ Item = @{ name = $File.Name; result = $result; sha256 = $hash; error = $null }; Error = $null }
}

$run = @{
    CorrelationId = $CorrelationId
    StartedAt = [DateTimeOffset]::UtcNow
    Worker = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
    RunAs = [string](& whoami)
}
$sourceDirectory = Resolve-Directory $SourcePath
$settings = @{
    ToolPath = Resolve-ToolPath $ToolPath
    PowerShellPath = Find-PowerShellPath
    TargetDirectory = Resolve-Directory $TargetPath
    ArchiveDirectory = Resolve-Directory $ArchivePath
    SimulateFailure = $SimulateFailure.IsPresent
}
$files = @(Get-ChildItem -LiteralPath $sourceDirectory -File -Force | Sort-Object Name | Select-Object -First $MaxFiles)
Assert-OutputFitsLimit $run $files

$items = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    try {
        $outcome = Invoke-FileStep $settings $file
    }
    catch [System.UnauthorizedAccessException] {
        # Access denied on the share is one of the three fatal errors of SPEC section 5.9: the job must end Failed.
        throw
    }
    catch {
        # Any other error concerns this file only: record it, leave the source in place, and carry on,
        # so the single JSON result is always written.
        Write-Verbose -Message "$($file.Name): failed: $($_.Exception.Message)" -Verbose
        $outcome = ConvertTo-FailedOutcome $file.Name 'FILE_PROCESSING_FAILED' $_.Exception.Message
    }
    $items.Add($outcome.Item)
    if ($outcome.Error) {
        $errors.Add($outcome.Error)
    }
}

$processedCount = @($items | Where-Object { $_.result -eq 'converted' }).Count
$skippedCount = @($items | Where-Object { $_.result -eq 'skipped' }).Count
Write-Output (ConvertTo-ResultJson $run $items.ToArray() $errors.ToArray() $processedCount $skippedCount)
