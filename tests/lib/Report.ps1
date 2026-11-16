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
        foreach ($action in @($result.Actions)) {
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
    $report = "# Test report`n`nGenerated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz').`n`n$(Format-TestSummary -Results $Results)`n"
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [IO.File]::AppendAllText($Path, [Environment]::NewLine + $report, [Text.UTF8Encoding]::new($false))
    }
    else {
        Set-Content -LiteralPath $Path -Value $report -Encoding utf8 -NoNewline
    }
    return $report
}
