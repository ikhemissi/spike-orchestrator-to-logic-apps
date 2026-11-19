# Fallback deployment of src/logicapp without azd (SPEC 2.3): zip honouring .funcignore, deploy, restart, list workflows.
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $scriptDirectory '../src/logicapp')
)

if ([string]::IsNullOrWhiteSpace($env:AZURE_RESOURCE_GROUP)) {
    throw 'Set AZURE_RESOURCE_GROUP to the Logic App resource group.'
}
if ([string]::IsNullOrWhiteSpace($env:LOGIC_APP_NAME)) {
    throw 'Set LOGIC_APP_NAME to the Logic App name.'
}

$ignoreFile = Join-Path $projectDirectory '.funcignore'
if (-not (Test-Path -LiteralPath $ignoreFile -PathType Leaf)) {
    throw "Missing .funcignore in $projectDirectory"
}

# Simplified .funcignore reading (no negation): a pattern with a slash matches the whole relative path,
# otherwise it matches any path segment. Case-insensitive, like the bash version.
function Test-FuncIgnore {
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath,
        [Parameter(Mandatory)]
        [string[]] $Patterns
    )

    foreach ($pattern in $Patterns) {
        $pattern = $pattern.Trim()
        if ([string]::IsNullOrWhiteSpace($pattern) -or $pattern.StartsWith('#')) {
            continue
        }

        $pattern = $pattern.TrimEnd('/')
        if ($pattern.Contains('/')) {
            if ($RelativePath -like $pattern) {
                return $true
            }
            continue
        }

        foreach ($segment in ($RelativePath -split '/')) {
            if ($segment -like $pattern) {
                return $true
            }
        }
    }

    return $false
}

function Invoke-Az {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    & az @Arguments
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Azure CLI failed with exit code $LASTEXITCODE."
    }
}

$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "logicapp-deploy-$([guid]::NewGuid()).zip"
$archive = $null

try {
    $ignorePatterns = Get-Content -LiteralPath $ignoreFile
    $filesToZip = @(
        Get-ChildItem -LiteralPath $projectDirectory -File -Recurse -Force |
            ForEach-Object {
                $relativePath = [System.IO.Path]::GetRelativePath(
                    $projectDirectory,
                    $_.FullName
                ).Replace('\', '/')
                if (-not (Test-FuncIgnore -RelativePath $relativePath -Patterns $ignorePatterns)) {
                    [pscustomobject]@{
                        FullName = $_.FullName
                        RelativePath = $relativePath
                    }
                }
            }
    )

    if ($filesToZip.Count -eq 0) {
        throw "No deployable files found in $projectDirectory"
    }

    Add-Type -AssemblyName System.IO.Compression
    $archive = [System.IO.Compression.ZipFile]::Open(
        $zipPath,
        [System.IO.Compression.ZipArchiveMode]::Create
    )
    foreach ($file in $filesToZip) {
        $entry = $archive.CreateEntry($file.RelativePath)
        $sourceStream = [System.IO.File]::OpenRead($file.FullName)
        $destinationStream = $entry.Open()
        try {
            $sourceStream.CopyTo($destinationStream)
        }
        finally {
            $destinationStream.Dispose()
            $sourceStream.Dispose()
        }
    }
    $archive.Dispose()
    $archive = $null

    Invoke-Az -Arguments @(
        'logicapp', 'deployment', 'source', 'config-zip',
        '--resource-group', $env:AZURE_RESOURCE_GROUP,
        '--name', $env:LOGIC_APP_NAME,
        '--src', $zipPath
    )
    Invoke-Az -Arguments @(
        'logicapp', 'restart',
        '--resource-group', $env:AZURE_RESOURCE_GROUP,
        '--name', $env:LOGIC_APP_NAME
    )

    $subscriptionId = & az account show --query id --output tsv
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Azure CLI failed with exit code $LASTEXITCODE."
    }
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw 'Azure CLI did not return a subscription ID.'
    }

    $workflowApiUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers/Microsoft.Web/sites/$($env:LOGIC_APP_NAME)/hostruntime/runtime/webhooks/workflow/api/management/workflows?api-version=2018-11-01"
    # The runtime answers 503 for a while after the restart.
    $retrySeconds = if ($env:DEPLOY_RETRY_SECONDS) { [int]$env:DEPLOY_RETRY_SECONDS } else { 30 }
    $unhealthy = $null
    foreach ($attempt in 1..10) {
        try {
            # A workflow with an invalid definition still deploys; the runtime marks it Unhealthy and disables its trigger.
            $unhealthy = Invoke-Az -Arguments @(
                'rest', '--method', 'get', '--url', $workflowApiUrl, '--output', 'tsv',
                '--query', "[?health.state!='Healthy'].{workflow: name, error: health.errorMessage.error.message}"
            )
            break
        }
        catch {
            if ($attempt -eq 10) { throw 'The workflow runtime did not answer after the restart.' }
            Write-Warning "The workflow runtime is not ready yet (attempt $attempt/10); retrying in $retrySeconds s."
            Start-Sleep -Seconds $retrySeconds
        }
    }
    if ($unhealthy) {
        throw "Unhealthy workflows after the deployment:`n$($unhealthy -join "`n")"
    }
    Write-Output 'All workflows are healthy.'
}
finally {
    if ($null -ne $archive) {
        $archive.Dispose()
    }
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
}
