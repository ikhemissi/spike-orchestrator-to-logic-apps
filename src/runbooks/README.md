# Encrypt and move runbook

`Invoke-EncryptAndMove.ps1` requires PowerShell 7.4, GPG and an accessible
public key for `Recipient`. Supply `CorrelationId`, `SourcePath`, `TargetPath`,
`ArchivePath` and `Recipient` (all mandatory: none has a sensible default);
`MaxFiles` defaults to 100. Directories must already exist.

GPG location: an Automation job on a Windows worker may not see machine-wide
`PATH` or `GNUPGHOME` changes, so each value is taken from, in order:

1. the optional parameters `-GpgPath` and `-GpgHomeDir`;
2. `gpgPath` and `homeDir` in `%ProgramData%\OrchestratorSpike\gpg.json`,
   for example `{"gpgPath": "C:\\Program Files\\GnuPG\\bin\\gpg.exe", "homeDir": "D:\\gnupg"}`;
3. `gpg` on PATH or the default Gpg4win folder under `Program Files` or
   `Program Files (x86)`, and gpg's default home.

When a home directory is known, gpg runs with `--homedir`. A configured gpg
path or home directory that does not exist is fatal.

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
Only the fatal errors of SPEC section 5.9 throw (source path not reachable, gpg
not installed, access denied on the share). Any other error on one file (locked
source, gpg failure, archive name collision) is recorded as a failed item with
an error `FILE_PROCESSING_FAILED`; that source stays in place, the other files
are processed, and the status is `PartialFailure`. If the result could reach 1 MiB, the runbook
throws before processing; reduce `MaxFiles` or `CorrelationId` length.
An existing archive is never overwritten: a name collision fails that file.

Run the tests on Linux or Windows with PowerShell 7.4, Pester 5 or later, and
GPG on PATH:

```powershell
Invoke-Pester -Path ./src/runbooks/tests/Invoke-EncryptAndMove.Tests.ps1 -Output Detailed
```

The tests generate and remove an isolated, temporary GPG keyring.
