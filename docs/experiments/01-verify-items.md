# 01 — VERIFY items of the specification

**Date:** 2026-11-17 (in progress) · **Answers:** Q6 (and the build of Q2–Q4) · **Versions:** Azure CLI 2.88.0, azd 1.37.3, Terraform 1.15.8

## Goal

Settle every item the [specification](../SPEC.md) marks **VERIFY** before building on it: each one is confirmed live, confirmed in current documentation (to confirm live at first use), or replaced by the documented fallback. Outcomes go to the VERIFY table of [DECISIONS.md](../DECISIONS.md).

## Setup

One subscription, region `francecentral`, the deployer's own Entra identity through the Azure CLI. No resources other than short-lived probes.

## Results

| # | Item (spec §) | How checked | Outcome |
|---|---|---|---|
| V1 | VM sizes B1s/B2s for the simulated VMs (§3.2) | `az deployment group validate` of a Windows Server 2022 VM per size in a temporary resource group | `Standard_B2s`, `Standard_B2s_v2`, `Standard_B2als_v2`: `SkuNotAvailable` (capacity restrictions) for this subscription. `Standard_D2als_v7` and `Standard_D2as_v7` (2 vCPU, 4 GiB): validation succeeded. The subscription reports 100 vCPUs of B-series quota, so quota alone did not predict it. → VM size is a setting (`VM_SIZE`), default `Standard_D2als_v7` for every VM (D4). |
| V2 | Built-in policy enforcing jobs on Hybrid Runbook Workers (§3.4) | Search of the built-in definitions (`az policy definition list`) and of the Azure Policy built-ins repository | No such built-in definition found. → Skipped and documented, as the spec allows (D5). |
| V3 | azd `azure.logicappsstandard` extension (§2.2) | `azd ext list`; the azd extension registries | Source exists in the azd repository; not listed in the extension registries available to this azd on 2026-11-17. → The scripted path (Terraform through azd, then `scripts/deploy-logicapp.*`) is the primary path; the extension path is rechecked at the end. |
| V4 | Built-in FTP operations (§5.2) | Connector reference | No rename, move or copy operation; archive = create the file in `/outbound/archive`, then delete the source. To confirm live. |
| V5 | Built-in SFTP rename (§5.2) | Connector reference | `renameFile` exists (same folder): upload as `.partial`, then rename. Not-found behaviour of the metadata action: to test live. |
| V6 | Azure Automation built-in connector (§5.1) | Connector reference | Exists for Standard: create job (with a hybrid worker group), get job status, get job output; managed identity authentication. ARM fallback: job API version `2024-10-23`. To confirm live. |
| V7 | Extension bundle and enhanced telemetry (§3.3, §3.6) | Host settings documentation | `Microsoft.Azure.Functions.ExtensionBundle.Workflows` `[1.*, 2.0.0)`; `extensions.workflow.Settings."Runtime.ApplicationInsightTelemetryVersion": "v2"` (in `src/logicapp/host.json`). |
| V8 | `az logicapp deployment source config-zip` (§2.3) | CLI reference | `-g <rg> -n <app> --src <zip>` (zip deployment). |
| V9 | PowerShell 7.4 runtime environment (§3.4) | REST and Terraform provider references | `Microsoft.Automation/automationAccounts/runtimeEnvironments` (`2024-10-23`); `azurerm_automation_runtime_environment` and `runtime_environment_name` on the runbook. Version 7.4 acceptance: to confirm live. |
| V10 | Hybrid worker extension and group credential (§3.4) | Automation documentation, provider reference | VM extension `Microsoft.Azure.Automation.HybridWorker` / `HybridWorkerForWindows` 1.1, setting `AutomationAccountURL`; `azurerm_automation_hybrid_runbook_worker_group.credential_name`; worker registration needs a worker UUID and the VM resource ID. |
| V11 | Run a Recurrence trigger through the management API (§5.0) | — | Open: test live with `wf-diag-egress-ip` deployed. |
| V12 | `connections.json` parameter names of the built-in connectors (§5.1) | — | Open: the references list display names; take the keys from the designer's code view of a deployed app. |

## Conclusion

In progress. No item so far blocks the design: V1 changes the VM size, V2 drops the policy assignment, V3 makes the scripted deployment the primary path.
