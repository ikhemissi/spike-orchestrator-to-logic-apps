# Encrypt the files of a folder with GPG, then archive the sources; contract in docs/SPEC.md section 5.9.
# The success stream carries one compressed JSON line only, because Logic Apps parses the job output.
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

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Recipient,

    [ValidateRange(1, [int]::MaxValue)]
    [int] $MaxFiles = 100,

    [switch] $SimulateFailure
)

$ErrorActionPreference = 'Stop'
$outputLimitBytes = 1MB

function Find-GpgPath {
    $gpgCommand = Get-Command gpg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gpgCommand) {
        return $gpgCommand.Source
    }
    if (-not $IsWindows) {
        throw 'GPG is not installed or not on PATH.'
    }
    # VERIFY: Gpg4win 5 (64-bit) installs GnuPG under Program Files, Gpg4win 4 (32-bit) under Program Files (x86).
    foreach ($programFiles in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programFiles) {
            continue
        }
        $defaultGpgPath = Join-Path $programFiles 'GnuPG' 'bin' 'gpg.exe'
        if (Test-Path -LiteralPath $defaultGpgPath -PathType Leaf) {
            return $defaultGpgPath
        }
    }
    throw 'GPG is not installed: not on PATH nor in the Gpg4win default folder.'
}

function Resolve-Directory([string] $Path) {
    # Absolute paths, because gpg and .NET resolve relative paths against the process directory,
    # which differs from the PowerShell location.
    $directory = Get-Item -LiteralPath $Path
    if (-not $directory.PSIsContainer) {
        throw "Not a directory: $Path"
    }
    return $directory.FullName
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
    $largestItems = @($Files | ForEach-Object { @{ name = $_.Name; result = 'encrypted'; sha256 = ('F' * 64); error = 'SIMULATED_FAILURE' } })
    $largestErrors = @($Files | ForEach-Object { @{ code = 'SIMULATED_FAILURE'; message = 'Simulated failure.'; file = $_.Name } })
    $largestJson = ConvertTo-ResultJson $Run $largestItems $largestErrors $Files.Count $Files.Count
    if ([System.Text.Encoding]::UTF8.GetByteCount($largestJson) -ge $outputLimitBytes) {
        throw 'Runbook output could exceed the 1 MiB limit; reduce MaxFiles or the CorrelationId length.'
    }
}

function Test-AlreadyEncrypted([string] $Target, [string] $Sidecar, [string] $Hash) {
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Sidecar -PathType Leaf)) {
        return $false
    }
    $recordedHash = ([string](Get-Content -LiteralPath $Sidecar -Raw)).Trim()
    return $recordedHash -eq $Hash
}

function Protect-File([string] $GpgPath, [string] $Recipient, [System.IO.FileInfo] $File, [string] $Target, [string] $Sidecar, [string] $Hash) {
    # Encrypt to a temporary file then rename, so a reader never sees a half-written target.
    $temporaryTarget = Join-Path (Split-Path -Parent $Target) ".$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $gpgMessages = & $GpgPath --batch --yes --trust-model always --recipient $Recipient --output $temporaryTarget --encrypt $File.FullName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "GPG encryption failed for $($File.Name): $($gpgMessages -join ' ')"
        }
        # Remove the old sidecar first: a stale hash next to new ciphertext would make a later run skip wrongly.
        if (Test-Path -LiteralPath $Sidecar) {
            Remove-Item -LiteralPath $Sidecar
        }
        [System.IO.File]::Move($temporaryTarget, $Target, $true)
        Set-Content -LiteralPath $Sidecar -Value $Hash -NoNewline
    }
    finally {
        if (Test-Path -LiteralPath $temporaryTarget) {
            Remove-Item -LiteralPath $temporaryTarget -Force
        }
    }
}

function Move-ToArchive([System.IO.FileInfo] $File, [string] $ArchiveDirectory) {
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $archive = Join-Path $ArchiveDirectory "${timestamp}_$($File.Name)"
    # Move-Item refuses an existing destination, so an archive is never overwritten.
    Move-Item -LiteralPath $File.FullName -Destination $archive
}

function Invoke-FileStep([hashtable] $Settings, [System.IO.FileInfo] $File) {
    Write-Verbose -Message "Processing $($File.Name)" -Verbose
    # Case-sensitive on purpose: the fault injection marker is the upper-case word FAIL.
    if ($Settings.SimulateFailure -or $File.Name -clike '*FAIL*') {
        return @{ name = $File.Name; result = 'failed'; sha256 = $null; error = 'SIMULATED_FAILURE' }
    }
    $hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    $target = Join-Path $Settings.TargetDirectory "$($File.Name).gpg"
    $sidecar = "$target.sha256"
    $result = 'skipped'
    if (-not (Test-AlreadyEncrypted $target $sidecar $hash)) {
        Protect-File $Settings.GpgPath $Settings.Recipient $File $target $sidecar $hash
        $result = 'encrypted'
    }
    Move-ToArchive $File $Settings.ArchiveDirectory
    Write-Verbose -Message "$($File.Name): $result" -Verbose
    return @{ name = $File.Name; result = $result; sha256 = $hash; error = $null }
}

$run = @{
    CorrelationId = $CorrelationId
    StartedAt = [DateTimeOffset]::UtcNow
    Worker = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
    RunAs = [string](& whoami)
}
$settings = @{
    GpgPath = Find-GpgPath
    Recipient = $Recipient
    TargetDirectory = Resolve-Directory $TargetPath
    ArchiveDirectory = Resolve-Directory $ArchivePath
    SimulateFailure = $SimulateFailure.IsPresent
}
$sourceDirectory = Resolve-Directory $SourcePath
$files = @(Get-ChildItem -LiteralPath $sourceDirectory -File -Force | Sort-Object Name | Select-Object -First $MaxFiles)
Assert-OutputFitsLimit $run $files

$items = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    try {
        $item = Invoke-FileStep $settings $file
    }
    catch [System.UnauthorizedAccessException] {
        # Access denied on the share is one of the three fatal errors of SPEC section 5.9: the job must end Failed.
        throw
    }
    catch {
        # Any other error concerns this file only: record it, leave the source in place, and carry on,
        # so the single JSON result is always written.
        $message = $_.Exception.Message
        Write-Verbose -Message "$($file.Name): failed: $message" -Verbose
        $items.Add(@{ name = $file.Name; result = 'failed'; sha256 = $null; error = $message })
        $errors.Add(@{ code = 'FILE_PROCESSING_FAILED'; message = $message; file = $file.Name })
        continue
    }
    $items.Add($item)
    if ($item.result -eq 'failed') {
        $errors.Add(@{ code = $item.error; message = 'Simulated failure.'; file = $item.name })
    }
}

$processedCount = @($items | Where-Object { $_.result -eq 'encrypted' }).Count
$skippedCount = @($items | Where-Object { $_.result -eq 'skipped' }).Count
Write-Output (ConvertTo-ResultJson $run $items.ToArray() $errors.ToArray() $processedCount $skippedCount)
