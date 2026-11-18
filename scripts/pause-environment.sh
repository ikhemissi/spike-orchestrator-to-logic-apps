#!/usr/bin/env bash
# Pauses the spike outside working hours: disables the job workflows (J1-J5), so that their schedules do not fail
# against stopped servers, and deallocates the VMs. scripts/resume-environment.sh undoes it.
set -euo pipefail

azd_value() {
  azd env get-value "$1"
}

resource_group=$(azd_value AZURE_RESOURCE_GROUP)
logic_app=$(azd_value LOGIC_APP_NAME)
job_workflows=(wf-j1-partner-ftp-to-sftp wf-j2-ftp-to-sharepoint wf-j3-convert-onprem wf-j4-ftp-sort-to-nas wf-j5-nas-folderwatch)

flow_state_settings=()
for workflow in "${job_workflows[@]}"; do
  flow_state_settings+=("Workflows.${workflow}.FlowState=Disabled")
done
az logicapp config appsettings set --resource-group "$resource_group" --name "$logic_app" \
  --settings "${flow_state_settings[@]}" --output none
echo "Disabled ${#job_workflows[@]} job workflows."

mapfile -t vm_ids < <(az vm list --resource-group "$resource_group" --query "[].id" --output tsv)
if (( ${#vm_ids[@]} > 0 )); then
  az vm deallocate --ids "${vm_ids[@]}" --no-wait
  echo "Deallocating ${#vm_ids[@]} VMs."
fi
