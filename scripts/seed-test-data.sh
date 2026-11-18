#!/usr/bin/env bash
set -euo pipefail

load_azd_values() {
  local missing=false name line key value
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing=true
  done
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

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_directory/.." && pwd)

usage() {
  echo "Usage: $0 --scenario <j1|j2|j3|j3-failure|j4|j5>" >&2
}

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

if [[ $# != 2 || "$1" != "--scenario" ]]; then usage; exit 2; fi
scenario=$2
case "$scenario" in
  j1|j2|j3|j3-failure|j4|j5) ;;
  *) usage; echo "Unknown scenario: $scenario" >&2; exit 2 ;;
esac

load_azd_values AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID KEY_VAULT_NAME PARTNER_VM_FQDN NAS_VM_NAME NAS_SHARE_UNC
: "${AZURE_RESOURCE_GROUP:?AZURE_RESOURCE_GROUP is required}"
: "${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"
: "${KEY_VAULT_NAME:?KEY_VAULT_NAME is required}"
if [[ -z "${PARTNER_FTP_PORT:-}" ]] && command -v azd >/dev/null; then
  load_azd_values PARTNER_FTP_PORT
fi
PARTNER_FTP_PORT=${PARTNER_FTP_PORT:-2121}

data_job=$scenario
if [[ "$scenario" == j3-failure ]]; then
  data_job=j3
fi
scenario_directory="$repository_root/test-data/$data_job"
if [[ "$scenario" == j1 && ! -f "$scenario_directory/large_partner_extract.csv" ]]; then
  bash "$repository_root/test-data/generate-large-files.sh"
fi

seed_files=()
for file in "$scenario_directory"/*; do
  [[ -f "$file" ]] || continue
  if [[ "$scenario" == j3 && "$(basename "$file")" == FAIL_locked_file.csv ]]; then
    continue
  fi
  seed_files+=("$file")
done
if [[ ${#seed_files[@]} == 0 ]]; then
  echo "No test-data files found for scenario $scenario in $scenario_directory" >&2
  exit 1
fi

seed_ftp() {
  local password file
  : "${PARTNER_VM_FQDN:?PARTNER_VM_FQDN is required for FTP scenarios}"
  IFS= read -r password < <(az keyvault secret show --vault-name "$KEY_VAULT_NAME" \
    --name ftp-partner-a-password --query value --output tsv --subscription "$AZURE_SUBSCRIPTION_ID")
  [[ -n "$password" ]] || { echo "Key Vault returned an empty FTP password" >&2; return 1; }
  for file in "${seed_files[@]}"; do
    curl_with_password "$password" --ftp-pasv --fail --silent --show-error \
      -T "$file" "ftp://$PARTNER_VM_FQDN:$PARTNER_FTP_PORT/outbound/$scenario/"
  done
}

seed_nas() {
  local relative_directory file encoded remote_script share_name file_size
  : "${NAS_VM_NAME:?NAS_VM_NAME is required for NAS scenarios}"
  : "${NAS_SHARE_UNC:?NAS_SHARE_UNC is required for NAS scenarios}"
  case "$scenario" in
    j3|j3-failure) relative_directory='j3\in' ;;
    j5) relative_directory='folderwatch\in' ;;
    *) return 0 ;;
  esac
  # On the NAS VM itself, run command runs as Local System, which has no rights on the share: write to the share's
  # local folder instead, found from the share name (the last part of NAS_SHARE_UNC).
  share_name=${NAS_SHARE_UNC##*\\}
  share_name=${share_name//\'/\'\'}
  remote_script="\$ErrorActionPreference = 'Stop'; \$share = (Get-SmbShare -Name '$share_name').Path; \$files = @("
  for file in "${seed_files[@]}"; do
    file_size=$(wc -c <"$file")
    if (( file_size > 262144 )); then
      echo "NAS file exceeds the 256 KiB Run Command limit: $file ($file_size bytes)" >&2
      return 1
    fi
    encoded=$(base64 <"$file" | tr -d '\n')
    remote_script+="@{ Path = '$relative_directory\\$(basename "$file")'; Content = '$encoded' };"
  done
  remote_script+="); foreach (\$file in \$files) { \$path = Join-Path \$share \$file.Path; New-Item -ItemType Directory -Force -Path (Split-Path \$path) | Out-Null; [IO.File]::WriteAllBytes(\$path, [Convert]::FromBase64String(\$file.Content)) }; 'SEEDED'"
  local script_size
  script_size=$(printf '%s' "$remote_script" | wc -c)
  if (( script_size > 28672 )); then
    echo "NAS Run Command script exceeds the 28 KiB process argument limit after base64 encoding ($script_size bytes)" >&2
    return 1
  fi
  # Run command reports success even when the script fails: check that the script reached its end.
  local run_output
  run_output=$(az vm run-command invoke --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$NAS_VM_NAME" --command-id RunPowerShellScript --scripts "$remote_script" \
    --query "value[0].message" --output tsv)
  if [[ "$run_output" != *SEEDED* ]]; then
    echo "Seeding the NAS failed: $run_output" >&2
    return 1
  fi
}

case "$scenario" in
  j1|j2|j4) seed_ftp ;;
  j3|j3-failure|j5) seed_nas ;;
esac
printf 'Seeded scenario %s.\n' "$scenario"
