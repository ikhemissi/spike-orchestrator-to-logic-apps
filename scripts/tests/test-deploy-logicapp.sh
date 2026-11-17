#!/usr/bin/env bash
# Tests scripts/deploy-logicapp.sh with a fake az on PATH: zip contents and command order.
set -euo pipefail

scripts_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
repository_root="$(cd -- "$scripts_dir/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root/scripts" "$test_root/src/logicapp/workflows/ping" "$test_root/src/logicapp/.vscode" \
  "$test_root/src/logicapp/workflow-designtime" "$test_root/src/logicapp/tests" \
  "$test_root/src/logicapp/__azurite_data"
cp "$repository_root/scripts/deploy-logicapp.sh" "$test_root/scripts/deploy-logicapp.sh"
cp "$repository_root/src/logicapp/.funcignore" "$test_root/src/logicapp/.funcignore"
printf '{"version":"2.0"}\n' > "$test_root/src/logicapp/host.json"
printf '{"definition":{}}\n' > "$test_root/src/logicapp/workflows/ping/workflow.json"
printf '{}\n' > "$test_root/src/logicapp/local.settings.json"
printf '{}\n' > "$test_root/src/logicapp/.vscode/settings.json"
printf '{}\n' > "$test_root/src/logicapp/workflow-designtime/designer.json"
printf '{}\n' > "$test_root/src/logicapp/tests/test-workflow.json"
printf 'data\n' > "$test_root/src/logicapp/__azurite_data/blob"
mkdir -p "$test_root/src/logicapp/workflows/latest-orders"
printf '{"definition":{}}\n' > "$test_root/src/logicapp/workflows/latest-orders/workflow.json"
printf 'test\n' > "$test_root/src/logicapp/Workflow.Tests.ps1"
mkdir -p "$test_root/bin"

cat > "$test_root/bin/az" <<'AZ'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$AZ_TEST_LOG"
if [[ "$1 $2 $3 $4" == "logicapp deployment source config-zip" ]]; then
  while (($#)); do
    if [[ "$1" == "--src" ]]; then
      cp "$2" "$AZ_TEST_ZIP_COPY"
      break
    fi
    shift
  done
elif [[ "$1 $2" == "account show" ]]; then
  printf '00000000-0000-0000-0000-000000000001\n'
fi
AZ
chmod +x "$test_root/bin/az"

export AZURE_RESOURCE_GROUP='rg-test'
export LOGIC_APP_NAME='logicapp-test'
export AZ_TEST_LOG="$test_root/commands.log"
export AZ_TEST_ZIP_COPY="$test_root/deployed.zip"
export PATH="$test_root/bin:$PATH"

bash "$test_root/scripts/deploy-logicapp.sh"

mapfile -t commands < "$AZ_TEST_LOG"
[[ "${#commands[@]}" -eq 4 ]]
[[ "${commands[0]}" == "logicapp deployment source config-zip --resource-group rg-test --name logicapp-test --src "* ]]
[[ "${commands[1]}" == "logicapp restart --resource-group rg-test --name logicapp-test" ]]
[[ "${commands[2]}" == "account show --query id --output tsv" ]]
[[ "${commands[3]}" == "rest --method get --url https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test/providers/Microsoft.Web/sites/logicapp-test/hostruntime/runtime/webhooks/workflow/api/management/workflows?api-version=2018-11-01" ]]

python3 - "$AZ_TEST_ZIP_COPY" <<'PY'
import sys
import zipfile

expected = {"host.json", "workflows/ping/workflow.json", "workflows/latest-orders/workflow.json"}
with zipfile.ZipFile(sys.argv[1]) as archive:
    actual = set(archive.namelist())
if actual != expected:
    raise SystemExit(f"unexpected zip contents: {sorted(actual)}")
PY

echo "deploy-logicapp.sh tests passed"
