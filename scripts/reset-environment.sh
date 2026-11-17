#!/usr/bin/env bash
set -euo pipefail

load_azd_values() {
  local missing=false name line key value
  for name in "$@"; do [[ -n "${!name:-}" ]] || missing=true; done
  [[ "$missing" == true ]] || return 0
  command -v azd >/dev/null || { echo "azd is required to load missing settings" >&2; return 1; }
  local -A wanted=()
  for name in "$@"; do wanted["$name"]=1; done
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    [[ -n "${wanted[$key]:-}" && -z "${!key:-}" ]] || continue
    value=${line#*=}
    if [[ "$value" == \"*\" ]]; then value=${value:1:${#value}-2}; fi
    export "$key=$value"
  done < <(azd env get-values)
}

require_values() {
  local name
  load_azd_values "$@"
  for name in "$@"; do [[ -n "${!name:-}" ]] || { echo "$name is required" >&2; return 1; }; done
}

require_values AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID KEY_VAULT_NAME PARTNER_VM_FQDN \
  NAS_VM_NAME NAS_SHARE_UNC DATA_STORAGE_ACCOUNT_NAME NAT_PUBLIC_IP PARTNER_VM_NAME PARTNER_NSG_NAME \
  SERVERS_NSG_NAME WORKER_VM_NAMES AUTOMATION_ACCOUNT_NAME HYBRID_WORKER_GROUP LOGIC_APP_NAME

# Restore FTP access and the partner VM before trying to clean up the FTP folders.
bash "$(dirname "$0")/inject-fault.sh" restore-all >/dev/null

curl_with_password() {
  local ftp_password=$1 escaped_password
  shift
  [[ "$ftp_password" != *$'\n'* && "$ftp_password" != *$'\r'* ]] || {
    echo "FTP password contains a newline" >&2
    return 1
  }
  escaped_password=${ftp_password//\\/\\\\}
  escaped_password=${escaped_password//\"/\\\"}
  printf 'user = "partner-a:%s"\n' "$escaped_password" | curl --config - "$@"
}

IFS= read -r password < <(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name ftp-partner-a-password \
  --subscription "$AZURE_SUBSCRIPTION_ID" --query value --output tsv)
[[ -n "$password" ]] || { echo "Key Vault returned an empty FTP password" >&2; exit 1; }

empty_ftp_directory() {
  local directory=$1 listing filename
  listing=$(curl_with_password "$password" --ftp-pasv --fail --silent --show-error \
    --list-only "ftp://$PARTNER_VM_FQDN/outbound/$directory/")
  while IFS= read -r filename; do
    [[ -n "$filename" ]] || continue
    [[ "$filename" == . || "$filename" == .. ]] && continue
    [[ "$filename" =~ ^[A-Za-z0-9._~-]+$ ]] || { echo "Unsafe FTP filename in $directory: $filename" >&2; exit 1; }
    # VERIFY: confirm the FTP server accepts absolute DELE/RMD paths and NLST directory entries.
    if curl_with_password "$password" --ftp-pasv --fail --silent --show-error \
      --quote "-DELE /outbound/$directory/$filename" "ftp://$PARTNER_VM_FQDN/"; then
      continue
    fi
    empty_ftp_directory "$directory/$filename"
    curl_with_password "$password" --ftp-pasv --fail --silent --show-error \
      --quote "-RMD /outbound/$directory/$filename" "ftp://$PARTNER_VM_FQDN/"
  done <<<"$listing"
}

for directory in j1 j2 j4 archive; do empty_ftp_directory "$directory"; done

# VERIFY: confirm the NAS VM supports RunPowerShellScript and the share is reachable by the VM agent.
nas_reset_script="\$share = '${NAS_SHARE_UNC//\'/\'\'}'; @('j3','j4','folderwatch') | ForEach-Object { \$path = Join-Path \$share \$_; if (Test-Path \$path) { Remove-Item -Recurse -Force \$path } }; @('j3\\in','j3\\out','j3\\archive','j4\\finance','j4\\documents','j4\\integration','j4\\quarantine','folderwatch\\in','folderwatch\\out') | ForEach-Object { New-Item -ItemType Directory -Force -Path (Join-Path \$share \$_) | Out-Null }"
az vm run-command invoke --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
  --name "$NAS_VM_NAME" --command-id RunPowerShellScript --scripts "$nas_reset_script" --output none

for container in sharepoint-sim run-reports; do
  # VERIFY: the deployer identity has Storage Blob Data Contributor on the test data account.
  az storage blob delete-batch --account-name "$DATA_STORAGE_ACCOUNT_NAME" --auth-mode login \
    --source "$container" --subscription "$AZURE_SUBSCRIPTION_ID" --output none
done

printf 'Environment reset; all injected faults restored.\n'
