# AGENTS.md — Orchestrator to Logic Apps Standard migration spike

This repository is a **spike**: it answers questions by experiment, within a time box (Ready by 2026-11-23). Nothing here is production code. Read [README.md](README.md) for the questions and the status.

## How the spike works

- **Questions first:** [docs/QUESTIONS.md](docs/QUESTIONS.md) lists what we want to know. Every experiment answers at least one question; a question can need several experiments.
- **One experiment, one file:** `docs/experiments/NN-<slug>.md` from [the template](docs/experiments/TEMPLATE.md): goal, setup, steps, result, evidence (commands, outputs, screenshots, queries), conclusion. Number them in the order they run; never renumber.
- **Evidence over opinion:** record what was observed, with the date and the versions involved. Products change: a result without a date and a version cannot be retested.
- **Findings:** [docs/FINDINGS.md](docs/FINDINGS.md) answers each question in one paragraph, with links to the experiments. Update it after every experiment, and the "Key findings" of the README (one line per question) with it. Keep the README's setup diagram in step with the infrastructure.
- **Retest plan:** [docs/RETEST-PLAN.md](docs/RETEST-PLAN.md) lists what to run again when a product or a version changes.
- **Demo:** [docs/DEMO-RUNBOOK.md](docs/DEMO-RUNBOOK.md) is the step-by-step script for showing the results, written for someone else to run.
- **Time box:** when it runs out, stop and write the findings, including "unanswered" with what blocked it.
- **Ask before deciding** when a choice changes what the spike can conclude; propose a default.

## Rules

- **Never commit secrets**, keys, tokens, tenant or subscription IDs, or real user data. Use your own Entra identity (Azure CLI) and managed identities; local settings go to `.env` (git-ignored).
- **Generalize what you write:** the findings may be shared; customer, employer-internal and personal details stay out.
- Code is throwaway but must stay readable by another developer: small scripts in `src/`, one per experiment when useful, named after it (`src/03_call_with_obo.py`), each with a one-line purpose at the top, explicit names, no clever tricks, settings from the environment.
- **Commits:** conventional commits (`docs(experiment): 03 …`, `feat(spike): …`), ending with the trailer `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.
- **At the end:** harvest the reusable learnings into the knowledge base (pitfalls, findings, decisions), generalized.

## Infrastructure

- **One Terraform root** (`infra/`, one state), one file per part of the architecture. The files from shared building blocks (`key-vault.tf`, `monitoring.tf`, `main.tf`, `providers.tf`, …), the modules in `infra/modules/` and the hook steps in `infra/hooks/<event>/` stay as they are, so that their improvements can be merged in later. Put the spike's own resources in a new file of `infra/` (calling a module of `infra/modules/` where one fits), its settings as variables mapped in `infra/main.tfvars.json`, its outputs as azd values, and its steps in `infra/hooks/<event>/NN-<name>.sh`.
- **Before every `azd provision`:** `azd provision --preview` (one plan for the whole root) and read it: only expected adds and changes, no unexpected destroy. Module tests: `terraform init -backend=false && terraform test` in `infra/modules/<module>`.

## The specification

[docs/SPEC.md](docs/SPEC.md) is the requirement for everything built here; its first block says how it maps onto this repository's layout. Record every choice and deviation in [docs/DECISIONS.md](docs/DECISIONS.md).

## Cloud agent (GitHub Copilot)

Tasks are tagged **[cloud agent]** (built and verified offline, on the PR branch) or **[Azure]** (needs the deployed environment; done locally by the owner).

- **No Azure access:** never call Azure, never sign in. Stub Azure calls in tests; check Terraform with `terraform fmt -check`, `terraform init -backend=false && terraform validate`, and `terraform test` with mock providers.
- **Work autonomously:** never wait for confirmation. One conventional commit per task, push after every task. When blocked, write why in the PR description and stop.
- **Stay in the issue's files:** other agents work in parallel on other files. Do not edit shared files (`README.md`, `docs/DECISIONS.md`, `docs/QUESTIONS.md`, `docs/FINDINGS.md`) unless the issue says so; put proposed changes to them in the PR description.
- **Facts you cannot check offline** (connector operation names, API versions, resource arguments): use the values in the spec or the issue, mark them `# VERIFY` in the code and list them in the PR description.
- **Before each push:** `scripts/check.sh` (the same checks as CI).
- **Both shells:** every operational script in `scripts/` (deploy, seed, reset, inject-fault, grant; not `check.sh`) exists as `.sh` (bash, shellcheck clean) and `.ps1` (PowerShell 7, PSScriptAnalyzer clean) with the same parameters and behaviour.

## Code humans can maintain

Everything here must be maintainable by human developers, whoever (or whatever) wrote it. A developer new to the project understands a module in minutes and changes it with confidence.

- **Simple and explicit over clever:** no metaprogramming, hidden magic or generic frameworks; an abstraction only when a second real use exists.
- **One role per unit:** a module states its role in one or two lines at the top; a function does one thing and fits on a screen (about 40 lines), otherwise split it into named steps.
- **Names carry meaning:** domain words, full words, booleans that read as questions; no single letters except short loop indices.
- **Flat control flow:** early returns, named intermediate values, no dense one-liners or formatter opt-outs.
- **Comments explain why** (the decision, the constraint, a link to the design or ADR), never what the code already says.
- **Consistency beats preference:** follow the patterns already in the repository before introducing a new one.
- **Few dependencies:** ask before adding one; prefer the standard library and what is already used.
- **Tests read as documentation:** named after the behaviour or spec scenario they check; arrange, act, assert.
- **Read your diff as a reviewer before calling a change done;** if a piece cannot be explained simply, rewrite it.

## Known pitfalls

If `.fast-start/pitfalls.md` exists (local only, git-ignored: never commit, copy or quote it), read it before changing
infrastructure or services: it lists pitfalls known for this kind of project.

- None recorded yet.
Add a pitfall here every time something bites you, in one line: the symptom, then what to do.
