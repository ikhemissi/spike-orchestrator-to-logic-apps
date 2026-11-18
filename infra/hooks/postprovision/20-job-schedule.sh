#!/usr/bin/env bash
# Creates the app setting JOB_RECURRENCE_MINUTES (how often J1-J4 run) when it is missing. Terraform ignores this
# setting because scripts change it (pause, test runs); a key that Terraform ignores is never written by it.
set -euo pipefail

resource_group=$(azd env get-value AZURE_RESOURCE_GROUP)
logic_app=$(azd env get-value LOGIC_APP_NAME)
default_minutes=15

current=$(az logicapp config appsettings list --resource-group "$resource_group" --name "$logic_app" \
  --query "[?name=='JOB_RECURRENCE_MINUTES'].value | [0]" --output tsv)
if [[ -n "$current" ]]; then
  echo "JOB_RECURRENCE_MINUTES is already set: $current"
  exit 0
fi

az logicapp config appsettings set --resource-group "$resource_group" --name "$logic_app" \
  --settings "JOB_RECURRENCE_MINUTES=$default_minutes" --output none
echo "JOB_RECURRENCE_MINUTES set to $default_minutes"
