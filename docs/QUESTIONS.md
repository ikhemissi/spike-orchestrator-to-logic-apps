# Questions

The full requirements are in [SPEC.md](SPEC.md); each question below maps to its jobs and scenarios.

| # | Question | Experiments | Status |
|---|---|---|---|
| Q1 | Can scheduled and folder-monitoring System Center Orchestrator jobs, including jobs that use on-premises file shares and local tools, run on Azure Logic Apps Standard with Azure Automation hybrid workers, reliably, idempotently and observably? | — | open |
| Q2 | P0: do built-in FTP/SFTP connectors move files between partners from one stable egress IP (NAT Gateway) that partners can allow-list? (J1, J2, T01–T05, T14) | — | open |
| Q3 | P1: can Logic Apps Standard read and write an on-premises SMB share directly over VNet integration, with no on-premises agent? (J4, J5, T06, T07, T18) | — | open |
| Q4 | P3: can Logic Apps start a PowerShell runbook on a Hybrid Runbook Worker for local tools, run it as a dedicated account, and detect failures and an offline worker? (J3, T08–T13) | — | open |
| Q5 | Are re-runs safe (no duplicate or resent file) and are failures alerted and traceable end to end by correlation ID? (T03, T09, T15–T17, §6) | — | open |
| Q6 | Can the whole environment be deployed from an empty subscription with Terraform and azd, and torn down with one command? (§2, §11) | — | open |

Status: `open`, `answered`, `partly answered`, `unanswered` (with what blocked it).
