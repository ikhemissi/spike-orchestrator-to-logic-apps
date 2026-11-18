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

usage() {
  echo "Usage: $0 <partner-ip-block|partner-down|bad-ftp-password|nas-block|worker-stop|worker-system-account|restore-all>" >&2
}

[[ $# == 1 ]] || { usage; exit 2; }
fault=$1
case "$fault" in
  partner-ip-block|partner-down|bad-ftp-password|nas-block|worker-stop|worker-system-account|restore-all) ;;
  *) usage; echo "Unknown fault: $fault" >&2; exit 2 ;;
esac

restore_partner_ip() {
  local rules records name original_description_b64 original_prefixes_b64 original_description
  rules=$(az network nsg rule list --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --nsg-name "$PARTNER_NSG_NAME" --output json)
  records=$(python3 -c '
import base64, json, sys
for rule in json.load(sys.stdin):
    description = rule.get("description") or ""
    marker = "fault-restore:"
    if description.startswith(marker):
        state = json.loads(base64.b64decode(description[len(marker):]))
        print("\t".join((rule["name"], base64.b64encode(state["description"].encode()).decode(),
                         base64.b64encode(json.dumps(state["prefixes"]).encode()).decode())))
' <<<"$rules")
  [[ -n "$records" ]] || return 0
  while IFS=$'\t' read -r name original_description_b64 original_prefixes_b64; do
    original_description=$(printf '%s' "$original_description_b64" | base64 --decode)
    mapfile -t prefixes < <(printf '%s' "$original_prefixes_b64" | base64 --decode | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')
    # VERIFY: confirm the CLI update preserves all partner NSG rule fields not explicitly supplied here.
    az network nsg rule update --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
      --nsg-name "$PARTNER_NSG_NAME" --name "$name" --source-address-prefixes "${prefixes[@]}" \
      --description "$original_description" --output none
  done <<<"$records"
}

inject_partner_ip_block() {
  local rules record name state description prefixes_json
  rules=$(az network nsg rule list --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --nsg-name "$PARTNER_NSG_NAME" --output json)
  record=$(python3 -c '
import base64, json, sys
nat = sys.argv[1]
matches = []
for rule in json.load(sys.stdin):
    if rule.get("name") != "Allow-FTP-SFTP-From-NAT-And-Deployer":
        continue
    prefixes = rule.get("sourceAddressPrefixes") or ([rule["sourceAddressPrefix"]] if rule.get("sourceAddressPrefix") else [])
    if nat in prefixes:
        state = {"description": rule.get("description") or "", "prefixes": prefixes}
        encoded = base64.b64encode(json.dumps(state, separators=(",", ":")).encode()).decode()
        matches.append((rule["name"], encoded, prefixes))
if len(matches) != 1:
    raise SystemExit("Expected exactly one rule named Allow-FTP-SFTP-From-NAT-And-Deployer containing NAT_PUBLIC_IP; found %d" % len(matches))
name, encoded, prefixes = matches[0]
remaining = [prefix for prefix in prefixes if prefix != nat]
if not remaining:
    remaining = ["0.0.0.0/32"]
description = "fault-restore:" + encoded
if len(description) > 140:
    raise SystemExit("Partner NSG rule description is too long to store restore state")
print(name + "\t" + description + "\t" + json.dumps(remaining))
' "$NAT_PUBLIC_IP" <<<"$rules")
  IFS=$'\t' read -r name description prefixes_json <<<"$record"
  mapfile -t prefixes < <(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])))' "$prefixes_json")
  # VERIFY: confirm the CLI update preserves all partner NSG rule fields not explicitly supplied here.
  az network nsg rule update --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --nsg-name "$PARTNER_NSG_NAME" --name "$name" --source-address-prefixes "${prefixes[@]}" \
    --description "$description" --output none
}

invoke_partner_services() {
  local action=$1
  local script
  if [[ "$action" == stop ]]; then
    # VERIFY: partner VM runs Linux with vsftpd; ssh is stopped with it so the partner is unavailable.
    # shellcheck disable=SC2016
    script='state=/var/tmp/fault-partner-services; if [ -e "$state" ]; then echo "partner-down state already exists" >&2; exit 1; fi; : > "$state"; if systemctl is-active --quiet vsftpd; then echo vsftpd >> "$state"; fi; if systemctl is-active --quiet ssh; then echo ssh >> "$state"; fi; systemctl stop vsftpd ssh'
  else
    # VERIFY: restore only services that were active before fault injection.
    # shellcheck disable=SC2016
    script='state=/var/tmp/fault-partner-services; if [ -f "$state" ]; then while read -r service; do systemctl start "$service"; done < "$state"; rm -f "$state"; fi'
  fi
  az vm run-command invoke --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$PARTNER_VM_NAME" --command-id RunShellScript --scripts "$script" --output none
}

inject_nas_block() {
  local rules priority subnet_id subnet_prefix nas_ip
  # VERIFY: confirm Logic Apps Standard reports its VNet integration subnet through `az logicapp show`.
  subnet_id=$(az logicapp show --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$LOGIC_APP_NAME" --query properties.virtualNetworkSubnetId --output tsv)
  [[ -n "$subnet_id" && "$subnet_id" != None ]] || {
    echo "Logic app has no VNet integration subnet" >&2
    return 1
  }
  # VERIFY: confirm the subnet and NAS private-address queries match this environment's Azure CLI response shape.
  subnet_prefix=$(az network vnet subnet show --ids "$subnet_id" --query addressPrefix --output tsv)
  nas_ip=$(az vm list-ip-addresses --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$NAS_VM_NAME" --query '[0].virtualMachine.network.privateIpAddresses[0]' --output tsv)
  [[ -n "$subnet_prefix" && "$subnet_prefix" != None && -n "$nas_ip" && "$nas_ip" != None ]] || {
    echo "Could not resolve the Logic App subnet or NAS private IP" >&2
    return 1
  }
  rules=$(az network nsg rule list --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --nsg-name "$SERVERS_NSG_NAME" --output json)
  priority=$(python3 -c '
import json, sys
rules = json.load(sys.stdin)
if any(rule["name"] == "fault-nas-block" for rule in rules):
    raise SystemExit("NAS block rule already exists; restore it before injecting again")
used = {int(rule["priority"]) for rule in rules}
print(next((value for value in range(100, 4097) if value not in used), ""))
' <<<"$rules")
  [[ -n "$priority" ]] || { echo "No free NSG rule priority is available" >&2; return 1; }
  az network nsg rule create --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --nsg-name "$SERVERS_NSG_NAME" --name fault-nas-block --priority "$priority" \
    --direction Inbound --access Deny --protocol Tcp --source-address-prefixes "$subnet_prefix" \
    --source-port-ranges '*' --destination-address-prefixes "$nas_ip/32" --destination-port-ranges 445 --output none
}

worker_names() {
  IFS=',' read -r -a workers <<<"$WORKER_VM_NAMES"
  ((${#workers[@]} > 0)) || { echo "WORKER_VM_NAMES is empty" >&2; return 1; }
}

set_worker_running_state() {
  local mode=$1 worker resource_id state
  worker_names
  for worker in "${workers[@]}"; do
    resource_id=$(az vm show --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
      --name "$worker" --query id --output tsv)
    state=$(az vm get-instance-view --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
      --name "$worker" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv)
    if [[ "$mode" == stop ]]; then
      if [[ "$state" == PowerState/running ]]; then
        local existing_marker
        existing_marker=$(az vm show --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
          --name "$worker" --query tags.fault-was-running --output tsv)
        [[ -z "$existing_marker" || "$existing_marker" == None ]] || {
          echo "VM $worker already has the fault-was-running tag; refusing to overwrite it" >&2
          return 1
        }
        # VERIFY: Azure resource tags persist prior power state in Azure for restore-all.
        az tag update --resource-id "$resource_id" --operation Merge --tags fault-was-running=true --output none
        az vm stop --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" --name "$worker" --output none
      fi
    elif [[ "$(az vm show --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
      --name "$worker" --query tags.fault-was-running --output tsv)" == true ]]; then
      az vm start --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" --name "$worker" --output none
      az tag update --resource-id "$resource_id" --operation Delete --tags fault-was-running --output none
    fi
  done
}

worker_group_url() {
  printf 'https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Automation/automationAccounts/%s/hybridRunbookWorkerGroups/%s?api-version=2024-10-23' \
    "$AZURE_SUBSCRIPTION_ID" "$AZURE_RESOURCE_GROUP" "$AUTOMATION_ACCOUNT_NAME" "$HYBRID_WORKER_GROUP"
}

set_worker_system_account() {
  local operation=$1 url document body
  url=$(worker_group_url)
  # VERIFY: confirm the Hybrid Worker Group API version and `properties.credential` patch semantics before Azure use.
  document=$(az rest --method get --url "$url")
  body=$(python3 -c '
import json, sys
doc = json.load(sys.stdin)
tags = doc.get("tags") or {}
props = doc.get("properties") or {}
if sys.argv[1] == "inject":
    if "fault-original-credential" in tags:
        raise SystemExit("Worker system-account fault is already active")
    credential = props.get("credential")
    if not credential or not credential.get("name"):
        raise SystemExit("Worker group has no custom credential to restore")
    tags["fault-original-credential"] = credential["name"]
    body = {"properties": {"credential": None}, "tags": tags}
else:
    original = tags.pop("fault-original-credential", None)
    if original is None:
        print("{}")
        raise SystemExit
    body = {"properties": {"credential": {"name": original}}, "tags": tags}
print(json.dumps(body))
' "$operation" <<<"$document")
  [[ "$body" != '{}' ]] || return 0
  az rest --method patch --url "$url" --headers Content-Type=application/json --body "$body" --output none
}

restore_nas_block() {
  local rules exists
  rules=$(az network nsg rule list --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --nsg-name "$SERVERS_NSG_NAME" --output json)
  exists=$(python3 -c 'import json,sys; print(any(rule["name"] == "fault-nas-block" for rule in json.load(sys.stdin)))' <<<"$rules")
  [[ "$exists" == True ]] || return 0
  az network nsg rule delete --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --nsg-name "$SERVERS_NSG_NAME" --name fault-nas-block --output none
}

set_ftp_password_secret() {
  local password_value=$1 temporary_directory status
  temporary_directory=$(mktemp -d)
  chmod 700 "$temporary_directory"
  (umask 077; printf '%s' "$password_value" >"$temporary_directory/value")
  # VERIFY: confirm az keyvault secret set --file reads the secret value from a protected temporary file.
  if az keyvault secret set --vault-name "$KEY_VAULT_NAME" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name ftp-partner-a-password --file "$temporary_directory/value" --output none; then
    rm -rf "$temporary_directory"
  else
    status=$?
    rm -rf "$temporary_directory"
    return "$status"
  fi
}

restore_bad_password() {
  local version password
  version=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" \
    --subscription "$AZURE_SUBSCRIPTION_ID" --name ftp-partner-a-password --query tags.fault-restore-version --output tsv)
  [[ -n "$version" && "$version" != None ]] || return 0
  IFS= read -r password < <(az keyvault secret show --vault-name "$KEY_VAULT_NAME" \
    --subscription "$AZURE_SUBSCRIPTION_ID" --name ftp-partner-a-password --version "$version" --query value --output tsv)
  set_ftp_password_secret "$password"
  # VERIFY: confirm the Logic Apps Standard restart command is available in the deployed az CLI.
  az logicapp restart --name "$LOGIC_APP_NAME" --resource-group "$AZURE_RESOURCE_GROUP" \
    --subscription "$AZURE_SUBSCRIPTION_ID" --output none
}

inject_bad_password() {
  local current_id current_version
  local existing_restore_version
  existing_restore_version=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" \
    --subscription "$AZURE_SUBSCRIPTION_ID" --name ftp-partner-a-password \
    --query tags.fault-restore-version --output tsv)
  [[ -z "$existing_restore_version" || "$existing_restore_version" == None ]] || {
    echo "Bad FTP password fault is already active; restore it first" >&2
    return 1
  }
  current_id=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" \
    --subscription "$AZURE_SUBSCRIPTION_ID" --name ftp-partner-a-password --query id --output tsv)
  current_version=${current_id##*/}
  # VERIFY: secret version tags are supported by the deployed Key Vault CLI/API.
  az keyvault secret set --vault-name "$KEY_VAULT_NAME" \
    --subscription "$AZURE_SUBSCRIPTION_ID" --name ftp-partner-a-password --value invalid-test-password \
    --tags "fault-restore-version=$current_version" --output none
  # VERIFY: confirm the Logic Apps Standard restart command is available in the deployed az CLI.
  az logicapp restart --name "$LOGIC_APP_NAME" --resource-group "$AZURE_RESOURCE_GROUP" \
    --subscription "$AZURE_SUBSCRIPTION_ID" --output none
}

restore_all() {
  require_values AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID KEY_VAULT_NAME NAT_PUBLIC_IP PARTNER_VM_NAME PARTNER_NSG_NAME SERVERS_NSG_NAME \
    WORKER_VM_NAMES AUTOMATION_ACCOUNT_NAME HYBRID_WORKER_GROUP LOGIC_APP_NAME
  restore_partner_ip
  invoke_partner_services start
  restore_bad_password
  restore_nas_block
  set_worker_running_state restore
  set_worker_system_account restore
}

case "$fault" in
  partner-ip-block) require_values AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID NAT_PUBLIC_IP PARTNER_NSG_NAME; inject_partner_ip_block ;;
  partner-down) require_values AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID PARTNER_VM_NAME; invoke_partner_services stop ;;
  bad-ftp-password) require_values AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID KEY_VAULT_NAME LOGIC_APP_NAME; inject_bad_password ;;
  nas-block) require_values AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID LOGIC_APP_NAME NAS_VM_NAME SERVERS_NSG_NAME; inject_nas_block ;;
  worker-stop) require_values AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID WORKER_VM_NAMES; set_worker_running_state stop ;;
  worker-system-account) require_values AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID AUTOMATION_ACCOUNT_NAME HYBRID_WORKER_GROUP; set_worker_system_account inject ;;
  restore-all) restore_all ;;
esac

printf 'Applied fault %s.\n' "$fault"
