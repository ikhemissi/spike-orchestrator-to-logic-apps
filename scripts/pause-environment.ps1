# Pauses the spike outside working hours: disables the job workflows (J1-J5), so that their schedules do not fail
# against stopped servers, and deallocates the VMs. scripts/resume-environment.ps1 undoes it.
$ErrorActionPreference = 'Stop'

function Get-AzdValue([string] $Name) {
    $value = azd env get-value $Name
    if ($LASTEXITCODE -ne 0) { throw "azd value $Name is missing." }
    return $value
}

$resourceGroup = Get-AzdValue AZURE_RESOURCE_GROUP
$logicApp = Get-AzdValue LOGIC_APP_NAME
$jobWorkflows = @('wf-j1-partner-ftp-to-sftp', 'wf-j2-ftp-to-sharepoint', 'wf-j3-convert-onprem', 'wf-j4-ftp-sort-to-nas', 'wf-j5-nas-folderwatch')

$flowStateSettings = $jobWorkflows | ForEach-Object { "Workflows.$_.FlowState=Disabled" }
az logicapp config appsettings set --resource-group $resourceGroup --name $logicApp --settings @flowStateSettings --output none
if ($LASTEXITCODE -ne 0) { throw 'Could not disable the job workflows.' }
Write-Output "Disabled $($jobWorkflows.Count) job workflows."

$vmIds = @(az vm list --resource-group $resourceGroup --query '[].id' --output tsv)
if ($vmIds.Count -gt 0) {
    az vm deallocate --ids @vmIds --no-wait
    if ($LASTEXITCODE -ne 0) { throw 'Could not deallocate the VMs.' }
    Write-Output "Deallocating $($vmIds.Count) VMs."
}
