#!/usr/bin/env bash
# Sets DEPLOYER_IP in the azd environment, when empty, to this machine's public IPv4: the partner NSG allows it
# (infra/network.tf), so a fresh `azd up` needs no manual step. An existing value is kept.
set -euo pipefail

# The azd environment is the source of truth, not a value left in the shell.
current_ip="$(azd env get-value DEPLOYER_IP 2>/dev/null || true)"
if [[ -n "$current_ip" ]]; then
  echo "DEPLOYER_IP is already set: $current_ip"
  exit 0
fi

detected_ip="$(curl -fsS --max-time 10 https://api.ipify.org)"
if [[ ! "$detected_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "The detected public IP is not an IPv4 address: '$detected_ip'. Set it with: azd env set DEPLOYER_IP <ip>" >&2
  exit 1
fi

# VERIFY: azd reloads the environment after the preprovision hooks, so main.tfvars.json sees the new value.
azd env set DEPLOYER_IP "$detected_ip"
echo "DEPLOYER_IP set to $detected_ip (detected with api.ipify.org)"
