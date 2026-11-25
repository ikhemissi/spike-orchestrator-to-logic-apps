# Hand-off — Orchestrator to Logic Apps Standard spike

State on **2026-11-25**. Read this first; [FINDINGS.md](FINDINGS.md) has the answers and their evidence, [SPEC.md](SPEC.md) the full requirements.

## In one paragraph

The spike rebuilds five System Center Orchestrator jobs as Logic Apps Standard workflows to evaluate three patterns separately: **(1) partner file transfer** with the FTP and SFTP connectors from one NAT egress IP, **(2) direct access to a datacenter file share** with the File System connector, and **(3) a local tool on an Azure Automation hybrid worker**, started and polled by a workflow. Partners and the datacenter are simulated with Azure VMs. All three patterns pass their happy paths and their failure scenarios live; every run carries a correlation ID and writes a run report, and failures raise alerts. Two items remain: the did-not-run alert test (T16) and a rebuild from an empty subscription.

## Where things are

| Path | What |
|---|---|
| `infra/` | One Terraform root, run by `azd provision`: network (hub, datacenter and partner VNets, NAT), VMs, Logic App, Automation, Key Vault, storage, monitoring, alerts (`alerts/*.kql`) and the workbook |
| `infra/scripts/vm/` | Setup scripts the VMs download at provisioning (partner FTP/SFTP, NAS share, worker tool) |
| `src/logicapp/` | The workflows (`wf-j1` … `wf-j5`, `wf-diag-egress-ip`, `wf-child-run-report`), `connections.json`, `parameters.json` |
| `src/runbooks/` | `Invoke-ConvertAndMove.ps1`, the J3 runbook |
| `scripts/` | Deploy, seed, reset, inject faults, pause and resume, each as `.sh` and `.ps1`; `check.sh` runs every offline check |
| `tests/` | `run-all.ps1`, the scenario scripts `T01`–`T18`, the alert scenarios under `scenarios/alerts/`, unit tests |
| `docs/` | Specification, decisions (D1–D19), questions, findings, architecture, demo runbook, retest plan, CI/CD, test report |

## How to run it

```sh
azd env new <name> --location francecentral
azd env set DEPLOYER_IP "<your-public-ip>"
azd env set RESOURCE_TAGS "key=value"        # tags your subscription policies require, if any
azd env set ENABLE_SECOND_WORKER true        # optional: the failover scenario T13 needs it
azd provision                                # Terraform through azd, about 20 minutes the first time
bash scripts/deploy-logicapp.sh              # deploys the workflows; fails if a workflow is unhealthy
pwsh -File tests/run-all.ps1                 # the scenarios; -Only T02,T08 for some, -IncludeAlerts for the alert waits
bash scripts/pause-environment.sh            # outside working hours: VMs deallocated, job workflows disabled
bash scripts/resume-environment.sh
azd down --purge                             # remove everything
```

The VMs also shut down every day at 20:00 (Romance Standard Time, `AUTO_SHUTDOWN_TIME`); resume the environment before testing after that time. Before a commit, run `scripts/check.sh` (about 12 minutes).

## What is tested

| Pattern | Scenario | Result |
|---|---|---|
| — | T01 egress IP is the NAT IP | ✅ |
| 1 | T02 J1 delivers to partner B (temporary name, then rename), archives the sources | ✅ |
| 1 | T03 J1 re-run skips the three files already delivered | ✅ |
| 1 | T04 partner allow-list without the NAT IP: J1 fails, `alert-workflow-failed` fires, a re-run after restore delivers | ✅ with the alert |
| 1 | T05 wrong partner password: J1 fails with the FTP login error | ✅ |
| 1 | T14 J2 delivers to the SharePoint stand-in (Blob) | ✅ |
| 2 | T06 J4 sorts files into NAS folders, unknown files into quarantine | ✅ |
| 2 | T07 NAS unreachable: J4 fails before any file moves | ✅ |
| 2 | T18 J5 picks up a file dropped in the watched folder | 🟡 checked by hand |
| 3 | T08 J3 output identical to the expected JSON, run as the dedicated account | ✅ |
| 3 | T09 J3 re-run skips converted files | ✅ |
| 3 | T10 one bad file: the others are converted, the run fails with `RUNBOOK_REPORTED_FAILURE` | ✅ |
| 3 | T11 job runs as Local System: access denied on the share, the run fails | ✅ |
| 3 | T12 no worker online: J3 fails with `HYBRID_JOB_TIMEOUT` after 5 minutes | ✅ |
| 3 | T13 first worker stopped: the job runs on the second worker | ✅ |
| all | T15 every run writes a run report with its correlation ID | ✅ |
| all | T16 J3 does not run for an hour: the deadline alert fires | ⬜ not yet run |
| all | T17 the workbook query by correlation ID shows the Logic Apps steps and the Automation job | ✅ |

Outside the scenarios, `alert-workflow-failed`, `alert-runbook-failed`, `alert-hybrid-job-stuck` and `alert-critical-job-did-not-succeed-by-deadline` fired after real failures on 2026-11-18 and 2026-11-19, 15 to 20 minutes after the failure, and resolved on their own.

## What is not tested

| Gap | Note |
|---|---|
| A second clean rebuild | The rebuild of 2026-11-20 passed after three fixes (D17–D19); a rebuild with the fixes in place from the start is still to run. |
| T16 did-not-run alert | Needs J3 disabled for the alert window (1 hour) after the deadline alert has resolved. |
| Partner server down, and `alert-partner-connection-errors` | The fault exists (`inject-fault partner-down`); no scenario uses it. The alert's query was corrected on 2026-11-19 and checked against two days of logs, but has not fired in a test. |
| Alert e-mail delivery | Alerts fire in Azure; arrival in the mailbox set by `ALERT_EMAIL` was not checked. |
| SharePoint itself | J2 writes to a Blob container that stands in for SharePoint. |
| J5 as an automated scenario; failure cases of J2 and J5; J4's conflict path (same name, different size) | Happy paths only, J5 by hand. |
| Scheduled runs | The tests start workflows by hand; the 15-minute schedule ran outside the tests but is not asserted. |
| A hybrid worker on an Arc-enabled server | Arc onboarding worked on an Azure VM prepared for evaluation; the Hybrid Worker extension needs non-Azure hardware ([experiment 03](experiments/03-arc-enabled-worker.md)). The diagrams show the target design, with Arc-enabled datacenter servers. |
| Volume and overlap | A handful of small files and one large file; no concurrent runs of the same job. |

## Things to know

- **Partner ports** are 2121 (FTP) and 2222 (SFTP): in the test subscription, network rules opening the well-known ports to Internet addresses were removed automatically ([D9](DECISIONS.md)).
- **NAS access** goes through a file-share mount of the Logic App that Terraform declares; the File System connection only names the mount path ([D10](DECISIONS.md)). J5 polls the folder instead of using the File System trigger ([D11](DECISIONS.md)).
- **Schedules** come from the app setting `JOB_RECURRENCE_MINUTES` (default 15). The test runner stretches it to a day while it runs and restores it; if a run is interrupted, set it back to 15 ([D12](DECISIONS.md)).
- **Secrets**: the app resolves a Key Vault reference when its settings change, so the wrong-password fault points the setting at another secret ([D15](DECISIONS.md)). Rotate a secret with a settings change, not a restart alone.
- **A blocked NAS** makes an SMB call wait up to 20 minutes; J4 checks the NAS once before the first file ([D16](DECISIONS.md)).
- **Workbook**: `infra/workbook.json` (a business view per job and pattern, failures in plain words, run steps from Application Insights, the correlation trace). Test changes to its queries in Log Analytics before `azd provision`; `{TimeRange}`, `{RunId}` and `{CorrelationId}` are workbook parameters.
- **Logs**: the Automation job logs carry Automation's own correlation ID; the workbook joins them to the workflow through the job ID J3 records.
- **Deployment**: `deploy-logicapp` fails when the runtime reports an unhealthy workflow; an invalid definition otherwise deploys and silently disables its trigger.
- **Terraform plan** once stopped progressing while reading the state of existing resources; it was interrupted and the next run went through. Use a timeout in automation.

## Current state of the environment (2026-11-25)

- The environment was removed with `azd down --purge` on 2026-11-25; nothing remains in the subscription except the shared Terraform state store.
- To recreate it: the steps in [How to run it](#how-to-run-it) (`azd provision`, then `scripts/deploy-logicapp.sh`), about 15 minutes; the rebuild of 2026-11-20 is in the [test report](TEST-REPORT.md).

## Next steps

1. Run T16 (`pwsh -File tests/run-all.ps1 -Only T16 -IncludeAlerts`, about 1 hour 15 minutes).
2. Run a second clean rebuild with the fixes in place (`azd down --purge`, `azd provision`, `deploy-logicapp`, `run-all.ps1`) to confirm it needs no manual step.
3. Optional: a partner-down scenario with the partner-connection alert, J5 as an automated scenario, J4's conflict path.
4. Rehearse the [demo](DEMO-RUNBOOK.md).
