# Encrypt and move runbook

`Invoke-EncryptAndMove.ps1` requires PowerShell 7.4, GPG and an accessible
public key for `Recipient`. Supply `CorrelationId`, `SourcePath`, `TargetPath`,
`ArchivePath` and `Recipient` (all mandatory: none has a sensible default);
`MaxFiles` defaults to 100. Directories must already exist. GPG is found on
PATH or in the default Gpg4win folder under `Program Files` or
`Program Files (x86)`.

Files are processed in name order. Encrypted output is written as `<name>.gpg`
with a SHA-256 sidecar; a matching target and sidecar skips encryption. Both
processed and skipped source files are archived with a timestamp prefix. A name
containing the upper-case marker `FAIL` (case-sensitive, so `failover.txt` is
processed) or the `-SimulateFailure` switch records a per-file failure.
The hash-only skip rule assumes the recipient remains the same between runs;
changing recipients requires removing the existing target or sidecar.
Progress goes to `Write-Verbose -Verbose`; the only success-stream output is
one compressed JSON result with counts,
items, errors, worker, identity and timestamps, as specified in SPEC §5.9.
Infrastructure errors throw. If the result could reach 1 MiB, the runbook
throws before processing; reduce `MaxFiles` or `CorrelationId` length.
Archive name collisions also throw rather than overwrite an existing archive.

Run the tests on Linux or Windows with PowerShell 7.4, Pester 5 or later, and
GPG on PATH:

```powershell
Invoke-Pester -Path ./src/runbooks/tests/Invoke-EncryptAndMove.Tests.ps1 -Output Detailed
```

The tests generate and remove an isolated, temporary GPG keyring.
