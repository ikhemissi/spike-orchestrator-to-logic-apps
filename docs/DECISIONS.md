# Decisions

Every choice, simplification against production and fallback, with its date. VERIFY items link to the experiment that settled them.

| # | Date | Decision | Why | Production |
|---|---|---|---|---|
| D1 | 2026-11-16 | One Terraform root in `infra/` with one file per part and azd hook steps in `infra/hooks/<event>/`, instead of the per-concern module tree of the spec's §4 | Shared building blocks (state backend, monitoring, Key Vault, teardown) stay mergeable | Same |
| D2 | 2026-11-16 | azd hook steps are bash only; every operational script in `scripts/` has bash and PowerShell 7 versions | azd runs one hook runner; operators may use either shell for scripts | Same |
| D3 | 2026-11-17 | J3's local tool converts CSV to JSON (`Convert-Extract.ps1`, installed only on the workers) instead of encrypting with GnuPG | Same P3 demonstration (a tool that exists only in the datacenter, run as a dedicated account), deterministic output checked against expected files, no key distribution to a job account's profile | The real local tool, installed and versioned by the datacenter's software distribution |

## VERIFY items

| Item (spec §) | Outcome | Experiment |
|---|---|---|
| — | — | — |
