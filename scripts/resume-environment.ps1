# Resumes the spike after scripts/pause-environment.ps1: starts the VMs, waits until they run, then enables the job
# workflows again.
$ErrorActionPreference = 'Stop'

function Get-AzdValue([string] $Name) {
    $value = azd env get-value $Name
    if ($LASTEXITCODE -ne 0) { throw "azd value $Name is missing." }
    return $value
}

$resourceGroup = Get-AzdValue AZURE_RESOURCE_GROUP
$logicApp = Get-AzdValue LOGIC_APP_NAME
$jobWorkflows = @('wf-j1-partner-ftp-to-sftp', 'wf-j2-ftp-to-sharepoint', 'wf-j3-convert-onprem', 'wf-j4-ftp-sort-to-nas', 'wf-j5-nas-folderwatch')

$vmIds = @(az vm list --resource-group $resourceGroup --query '[].id' --output tsv)
if ($vmIds.Count -gt 0) {
    az vm start --ids @vmIds --output none
    if ($LASTEXITCODE -ne 0) { throw 'Could not start the VMs.' }
    Write-Output "Started $($vmIds.Count) VMs."
}

$flowStateSettings = $jobWorkflows | ForEach-Object { "Workflows.$_.FlowState=Enabled" }
az logicapp config appsettings set --resource-group $resourceGroup --name $logicApp --settings @flowStateSettings --output none
if ($LASTEXITCODE -ne 0) { throw 'Could not enable the job workflows.' }
Write-Output "Enabled $($jobWorkflows.Count) job workflows."
