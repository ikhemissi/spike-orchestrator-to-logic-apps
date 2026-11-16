# Encrypt source files with GPG and archive them after successful processing.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $CorrelationId,

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
$startedAt = [DateTimeOffset]::UtcNow

$gpgCommand = Get-Command gpg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$gpgPath = if ($gpgCommand) { $gpgCommand.Source } else { $null }
if (-not $gpgPath -and $IsWindows -and ${env:ProgramFiles(x86)}) {
    $defaultGpgPath = Join-Path ${env:ProgramFiles(x86)} 'GnuPG' 'bin' 'gpg.exe'
    if (Test-Path -LiteralPath $defaultGpgPath -PathType Leaf) {
        $gpgPath = $defaultGpgPath
    }
}
if (-not $gpgPath) {
    throw 'GPG is not installed or available on PATH.'
}

foreach ($directory in @($SourcePath, $TargetPath, $ArchivePath)) {
    $item = Get-Item -LiteralPath $directory
    if (-not $item.PSIsContainer) {
        throw "Not a directory: $directory"
    }
}

$SourcePath = (Get-Item -LiteralPath $SourcePath).FullName
$TargetPath = (Get-Item -LiteralPath $TargetPath).FullName
$ArchivePath = (Get-Item -LiteralPath $ArchivePath).FullName
$files = @(Get-ChildItem -LiteralPath $SourcePath -File -Force | Sort-Object Name | Select-Object -First $MaxFiles)
$runAs = & whoami
if ($LASTEXITCODE -ne 0) {
    throw 'Could not determine the runbook identity.'
}
$worker = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }

$largestItems = @(
    foreach ($file in $files) {
        @{ name = $file.Name; result = 'encrypted'; sha256 = ('F' * 64); error = 'SIMULATED_FAILURE' }
    }
)
$largestErrors = @(
    foreach ($file in $files) {
        @{ code = 'SIMULATED_FAILURE'; message = 'Simulated failure.'; file = $file.Name }
    }
)
$largestResult = @{
    correlationId = $CorrelationId
    status = 'PartialFailure'
    worker = $worker
    runAs = $runAs
    filesProcessed = $files.Count
    filesSkipped = $files.Count
    filesFailed = $files.Count
    items = $largestItems
    errors = $largestErrors
    startedAt = $startedAt.ToString('o')
    completedAt = $startedAt.ToString('o')
}
$largestJson = ConvertTo-Json -InputObject $largestResult -Depth 5 -Compress
if ([System.Text.Encoding]::UTF8.GetByteCount($largestJson) -ge 1MB) {
    throw 'Runbook output could exceed the 1 MiB limit; reduce MaxFiles or CorrelationId length.'
}

$items = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()
$filesProcessed = 0
$filesSkipped = 0

foreach ($file in $files) {
    Write-Verbose "Processing $($file.Name)"
    if ($SimulateFailure -or $file.Name -like '*FAIL*') {
        $message = 'Simulated failure.'
        $items.Add(@{ name = $file.Name; result = 'failed'; sha256 = $null; error = 'SIMULATED_FAILURE' })
        $errors.Add(@{ code = 'SIMULATED_FAILURE'; message = $message; file = $file.Name })
        continue
    }

    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $target = Join-Path $TargetPath "$($file.Name).gpg"
    $sidecar = "$target.sha256"
    $archive = Join-Path $ArchivePath "$((Get-Date).ToString('yyyyMMdd-HHmmss'))_$($file.Name)"

    if ((Test-Path -LiteralPath $target -PathType Leaf) -and
        (Test-Path -LiteralPath $sidecar -PathType Leaf) -and
        (([string](Get-Content -LiteralPath $sidecar -Raw)).Trim() -eq $hash)) {
        Move-Item -LiteralPath $file.FullName -Destination $archive
        $filesSkipped++
        $items.Add(@{ name = $file.Name; result = 'skipped'; sha256 = $hash; error = $null })
        continue
    }

    $temporaryTarget = Join-Path $TargetPath ".$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $gpgMessages = & $gpgPath --batch --yes --trust-model always --recipient $Recipient --output $temporaryTarget --encrypt $file.FullName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "GPG encryption failed for $($file.Name): $($gpgMessages -join ' ')"
        }
        if (Test-Path -LiteralPath $sidecar) {
            Remove-Item -LiteralPath $sidecar
        }
        [System.IO.File]::Move($temporaryTarget, $target, $true)
        Set-Content -LiteralPath $sidecar -Value $hash -NoNewline
        Move-Item -LiteralPath $file.FullName -Destination $archive
    }
    finally {
        if (Test-Path -LiteralPath $temporaryTarget) {
            Remove-Item -LiteralPath $temporaryTarget -Force
        }
    }

    $filesProcessed++
    $items.Add(@{ name = $file.Name; result = 'encrypted'; sha256 = $hash; error = $null })
}

$status = if ($errors.Count -gt 0) { 'PartialFailure' } else { 'Succeeded' }
$result = @{
    correlationId = $CorrelationId
    status = $status
    worker = $worker
    runAs = $runAs
    filesProcessed = $filesProcessed
    filesSkipped = $filesSkipped
    filesFailed = $errors.Count
    items = @($items.ToArray())
    errors = @($errors.ToArray())
    startedAt = $startedAt.ToString('o')
    completedAt = [DateTimeOffset]::UtcNow.ToString('o')
}
$json = ConvertTo-Json -InputObject $result -Depth 5 -Compress
if ([System.Text.Encoding]::UTF8.GetByteCount($json) -ge 1MB) {
    throw 'Runbook output exceeds the 1 MiB limit; reduce MaxFiles.'
}
Write-Output $json
