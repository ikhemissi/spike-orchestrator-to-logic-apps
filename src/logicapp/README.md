# Logic Apps Standard project

The primary deployment path is `azd up`, using the `azure.logicappsstandard`
extension configured in the repository's `azure.yaml`.

If that extension is unavailable, provision the infrastructure with
`terraform apply` from `infra/`, then deploy the Logic App with the fallback
script:

```bash
export AZURE_RESOURCE_GROUP="<resource-group>"
export LOGIC_APP_NAME="<logic-app-name>"
scripts/deploy-logicapp.sh
```

In PowerShell 7, set the same environment variables and run
`scripts/deploy-logicapp.ps1`. Both scripts package this project according to
`.funcignore` (a simplified reading: each line is a glob matched against a
path segment, or against the whole relative path when it contains `/`;
negations are not supported), deploy the zip, restart the app, and list its workflows using
the Azure management API.

`# VERIFY` before deployment: the workflow extension bundle version range in
`host.json`, the enhanced telemetry setting
`extensions.workflow.Settings."Runtime.ApplicationInsightTelemetryVersion": "v2"`
in `host.json` (SPEC §3.6), the `APP_KIND` and `FUNCTIONS_WORKER_RUNTIME`
values in `local.settings.json.sample`,
the `az logicapp deployment source config-zip` and `az logicapp restart`
commands and flags, and the management API endpoint and API version in the
fallback scripts. These values have not been checked against a live Azure
CLI/runtime in this offline task.

For local development, copy `local.settings.json.sample` to
`local.settings.json` and fill in the values required by the local runtime.
Never commit `local.settings.json`.
