#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
temporary_directory=$(mktemp -d)
oversized_fixture=
cleanup() {
  rm -rf "$temporary_directory"
  if [[ -n "$oversized_fixture" ]]; then
    rm -f "$oversized_fixture"
  fi
}
trap cleanup EXIT
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

assert_fixture_uploads() {
  python3 - "$root" "$1" "$2" <<'PY'
import base64
import hashlib
import json
import os
import re
import sys

root, scenario, transport = sys.argv[1:]
expected_names = {
    "j1": ["invoices_20261124_001.csv", "invoices_20261124_002.csv", "~lock_invoices.csv", "large_partner_extract.csv"],
    "j2": ["brochure_export_fr.pdf", "participants_salon_2026.csv"],
    "j3": ["hr_movements_202611.csv", "payroll_extract_202611.csv"],
    "j3-failure": ["FAIL_locked_file.csv", "hr_movements_202611.csv", "payroll_extract_202611.csv"],
    "j4": ["budget_q4.csv", "contract_partner_x.pdf", "order_000123.xml", "unknown_payload.dat"],
    "j5": ["folderwatch_test.txt"],
}[scenario]

if transport == "ftp":
    with open(os.environ["CURL_TEST_LOG"], encoding="utf-8") as log_file:
        calls = [json.loads(line) for line in log_file]
    uploads = [call for call in calls if "-T" in call["args"]]
    assert len(uploads) == len(expected_names), (scenario, len(uploads), expected_names)
    for call in uploads:
        arguments = call["args"]
        name = os.path.basename(arguments[arguments.index("-T") + 1])
        assert name in expected_names, (scenario, name, expected_names)
        source = os.path.join(root, "test-data", scenario, name)
        with open(source, "rb") as source_file:
            expected_hash = hashlib.sha256(source_file.read()).hexdigest()
        assert call["sha256"] == expected_hash, (scenario, name)
else:
    with open(os.environ["AZ_TEST_LOG"], encoding="utf-8") as log_file:
        calls = [json.loads(line) for line in log_file]
    run_commands = [call for call in calls if "RunPowerShellScript" in call]
    assert len(run_commands) == 1, (scenario, len(run_commands))
    command = run_commands[0]
    script = command[command.index("--scripts") + 1]
    entries = re.findall(r"Path = '([^']+)'; Content = '([^']+)'", script)
    assert len(entries) == len(expected_names), (scenario, len(entries), expected_names)
    for relative_path, encoded in entries:
        name = os.path.basename(relative_path.replace("\\", "/"))
        assert name in expected_names, (scenario, name, expected_names)
        source = os.path.join(root, "test-data", scenario.split("-")[0], name)
        with open(source, "rb") as source_file:
            expected_content = source_file.read()
        assert base64.b64decode(encoded) == expected_content, (scenario, name)
PY
}

output=$(bash "$root/scripts/seed-test-data.sh" --scenario j1)
[[ "$output" == "Seeded scenario j1." ]]
if grep -q 'test-secret-value' <<<"$output"; then exit 1; fi
grep -q -- '--ftp-pasv' "$CURL_TEST_LOG"
grep -q -- '--stdin-user-configured' "$CURL_TEST_LOG"
grep -q 'ftp://partner-a.example.test:2121/outbound/j1/' "$CURL_TEST_LOG"
grep -q 'ftp-partner-a-password' "$AZ_TEST_LOG"
if grep -q 'test-secret-value' "$AZ_TEST_LOG"; then exit 1; fi
assert_fixture_uploads j1 ftp

: >"$CURL_TEST_LOG"
export PARTNER_FTP_PORT=2021
output=$(bash "$root/scripts/seed-test-data.sh" --scenario j2)
[[ "$output" == "Seeded scenario j2." ]]
grep -q 'ftp://partner-a.example.test:2021/outbound/j2/' "$CURL_TEST_LOG"
assert_fixture_uploads j2 ftp

for scenario in j3 j3-failure j5; do
  : >"$AZ_TEST_LOG"
  output=$(bash "$root/scripts/seed-test-data.sh" --scenario "$scenario")
  [[ "$output" == "Seeded scenario $scenario." ]]
  grep -q 'RunPowerShellScript' "$AZ_TEST_LOG"
  assert_fixture_uploads "$scenario" nas
done

oversized_fixture=$(mktemp "$root/test-data/j3/oversize.XXXXXX")
truncate -s 262145 "$oversized_fixture"
if output=$(bash "$root/scripts/seed-test-data.sh" --scenario j3 2>&1); then
  echo "oversized NAS fixture unexpectedly succeeded" >&2
  exit 1
fi
[[ "$output" == *"NAS file exceeds the 256 KiB Run Command limit"* ]]
rm -f "$oversized_fixture"
oversized_fixture=$(mktemp "$root/test-data/j3/oversize.XXXXXX")
truncate -s 200000 "$oversized_fixture"
if output=$(bash "$root/scripts/seed-test-data.sh" --scenario j3 2>&1); then
  echo "oversized encoded NAS payload unexpectedly succeeded" >&2
  exit 1
fi
[[ "$output" == *"NAS Run Command script exceeds 256 KiB after base64 encoding"* ]]

: >"$CURL_TEST_LOG"
output=$(bash "$root/scripts/seed-test-data.sh" --scenario j4)
[[ "$output" == "Seeded scenario j4." ]]
assert_fixture_uploads j4 ftp

if bash "$root/scripts/seed-test-data.sh" --scenario unknown >/dev/null 2>&1; then
  echo "unknown scenario unexpectedly succeeded" >&2
  exit 1
fi

echo "seed-test-data bash tests passed."
