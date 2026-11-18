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

bash "$root/scripts/inject-fault.sh" partner-down >/dev/null
bash "$root/scripts/inject-fault.sh" bad-ftp-password >/dev/null
output=$(bash "$root/scripts/reset-environment.sh")
[[ "$output" == "Environment reset; all injected faults restored." ]]
grep -q -- '-DELE /outbound/j1/sample.txt' "$CURL_TEST_LOG"
grep -q 'ftp://partner-a.example.test:2021/' "$CURL_TEST_LOG"
grep -q -- '-DELE /outbound/archive/sample.txt' "$CURL_TEST_LOG"
grep -q 'sharepoint-sim' "$AZ_TEST_LOG"
grep -q 'run-reports' "$AZ_TEST_LOG"
grep -q 'RunPowerShellScript' "$AZ_TEST_LOG"
grep -q -- '--test-password-restored' "$CURL_TEST_LOG"
if grep -q 'test-secret-value' "$AZ_TEST_LOG"; then exit 1; fi
if grep -q 'test-secret-value' "$CURL_TEST_LOG"; then exit 1; fi
echo "reset-environment bash tests passed."
