# Convert and move runbook

`Invoke-ConvertAndMove.ps1` (PowerShell 7.4) converts the CSV extracts of a
folder to JSON with the worker's local conversion tool, then archives the
sources (SPEC section 5.9, decision D3).

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `CorrelationId` | — | mandatory |
| `SourcePath`, `TargetPath`, `ArchivePath` | — | mandatory (no sensible default); the folders must exist |
| `ToolPath` | `C:\Tools\OrchestratorSpike\Convert-Extract.ps1` | the local tool, from `infra/scripts/vm/tools/` |
| `MaxFiles` | 100 | files are processed in name order |
| `SimulateFailure` | off | every file fails with `SIMULATED_FAILURE` and stays in place |

## Behaviour

- For each file, the runbook computes the SHA-256 of the source. The target is
  `<TargetPath>/<basename>.json`, with a sidecar `<basename>.json.sha256`
  holding the source hash. When the target exists and the sidecar has the same
  hash, the file is `skipped`; otherwise the tool converts it to a temporary
  file, which is renamed to the target (atomic), and the sidecar is written:
  `converted`. Converted and skipped sources move to
  `<ArchivePath>/<yyyyMMdd-HHmmss>_<name>`; an existing archive is never
  overwritten.
- The tool runs in its own `pwsh` process:
  `pwsh -File <ToolPath> -SourcePath <source> -OutputPath <tmp>`. A non-zero
  exit is a per-file `INVALID_INPUT` error with the tool's message (for
  example, the unknown header of `FAIL_locked_file.csv`). There is no
  name-based failure rule.
- Any other error on one file (locked source, archive name collision) is a
  per-file `FILE_PROCESSING_FAILED` error. A failed file stays in place, the
  other files are processed, and the status is `PartialFailure`.
- Fatal errors throw, so the job ends Failed: source path not reachable,
  conversion tool not installed at `ToolPath`, access denied on the share (any
  `UnauthorizedAccessException`).
- Progress goes to `Write-Verbose -Verbose`. The only success-stream output is
  one compressed JSON result with counts, items (`converted`, `skipped` or
  `failed`), errors, worker, identity and timestamps. Error messages are cut
  at 1000 characters. If the result could reach 1 MiB, the runbook throws
  before processing; reduce `MaxFiles` or the `CorrelationId` length.

## Local conversion tool

`infra/scripts/vm/tools/Convert-Extract.ps1 -SourcePath <csv> -OutputPath <json>`
accepts the headers `employeeId,period,grossAmount,currency` and
`movementId,employeeId,movementType,effectiveDate`. It writes a JSON array,
one object per line, with keys in header order: amounts as JSON numbers as
written in the source, `period` as `yyyy-MM` and `effectiveDate` as
`yyyy-MM-dd` (ISO 8601). Output is UTF-8 without BOM, with LF line ends. An
unknown header or a malformed row (wrong field count, invalid amount, date,
currency or identifier, quoted fields) exits 1 with a message on standard
error, and nothing is written. `test-data/j3/expected/` holds the output for
the two valid extracts.

## Tests

Run on Linux or Windows with PowerShell 7.4 and Pester 5 or later; no other
tool is needed:

```powershell
Invoke-Pester -Path ./src/runbooks/tests, ./infra/scripts/vm/tests/Convert-Extract.Tests.ps1 -Output Detailed
```

The runbook tests run the real tool against temporary folders; the tool tests
check its output byte for byte against `test-data/j3/expected/`.
