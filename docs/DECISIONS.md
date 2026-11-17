# Decisions

Every choice, simplification against production and fallback, with its date. VERIFY items link to the experiment that settled them.

| # | Date | Decision | Why | Production |
|---|---|---|---|---|
| D1 | 2026-11-16 | One Terraform root in `infra/` with one file per part and azd hook steps in `infra/hooks/<event>/`, instead of the per-concern module tree of the spec's §4 | Shared building blocks (state backend, monitoring, Key Vault, teardown) stay mergeable | Same |
| D2 | 2026-11-16 | azd hook steps are bash only; every operational script in `scripts/` has bash and PowerShell 7 versions | azd runs one hook runner; operators may use either shell for scripts | Same |
| D3 | 2026-11-17 | J3's local tool converts CSV to JSON (`Convert-Extract.ps1`, installed only on the workers) instead of encrypting with GnuPG | Same P3 demonstration (a tool that exists only in the datacenter, run as a dedicated account), deterministic output checked against expected files, no key distribution to a job account's profile | The real local tool, installed and versioned by the datacenter's software distribution |
| D4 | 2026-11-17 | Every VM uses the size setting `VM_SIZE`, default `Standard_D2als_v7` (2 vCPU, 4 GiB) | B-series sizes were not available to the test subscription in the region ([01](experiments/01-verify-items.md) V1) | Size per role, from the real servers |
| D5 | 2026-11-17 | No policy assignment forcing jobs onto hybrid workers | No built-in definition found ([01](experiments/01-verify-items.md) V2); a custom definition is out of scope | A custom policy, or the Automation account used only with hybrid worker groups |
| D6 | 2026-11-17 | The Logic App's runtime storage account keeps shared keys (the runtime's content share uses the account key); workflows reach Azure only with the managed identity, and the data account has shared keys disabled | Workflow Standard plans mount their content share with the account key | Same, plus private endpoints for the runtime storage (`enable_private_storage`) |
| D7 | 2026-11-17 | The Logic App's public network access stays enabled, so that `azd`/zip deployment works from a laptop | Simplest deployment path for the spike | Private inbound access, deployment from a runner inside the network |
| D8 | 2026-11-17 | The VMs' setup scripts are downloaded from this repository at a git ref (`VM_SCRIPT_SOURCE_REF`, default `main`) | Simplest delivery for a public spike repository; a script change takes effect once pushed | Scripts from the organisation's software distribution or a private artifact store |
| D9 | 2026-11-17 | The simulated partner listens on non-standard ports (FTP control `PARTNER_FTP_PORT`, default 2121; SFTP `PARTNER_SFTP_PORT`, default 2222) | In the test environment, network rules that open well-known management ports to Internet addresses were removed automatically within the hour, even when restricted to two source addresses | Real partners use their own ports; the connections take the port as a setting |

## VERIFY items

| Item (spec §) | Outcome | Experiment |
|---|---|---|
| All items | See [experiment 01](experiments/01-verify-items.md) | [01](experiments/01-verify-items.md) |
