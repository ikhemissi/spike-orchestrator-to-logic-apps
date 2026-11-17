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

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

make_files() {
  case "$scenario" in
    j1)
      mkdir -p "$temporary_directory"
      cat >"$temporary_directory/invoices_20261124_001.csv" <<'EOF'
invoiceId,partnerId,amount,currency,date
INV-001,PARTNER-A,125.50,EUR,2026-11-24
EOF
      cat >"$temporary_directory/invoices_20261124_002.csv" <<'EOF'
invoiceId,partnerId,amount,currency,date
INV-002,PARTNER-A,240.00,EUR,2026-11-24
EOF
      printf 'locked,ignored\n' >"$temporary_directory/~lock_invoices.csv"
      awk 'BEGIN { for (row = 0; row < 500000; row++) printf "INV-%06d,PARTNER-A,1.00,EUR,2026-11-24\n", row }' \
        >"$temporary_directory/large_partner_extract.csv"
      ;;
    j2)
      cat >"$temporary_directory/participants_salon_2026.csv" <<'EOF'
participantId,event
P-001,Salon-2026
EOF
      printf '%%PDF-1.1\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%%%EOF\n' \
        >"$temporary_directory/brochure_export_fr.pdf"
      ;;
    j3|j3-failure)
      cat >"$temporary_directory/payroll_extract_202611.csv" <<'EOF'
employeeId,period,amount
EMP-001,2026-11,100.00
EOF
      cat >"$temporary_directory/hr_movements_202611.csv" <<'EOF'
employeeId,movement
EMP-002,transfer
EOF
      if [[ "$scenario" == j3-failure ]]; then
        printf 'employeeId,trigger\nEMP-003,FAIL\n' >"$temporary_directory/FAIL_locked_file.csv"
      fi
      ;;
    j4)
      printf 'account,amount\nA-001,100\n' >"$temporary_directory/budget_q4.csv"
      printf '%%PDF-1.1\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%%%EOF\n' \
        >"$temporary_directory/contract_partner_x.pdf"
      printf '<order id="000123"></order>\n' >"$temporary_directory/order_000123.xml"
      printf 'synthetic unknown payload\n' >"$temporary_directory/unknown_payload.dat"
      ;;
    j5)
      printf 'synthetic folder watch input\n' >"$temporary_directory/folderwatch_test.txt"
      ;;
  esac
}

seed_ftp() {
  local password file
  : "${PARTNER_VM_FQDN:?PARTNER_VM_FQDN is required for FTP scenarios}"
  IFS= read -r password < <(az keyvault secret show --vault-name "$KEY_VAULT_NAME" \
    --name ftp-partner-a-password --query value --output tsv --subscription "$AZURE_SUBSCRIPTION_ID")
  [[ -n "$password" ]] || { echo "Key Vault returned an empty FTP password" >&2; return 1; }
  for file in "$temporary_directory"/*; do
    curl_with_password "$password" --ftp-pasv --fail --silent --show-error \
      -T "$file" "ftp://$PARTNER_VM_FQDN/outbound/$scenario/"
  done
}

seed_nas() {
  local relative_directory file encoded remote_script share
  : "${NAS_VM_NAME:?NAS_VM_NAME is required for NAS scenarios}"
  : "${NAS_SHARE_UNC:?NAS_SHARE_UNC is required for NAS scenarios}"
  case "$scenario" in
    j3|j3-failure) relative_directory='j3\in' ;;
    j5) relative_directory='folderwatch\in' ;;
    *) return 0 ;;
  esac
  share=${NAS_SHARE_UNC//\'/\'\'}
  remote_script="\$share = '$share'; \$files = @("
  for file in "$temporary_directory"/*; do
    encoded=$(base64 <"$file" | tr -d '\n')
    remote_script+="@{ Path = '$relative_directory\\$(basename "$file")'; Content = '$encoded' };"
  done
  remote_script+="); foreach (\$file in \$files) { \$path = Join-Path \$share \$file.Path; New-Item -ItemType Directory -Force -Path (Split-Path \$path) | Out-Null; [IO.File]::WriteAllBytes(\$path, [Convert]::FromBase64String(\$file.Content)) }"
  # VERIFY: confirm the NAS VM supports RunPowerShellScript and the share is reachable by the VM agent.
  az vm run-command invoke --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$NAS_VM_NAME" --command-id RunPowerShellScript --scripts "$remote_script" --output none
}

make_files
case "$scenario" in
  j1|j2|j4) seed_ftp ;;
  j3|j3-failure|j5) seed_nas ;;
esac
printf 'Seeded scenario %s.\n' "$scenario"
