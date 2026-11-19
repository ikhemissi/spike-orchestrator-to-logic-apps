# Retest plan

What to run again when a product, an SDK or a policy changes, so that the findings stay true.

| Experiment or decision | Retest when | How | Last run |
|---|---|---|---|
| [Experiment 00](experiments/00-environment.md) | Before a new live experiment or when the environment changes | Record the region, identity types, and product versions used by the run. | Not recorded |
| [Experiment 01](experiments/01-verify-items.md) | When Azure CLI, azd, Terraform, Logic Apps connector operations, or relevant Azure service behavior changes | Recheck the V1–V12 items against the documented evidence; repeat live checks for items marked confirmed live. | 2026-11-17; V5 and V11 also checked 2026-11-18 |
| [Experiment 02](experiments/02-p3-runbook-on-hybrid-worker.md) | When Azure Automation, the Hybrid Worker extension, its PowerShell runtime, or the runbook changes | Run J3 with valid inputs; compare output hashes with expected files and confirm worker identity, archive, and run report. | 2026-11-18 |
| [D5](DECISIONS.md) | When Azure Policy built-in definitions change or production requires job-placement enforcement | Search current built-in definitions and the Azure Policy built-ins repository; if enforcement is needed, assess a custom policy. | 2026-11-17 |
| [D9](DECISIONS.md) | When partner endpoint ports or network policy behavior changes | Confirm configured FTP/SFTP ports are reachable and rerun J1, including the NAT-IP allow-list block and restore scenario. | 2026-11-17 |
| [D10](DECISIONS.md) | When the Logic Apps File System connector or mount configuration behavior changes | Deploy the mount-based connection and verify J4 can read from and write to the NAS. | 2026-11-18 |
| [D11](DECISIONS.md) | When the File System connector trigger behavior changes | Test the built-in trigger with the mount-based connection; verify it loads and responds to a file, then compare with J5 recurrence polling. | 2026-11-18 |
| [Experiment 01 V3](experiments/01-verify-items.md) | When the azd extension registry or `azure.logicappsstandard` extension availability changes, and at the end of the spike | Check the extension registry and deployment path; compare with the scripted Terraform-through-azd and zip-deployment path. | 2026-11-17; end-of-spike recheck pending |
