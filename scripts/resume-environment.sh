#!/usr/bin/env bash
# Resumes the spike after scripts/pause-environment.sh: starts the VMs, waits until they run, then enables the job
# workflows again.
set -euo pipefail

azd_value() {
  azd env get-value "$1"
}

resource_group=$(azd_value AZURE_RESOURCE_GROUP)
logic_app=$(azd_value LOGIC_APP_NAME)
job_workflows=(wf-j1-partner-ftp-to-sftp wf-j2-ftp-to-sharepoint wf-j3-convert-onprem wf-j4-ftp-sort-to-nas wf-j5-nas-folderwatch)

mapfile -t vm_ids < <(az vm list --resource-group "$resource_group" --query "[].id" --output tsv)
if (( ${#vm_ids[@]} > 0 )); then
  az vm start --ids "${vm_ids[@]}" --output none
  echo "Started ${#vm_ids[@]} VMs."
fi

flow_state_settings=()
for workflow in "${job_workflows[@]}"; do
  flow_state_settings+=("Workflows.${workflow}.FlowState=Enabled")
done
az logicapp config appsettings set --resource-group "$resource_group" --name "$logic_app" \
  --settings "${flow_state_settings[@]}" --output none
echo "Enabled ${#job_workflows[@]} job workflows."
