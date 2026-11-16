#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/../src/logicapp" && pwd)"

: "${AZURE_RESOURCE_GROUP:?Set AZURE_RESOURCE_GROUP to the Logic App resource group}"
: "${LOGIC_APP_NAME:?Set LOGIC_APP_NAME to the Logic App name}"

if [[ ! -f "$project_dir/.funcignore" ]]; then
  echo "Missing .funcignore in $project_dir" >&2
  exit 1
fi

should_ignore() {
  local relative_path="$1"
  local relative_path_lower="${relative_path,,}"
  local pattern
  local pattern_lower
  local segment
  local -a path_segments

  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    pattern="${pattern%$'\r'}"
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    pattern="${pattern%/}"
    pattern_lower="${pattern,,}"

    if [[ "$pattern" == */* ]]; then
      # .funcignore entries are glob patterns.
      # shellcheck disable=SC2254
      case "$relative_path_lower" in
        $pattern_lower) return 0 ;;
      esac
      continue
    fi

    IFS='/' read -r -a path_segments <<< "$relative_path_lower"
    for segment in "${path_segments[@]}"; do
      # .funcignore entries are glob patterns.
      # shellcheck disable=SC2254
      case "$segment" in
        $pattern_lower) return 0 ;;
      esac
    done
  done < "$project_dir/.funcignore"

  return 1
}

zip_directory="$(mktemp -d "${TMPDIR:-/tmp}/logicapp-deploy.XXXXXX")"
zip_path="$zip_directory/project.zip"
trap 'rm -rf -- "$zip_directory"' EXIT

cd "$project_dir"
mapfile -d '' -t project_files < <(find . -type f -print0)
files_to_zip=()
for project_file in "${project_files[@]}"; do
  relative_path="${project_file#./}"
  if ! should_ignore "$relative_path"; then
    files_to_zip+=("$relative_path")
  fi
done

if ((${#files_to_zip[@]} == 0)); then
  echo "No deployable files found in $project_dir" >&2
  exit 1
fi

zip -q "$zip_path" "${files_to_zip[@]}"

az logicapp deployment source config-zip \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$LOGIC_APP_NAME" \
  --src "$zip_path"
az logicapp restart \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$LOGIC_APP_NAME"

subscription_id="$(az account show --query id --output tsv)"
if [[ -z "$subscription_id" ]]; then
  echo "Azure CLI did not return a subscription ID" >&2
  exit 1
fi

workflow_api_url="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.Web/sites/$LOGIC_APP_NAME/hostruntime/runtime/webhooks/workflow/api/management/workflows?api-version=2018-11-01"
az rest --method get --url "$workflow_api_url"
