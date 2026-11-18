#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
export PATH="$root/scripts/tests/fakes:$PATH"
export AZ_TEST_STATE="$temporary_directory/az-state.json"
export AZ_TEST_LOG="$temporary_directory/az.log"
export CURL_TEST_LOG="$temporary_directory/curl.log"
export AZURE_RESOURCE_GROUP=test-rg
export AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000
export KEY_VAULT_NAME=test-vault
export PARTNER_VM_FQDN=partner-a.example.test
export PARTNER_VM_NAME=partner-test
export PARTNER_NSG_NAME=partner-nsg
export NAT_PUBLIC_IP=198.51.100.10
export SERVERS_NSG_NAME=servers-nsg
export WORKER_VM_NAMES=worker-01
export AUTOMATION_ACCOUNT_NAME=automation-test
export HYBRID_WORKER_GROUP=workers
export LOGIC_APP_NAME=logicapp-test
export NAS_VM_NAME=nas-test
export NAS_SHARE_UNC='\\nas01.corp.local\share'
export DATA_STORAGE_ACCOUNT_NAME=teststorage
export PARTNER_FTP_PORT=2021
export PARTNER_SFTP_PORT=2222
export CURL_SFTP_TEST_LISTING=$'partner-file.csv\nincomplete.csv.partial'

bash "$root/scripts/inject-fault.sh" partner-down >/dev/null
bash "$root/scripts/inject-fault.sh" bad-ftp-password >/dev/null
output=$(bash "$root/scripts/reset-environment.sh")
[[ "$output" == "Environment reset; all injected faults restored." ]]
grep -q -- '-DELE /outbound/j1/sample.txt' "$CURL_TEST_LOG"
grep -q 'ftp://partner-a.example.test:2021/' "$CURL_TEST_LOG"
grep -q -- '-DELE /outbound/archive/sample.txt' "$CURL_TEST_LOG"
grep -q 'rm /inbound/partner-file.csv' "$CURL_TEST_LOG"
grep -q 'rm /inbound/incomplete.csv.partial' "$CURL_TEST_LOG"
grep -q 'sharepoint-sim' "$AZ_TEST_LOG"
grep -q 'run-reports' "$AZ_TEST_LOG"
grep -q 'RunPowerShellScript' "$AZ_TEST_LOG"
grep -q -- '--test-password-restored' "$CURL_TEST_LOG"
if grep -q 'test-secret-value' "$AZ_TEST_LOG"; then exit 1; fi
if grep -q 'test-secret-value' "$CURL_TEST_LOG"; then exit 1; fi
if grep -q 'fixture-private-key' "$AZ_TEST_LOG" "$CURL_TEST_LOG"; then exit 1; fi
python3 - "$CURL_TEST_LOG" "$AZ_TEST_LOG" <<'PY'
import json
import pathlib
import sys

curl_entries = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
sftp_entries = [
    entry for entry in curl_entries
    if any(argument.startswith("sftp://") for argument in entry["args"])
]
assert len(sftp_entries) == 3
assert all("--insecure" in entry["args"] for entry in sftp_entries)
assert all(entry["key_mode"] == "0600" for entry in sftp_entries)
assert all(entry["key_matches_fixture"] for entry in sftp_entries)
assert all(not pathlib.Path(entry["key_path"]).exists() for entry in sftp_entries)
assert any("sftp://partner-a.example.test:2222/inbound/" in entry["args"] for entry in sftp_entries)
delete_commands = [
    entry["args"][entry["args"].index("--quote") + 1]
    for entry in sftp_entries if "--quote" in entry["args"]
]
assert delete_commands == ["rm /inbound/partner-file.csv", "rm /inbound/incomplete.csv.partial"]

az_entries = [json.loads(line) for line in pathlib.Path(sys.argv[2]).read_text().splitlines()]
reset_arguments = next(
    entry for entry in az_entries
    if entry[:3] == ["vm", "run-command", "invoke"] and "NAS_RESET_COMPLETE" in entry[entry.index("--scripts") + 1]
)
reset_script = reset_arguments[reset_arguments.index("--scripts") + 1]
assert "Get-SmbShare -Name 'share').Path" in reset_script
assert "$ErrorActionPreference = 'Stop'" in reset_script
assert "Get-ChildItem -LiteralPath" in reset_script
assert all(f"'{folder}'" in reset_script for folder in (
    "j3\\in", "j3\\out", "j3\\archive", "j4\\finance", "j4\\documents",
    "j4\\integration", "j4\\quarantine", "folderwatch\\in", "folderwatch\\processed",
))
assert "folderwatch\\out" not in reset_script
assert "New-Item" not in reset_script
PY
if AZ_TEST_NAS_RESET_OUTPUT='' bash "$root/scripts/reset-environment.sh" >"$temporary_directory/missing-marker.log" 2>&1; then
  echo "reset-environment succeeded without the NAS completion marker" >&2
  exit 1
fi
grep -q 'Resetting the NAS failed' "$temporary_directory/missing-marker.log"
echo "reset-environment bash tests passed."
