#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
export PATH="$root/scripts/tests/fakes:$PATH"
export AZ_TEST_STATE="$temporary_directory/az-state.json"
export AZ_TEST_LOG="$temporary_directory/az.log"
export AZURE_RESOURCE_GROUP=test-rg
export AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000
export KEY_VAULT_NAME=test-vault
export NAT_PUBLIC_IP=198.51.100.10
export PARTNER_VM_NAME=partner-test
export PARTNER_NSG_NAME=partner-nsg
export SERVERS_NSG_NAME=servers-nsg
export WORKER_VM_NAMES=worker-01
export AUTOMATION_ACCOUNT_NAME=automation-test
export HYBRID_WORKER_GROUP=workers
export LOGIC_APP_NAME=logicapp-test
export NAS_VM_NAME=nas-test

bash "$root/scripts/inject-fault.sh" partner-ip-block >/dev/null
python3 - "$AZ_TEST_STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    rule = json.load(state_file)["partner_rule"]
assert rule["name"] == "Allow-FTP-SFTP-From-NAT-And-Deployer"
assert rule["sourceAddressPrefixes"] == ["203.0.113.8"]
assert "198.51.100.10" not in rule["sourceAddressPrefixes"]
assert rule["description"].startswith("fault-restore:")
PY

bash "$root/scripts/inject-fault.sh" restore-all >/dev/null
python3 - "$AZ_TEST_STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    state = json.load(state_file)
assert state["partner_rule"]["sourceAddressPrefixes"] == ["198.51.100.10", "203.0.113.8"]
assert state["partner_rule"]["description"] == "partner allow list"
PY

bash "$root/scripts/inject-fault.sh" bad-ftp-password >/dev/null
python3 - "$AZ_TEST_STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    state = json.load(state_file)
assert state["fault_secret_value"] == "invalid-test-password"
assert state["secret_value"] == "test-secret-value"
assert state["app_settings"]["FTP_PARTNER_A_PASSWORD"] == "@Microsoft.KeyVault(VaultName=test-vault;SecretName=ftp-partner-a-password-fault)"
PY
bash "$root/scripts/inject-fault.sh" restore-all >/dev/null
python3 - "$AZ_TEST_STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    state = json.load(state_file)
assert state["secret_value"] == "test-secret-value"
assert state["app_settings"]["FTP_PARTNER_A_PASSWORD"] == "@Microsoft.KeyVault(VaultName=test-vault;SecretName=ftp-partner-a-password)"
PY

bash "$root/scripts/inject-fault.sh" partner-down >/dev/null
grep -q 'systemctl stop vsftpd ssh' "$AZ_TEST_LOG"
bash "$root/scripts/inject-fault.sh" restore-all >/dev/null
grep -q 'systemctl start' "$AZ_TEST_LOG"

bash "$root/scripts/inject-fault.sh" nas-block >/dev/null
python3 - "$AZ_TEST_STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    rules = json.load(state_file)["servers_rules"]
assert len(rules) == 1
assert rules[0]["name"] == "fault-nas-block"
assert rules[0]["source"] == "10.10.0.0/27"
assert rules[0]["destination"] == "10.20.0.4/32"
assert rules[0]["ports"] == "445"
PY
# The open SMB connection survives the new rule, so the NAS restarts its SMB server.
grep -q 'Restart-Service -Name LanmanServer' "$AZ_TEST_LOG"
bash "$root/scripts/inject-fault.sh" restore-all >/dev/null

bash "$root/scripts/inject-fault.sh" worker-stop >/dev/null
python3 - "$AZ_TEST_STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    state = json.load(state_file)
assert state["workers_running"]["worker-01"] is False
assert state["worker_tags"]["worker-01"] is True
PY
bash "$root/scripts/inject-fault.sh" restore-all >/dev/null
python3 - "$AZ_TEST_STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    state = json.load(state_file)
assert state["workers_running"]["worker-01"] is True
assert "worker-01" not in state["worker_tags"]
PY

bash "$root/scripts/inject-fault.sh" worker-system-account >/dev/null
python3 - "$AZ_TEST_STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    state = json.load(state_file)
assert state["worker_credential"] is None
assert state["worker_credential"] is None
PY
bash "$root/scripts/inject-fault.sh" restore-all >/dev/null
python3 - "$AZ_TEST_STATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    state = json.load(state_file)
assert state["worker_credential"] == "cred-svc-azauto"
PY

bash "$root/scripts/inject-fault.sh" restore-all >/dev/null
echo "inject-fault bash tests passed."
