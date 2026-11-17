#!/usr/bin/env bash
# Tests infra/hooks/preprovision/10-deployer-ip.sh with fake azd and curl on PATH: it keeps an existing DEPLOYER_IP,
# sets a detected IPv4 when empty, and refuses anything else.
set -euo pipefail

hook="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/preprovision/10-deployer-ip.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin"

# The fake azd keeps the environment in a file: "get-value" reads it, "set" writes it and logs the call.
cat > "$test_root/bin/azd" <<'AZD'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "env get-value" ]]; then
  [[ -s "$FAKE_AZD_VALUE" ]] || { echo "ERROR: key '$3' not found" >&2; exit 1; }
  cat "$FAKE_AZD_VALUE"
elif [[ "$1 $2" == "env set" ]]; then
  printf '%s' "$4" > "$FAKE_AZD_VALUE"
  printf 'set %s %s\n' "$3" "$4" >> "$FAKE_AZD_LOG"
fi
AZD
cat > "$test_root/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s' "$FAKE_PUBLIC_IP"
CURL
chmod +x "$test_root/bin/azd" "$test_root/bin/curl"

export PATH="$test_root/bin:$PATH"
export FAKE_AZD_VALUE="$test_root/value"
export FAKE_AZD_LOG="$test_root/azd.log"

fail() { echo "FAIL: $1" >&2; exit 1; }
reset_environment() { : > "$FAKE_AZD_VALUE"; : > "$FAKE_AZD_LOG"; }

echo "-- sets the detected IPv4 when DEPLOYER_IP is empty"
reset_environment
FAKE_PUBLIC_IP="203.0.113.8" bash "$hook" > "$test_root/out"
[[ "$(cat "$FAKE_AZD_LOG")" == "set DEPLOYER_IP 203.0.113.8" ]] || fail "expected azd env set DEPLOYER_IP 203.0.113.8"
grep -q "DEPLOYER_IP set to 203.0.113.8" "$test_root/out" || fail "expected the hook to print what it set"

echo "-- keeps an existing DEPLOYER_IP"
reset_environment
printf '198.51.100.20' > "$FAKE_AZD_VALUE"
FAKE_PUBLIC_IP="203.0.113.8" bash "$hook" > /dev/null
[[ ! -s "$FAKE_AZD_LOG" ]] || fail "expected no azd env set when DEPLOYER_IP exists"

echo "-- refuses a detected value that is not an IPv4 address"
reset_environment
if FAKE_PUBLIC_IP="2001:db8::1" bash "$hook" > /dev/null 2>&1; then fail "expected a failure for an IPv6 address"; fi
[[ ! -s "$FAKE_AZD_LOG" ]] || fail "expected no azd env set for an IPv6 address"

echo "all deployer-ip tests passed"
