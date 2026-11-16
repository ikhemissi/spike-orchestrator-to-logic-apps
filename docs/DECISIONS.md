# Decisions

Every choice, simplification against production and fallback, with its date. VERIFY items link to the experiment that settled them.

| # | Date | Decision | Why | Production |
|---|---|---|---|---|
| D1 | 2026-11-16 | One Terraform root in `infra/` with one file per part and azd hook steps in `infra/hooks/<event>/`, instead of the per-concern module tree of the spec's §4 | Shared building blocks (state backend, monitoring, Key Vault, teardown) stay mergeable | Same |
| D2 | 2026-11-16 | azd hook steps are bash only; every operational script in `scripts/` has bash and PowerShell 7 versions | azd runs one hook runner; operators may use either shell for scripts | Same |

## VERIFY items

| Item (spec §) | Outcome | Experiment |
|---|---|---|
| — | — | — |
