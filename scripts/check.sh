#!/usr/bin/env bash
# The offline checks of this repository, the same locally, in CI and for the cloud agent: shell and PowerShell lint,
# Pester tests, JSON validity (workflow definitions, settings), and Terraform format, validation and tests.
# No Azure access needed.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$1"; }

step "shellcheck"
mapfile -t shell_scripts < <(git ls-files '*.sh')
shellcheck "${shell_scripts[@]}"

step "PSScriptAnalyzer"
# shellcheck disable=SC2016 # the PowerShell code is expanded by pwsh, not by bash
pwsh -NoProfile -Command '
  $files = git ls-files "*.ps1" "*.psm1"
  if (-not $files) { Write-Host "no PowerShell files yet"; return }
  $issues = $files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Severity Warning,Error }
  $issues | Format-Table -AutoSize | Out-String | Write-Host
  if ($issues) { exit 1 }'

step "Pester"
# shellcheck disable=SC2016 # the PowerShell code is expanded by pwsh, not by bash
pwsh -NoProfile -Command '
  $tests = git ls-files "*.Tests.ps1"
  if (-not $tests) { Write-Host "no Pester tests yet"; return }
  $result = Invoke-Pester -Path $tests -Output Detailed -PassThru
  if ($result.FailedCount -gt 0) { exit 1 }'

step "JSON files"
while IFS= read -r json_file; do
  python3 -m json.tool "$json_file" >/dev/null || { echo "invalid JSON: $json_file"; exit 1; }
done < <(git ls-files '*.json')

step "Terraform"
terraform fmt -check -recursive infra
terraform -chdir=infra init -backend=false -input=false >/dev/null
terraform -chdir=infra validate
for module_dir in infra/modules/*/; do
  if [[ -d "$module_dir/tests" ]]; then
    (cd "$module_dir" && terraform init -backend=false -input=false >/dev/null && terraform test)
  fi
done

printf '\nAll checks passed.\n'
