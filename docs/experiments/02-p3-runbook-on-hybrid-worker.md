# 02 — P3: a runbook on the hybrid worker converts files on the NAS

**Date:** 2026-11-18 · **Answers:** Q4 · **Versions:** Azure Automation (API `2024-10-23`), runtime environment PowerShell 7.4, Hybrid Worker extension for Windows 1.3, Windows Server 2022

## Goal

Show that a job started in Azure Automation runs on the hybrid worker in the simulated datacenter, under the dedicated account `svc-azauto` (not Local System), uses a tool that exists only on the worker, reads and writes the NAS share, and returns one JSON result a workflow can check.

## Setup

`vm-…-hw01` registered in the worker group `hwg-spike-files`, whose credential is `cred-svc-azauto` (user name without machine prefix, so that it resolves to the local account on any worker). The conversion tool at `C:\Tools\OrchestratorSpike\Convert-Extract.ps1`. The two valid J3 files of `test-data/j3/` copied to `\\nas01.corp.local\share\j3\in`.

## Steps

1. `PUT …/automationAccounts/{account}/jobs/{new GUID}?api-version=2024-10-23` with `runbook.name = Invoke-ConvertAndMove`, `runOn = hwg-spike-files` and the paths of SPEC §5.5.
2. Poll `GET …/jobs/{id}` until a terminal status; `GET …/jobs/{id}/output`.
3. Hash the files of `j3\out` and `j3\archive` on the NAS and compare with `test-data/j3/expected/`.

## Result

- The job went from `New` to `Completed` in under a minute.
- Output (abridged): `{"status":"Succeeded","worker":"hw01","runAs":"hw01\\svc-azauto","filesProcessed":2,"filesSkipped":0,"filesFailed":0,…}`.
- `j3\out\payroll_extract_202611.json` and `hr_movements_202611.json` have the same SHA-256 as the expected files; each has its `.sha256` sidecar; the sources are in `j3\archive` with a timestamp prefix; `j3\in` is empty.
- The output endpoint returns the verbose stream lines before the JSON line, as plain text: the workflow takes the last line that starts with `{`.

## Conclusion

The P3 pattern works without inbound connectivity to the datacenter: the worker polls Automation over HTTPS, and the job runs as a dedicated local account that only has rights on `j3\*`. The same through the J3 workflow (2026-11-18, `wf-j3-convert-onprem` started by its Recurrence trigger): the run took 91 s (job created, polled until `Completed`, output line parsed), ended `Succeeded`, and wrote a run report with `filesProcessed 2`, `filesFailed 0` and the runbook's JSON in `details` (`runAs hw01\svc-azauto`, `worker hw01`); the two outputs on the NAS match the expected files and the sources are archived (T08).

Still to show: the failure cases (T10–T12) and failover (T13).
