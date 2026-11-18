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
export NAS_VM_NAME=nas-test
export NAS_SHARE_UNC='\\nas01.corp.local\share'

output=$(bash "$root/scripts/seed-test-data.sh" --scenario j1)
[[ "$output" == "Seeded scenario j1." ]]
if grep -q 'test-secret-value' <<<"$output"; then exit 1; fi
grep -q '"-T"' "$CURL_TEST_LOG"
grep -q -- '--ftp-pasv' "$CURL_TEST_LOG"
grep -q -- '--stdin-user-configured' "$CURL_TEST_LOG"
grep -q 'large_partner_extract.csv' "$CURL_TEST_LOG"
grep -q '~lock_invoices.csv' "$CURL_TEST_LOG"
grep -q 'ftp://partner-a.example.test:2121/outbound/j1/' "$CURL_TEST_LOG"
grep -q 'ftp-partner-a-password' "$AZ_TEST_LOG"
if grep -q 'test-secret-value' "$AZ_TEST_LOG"; then exit 1; fi

: >"$CURL_TEST_LOG"
export PARTNER_FTP_PORT=2021
output=$(bash "$root/scripts/seed-test-data.sh" --scenario j2)
[[ "$output" == "Seeded scenario j2." ]]
grep -q 'ftp://partner-a.example.test:2021/outbound/j2/' "$CURL_TEST_LOG"

: >"$AZ_TEST_LOG"
output=$(bash "$root/scripts/seed-test-data.sh" --scenario j3-failure)
[[ "$output" == "Seeded scenario j3-failure." ]]
grep -q 'RunPowerShellScript' "$AZ_TEST_LOG"
grep -q 'FAIL_locked_file.csv' "$AZ_TEST_LOG"
if grep -q 'test-secret-value' "$CURL_TEST_LOG"; then exit 1; fi

if bash "$root/scripts/seed-test-data.sh" --scenario unknown >/dev/null 2>&1; then
  echo "unknown scenario unexpectedly succeeded" >&2
  exit 1
fi

echo "seed-test-data bash tests passed."
