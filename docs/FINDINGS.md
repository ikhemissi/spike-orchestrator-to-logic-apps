# Findings — Orchestrator to Logic Apps Standard migration spike

**Date:** 2026-11-18 · **Versions tested:** Azure CLI 2.88.0, azd 1.37.3, Terraform 1.15.8, Azure Automation API 2024-10-23, PowerShell 7.4, Hybrid Worker extension 1.3, Windows Server 2022

## Summary

As of 2026-11-18, live tests have demonstrated partner transfers through a stable NAT egress IP, NAS access from Logic Apps, and local file conversion on an Azure Automation Hybrid Runbook Worker. Re-runs skip duplicate files, run reports carry correlation IDs, and a bad input or offline worker produces a reported failure. The built-in File System trigger did not load with the mount-based connection, so J5 polls the folder on a recurrence instead ([D11](DECISIONS.md)). The wrong-password, NAS-unreachable, Local System, worker failover, alert, and complete rebuild scenarios remain pending.

## Answers

### Q1 — Can scheduled and folder-monitoring System Center Orchestrator jobs, including jobs that use on-premises file shares and local tools, run on Azure Logic Apps Standard with Azure Automation hybrid workers, reliably, idempotently and observably? (Partly answered)

The tested patterns cover cloud partner transfers, direct NAS access, recurrence-based folder polling, and local-tool execution through a Hybrid Worker. J3 ran under the dedicated worker account and produced files matching the expected outputs; duplicate inputs were skipped, and run reports were correlated ([02](experiments/02-p3-runbook-on-hybrid-worker.md), [D3](DECISIONS.md), [D11](DECISIONS.md)). A per-file failure and an offline worker were also detected with explicit outcomes ([D13](DECISIONS.md), [D14](DECISIONS.md)). The pending tests and full rebuild mean this does not yet answer whether the whole migration is ready to repeat end to end ([01](experiments/01-verify-items.md)).

### Q2 — P0: do built-in FTP/SFTP connectors move files between partners from one stable egress IP (NAT Gateway) that partners can allow-list? (Partly answered)

T01 confirmed that the observed egress IP equals the NAT IP. T02 and T03 confirmed J1 delivery using a `.partial` upload followed by rename and duplicate skipping on re-run; T04 confirmed that removing the partner allow-list entry makes J1 fail and restoring it allows a successful re-run. T14 confirmed J2 writes to Blob; T05 (wrong partner password) remains pending. Connector operations and the non-standard partner ports are documented in [01](experiments/01-verify-items.md) and [D9](DECISIONS.md).

### Q3 — P1: can Logic Apps Standard read and write an on-premises SMB share directly over VNet integration, with no on-premises agent? (Partly answered)

T06 confirmed J4 sorts files onto the NAS through VNet integration without an on-premises agent, and T18 confirmed J5 folder polling. J5 uses a Recurrence trigger because, on 2026-11-18, the built-in File System trigger did not load with the mount-based connection ([01](experiments/01-verify-items.md), [D10](DECISIONS.md), [D11](DECISIONS.md)). T07 (NAS unreachable) remains pending.

### Q4 — P3: can Logic Apps start a PowerShell runbook on a Hybrid Runbook Worker for local tools, run it as a dedicated account, and detect failures and an offline worker? (Partly answered)

T08 and T09 confirmed that J3 runs the local conversion tool as the dedicated worker account, produces the expected files, and skips files on re-run ([02](experiments/02-p3-runbook-on-hybrid-worker.md), [D3](DECISIONS.md)). T10 confirmed that a bad file yields `PartialFailure` and `RUNBOOK_REPORTED_FAILURE` while the other files are processed; T12 confirmed an offline worker is detected by the five-minute poll timeout as `HYBRID_JOB_TIMEOUT` ([D13](DECISIONS.md), [D14](DECISIONS.md)). T11 (Local System) and T13 (worker failover) remain pending.

### Q5 — Are re-runs safe (no duplicate or resent file) and are failures alerted and traceable end to end by correlation ID? (Partly answered)

T03 and T09 confirmed that reruns skip previously handled files, and T15 confirmed that run reports can be found by correlation ID. T10 confirmed an explicit runbook failure outcome while processing continued for other files ([02](experiments/02-p3-runbook-on-hybrid-worker.md), [D14](DECISIONS.md)). The alert scenarios T16 and T17 remain pending, so alert delivery and the end-to-end telemetry trace are not yet confirmed.

### Q6 — Can the whole environment be deployed from an empty subscription with Terraform and azd, and torn down with one command? (Partly answered)

Experiment 01 established the scripted Terraform-through-azd and zip-deployment path, and settled the specification's VERIFY items, including the VM size and connector operations ([01](experiments/01-verify-items.md), [D1](DECISIONS.md)). A full rebuild from an empty subscription and teardown have not yet been completed and remain pending.

## What we would do differently

For production, use VPN or ExpressRoute instead of VNet peering, Arc-enabled workers instead of Azure VM workers, and domain accounts instead of local accounts. Configure private endpoints, enable Key Vault purge protection, decide zone redundancy when creating the plan, and set real schedules for each job ([DECISIONS.md](DECISIONS.md), [ARCHITECTURE.md](ARCHITECTURE.md)).
