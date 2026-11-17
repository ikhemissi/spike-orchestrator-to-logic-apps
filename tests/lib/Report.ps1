# Test report for the runner: one summary table per run, appended to docs/TEST-REPORT.md as evidence.

function ConvertTo-ReportCell {
    param([object]$Value)

    if ($null -eq $Value) {
        return ''
    }
    $text = if ($Value -is [string]) { $Value } else { ConvertTo-Json -InputObject $Value -Depth 20 -Compress }
    return $text.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function Format-TestSummary {
    param([Parameter(Mandatory)][object[]]$Results)

    $lines = @(
        '| Scenario | Result | Run ID | Run status | Action statuses | Tracked properties | File listings | Details |',
        '| --- | --- | --- | --- | --- | --- | --- | --- |'
    )
    foreach ($result in $Results) {
        $actions = @{}
        foreach ($action in @($result.Actions | Where-Object { $_ })) {
            $actions[$action.name] = $action.properties.status
        }
        $cells = @(
            $result.Name,
            $result.Result,
            $result.RunId,
            $result.Status,
            (ConvertTo-ReportCell $actions),
            (ConvertTo-ReportCell $result.TrackedProperties),
            (ConvertTo-ReportCell $result.FileListings),
            (ConvertTo-ReportCell $result.Details)
        )
        $lines += '| ' + ($cells -join ' | ') + ' |'
    }
    return $lines -join [Environment]::NewLine
}

function Write-TestReport {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # Each run appends its own section, so earlier evidence stays in the report.
    $runSection = "## Run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')`n`n$(Format-TestSummary -Results $Results)`n"
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [IO.File]::AppendAllText($Path, "`n" + $runSection, $utf8WithoutBom)
    }
    else {
        [IO.File]::WriteAllText($Path, "# Test report`n`n" + $runSection, $utf8WithoutBom)
    }
    return $runSection
    return $report
}
