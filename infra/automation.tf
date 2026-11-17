# Azure Automation account, published runbook, and Hybrid Runbook Workers.
variable "automation_runtime_version" {
  description = "PowerShell runtime version used by the Automation runbook."
  type        = string
  default     = "7.4"
}

variable "worker_run_as_custom_credential" {
  description = "Use the svc-azauto credential for Hybrid Worker jobs instead of Local System."
  type        = bool
  default     = true
}

locals {
  automation_account_name = "aa-${var.environment_name}-${local.token}"
  automation_runtime_name = "ps-${var.environment_name}-${replace(var.automation_runtime_version, ".", "")}"
}

resource "azurerm_automation_account" "main" {
  name                = local.automation_account_name
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Basic"
  tags                = local.network_tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_automation_runtime_environment" "powershell" {
  name                  = local.automation_runtime_name
  automation_account_id = azurerm_automation_account.main.id
  location              = var.location
  runtime_language      = "PowerShell"
  # VERIFY: PowerShell 7.4 runtime acceptance must be confirmed at first Azure deployment.
  runtime_version = var.automation_runtime_version
  # A runtime environment accepts at most 3 tags; it is a child of the tagged Automation account.
  tags = {}
}

resource "azurerm_automation_runbook" "convert_and_move" {
  name                     = "Invoke-ConvertAndMove"
  location                 = var.location
  resource_group_name      = azurerm_resource_group.main.name
  automation_account_name  = azurerm_automation_account.main.name
  log_progress             = true
  log_verbose              = true
  runbook_type             = "PowerShell"
  runtime_environment_name = azurerm_automation_runtime_environment.powershell.name
  content                  = file("${path.module}/../src/runbooks/Invoke-ConvertAndMove.ps1")
  tags                     = local.network_tags
}

resource "azurerm_automation_credential" "svc_azauto" {
  name                    = "cred-svc-azauto"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  # No machine prefix: on each worker the name resolves to that worker's own (mirrored) local account, so a job
  # still runs as svc-azauto when it fails over to hw02.
  username = "svc-azauto"
  password = random_password.svc_azauto.result
}

resource "azurerm_automation_hybrid_runbook_worker_group" "files" {
  name                    = "hwg-spike-files"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  credential_name         = var.worker_run_as_custom_credential ? azurerm_automation_credential.svc_azauto.name : null
}

resource "random_uuid" "worker" {
  for_each = toset(local.worker_names)
}

resource "azurerm_automation_hybrid_runbook_worker" "worker" {
  for_each = toset(local.worker_names)

  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  worker_group_name       = azurerm_automation_hybrid_runbook_worker_group.files.name
  vm_resource_id          = azurerm_windows_virtual_machine.worker[each.key].id
  worker_id               = random_uuid.worker[each.key].result
}

resource "azurerm_virtual_machine_extension" "hybrid_worker" {
  for_each = toset(local.worker_names)

  name               = "HybridWorkerForWindows"
  virtual_machine_id = azurerm_windows_virtual_machine.worker[each.key].id
  publisher          = "Microsoft.Azure.Automation.HybridWorker"
  type               = "HybridWorkerForWindows"
  # VERIFY: confirm extension handler version and settings at first Azure deployment.
  type_handler_version       = "1.1"
  auto_upgrade_minor_version = true
  settings = jsonencode({
    AutomationAccountURL = azurerm_automation_account.main.hybrid_service_url
  })

  depends_on = [azurerm_automation_hybrid_runbook_worker.worker]
}

resource "azurerm_monitor_diagnostic_setting" "automation" {
  name                       = "diag-automation"
  target_resource_id         = azurerm_automation_account.main.id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  enabled_log {
    category = "JobLogs"
  }

  enabled_log {
    category = "JobStreams"
  }
}

resource "azurerm_role_assignment" "logicapp_automation_job_operator" {
  scope                = azurerm_automation_account.main.id
  role_definition_name = "Automation Job Operator"
  principal_id         = azurerm_user_assigned_identity.logicapp.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "logicapp_automation_runbook_operator" {
  scope                = azurerm_automation_account.main.id
  role_definition_name = "Automation Runbook Operator"
  principal_id         = azurerm_user_assigned_identity.logicapp.principal_id
  principal_type       = "ServicePrincipal"
}

output "AUTOMATION_ACCOUNT_NAME" {
  value = azurerm_automation_account.main.name
}

output "AUTOMATION_ACCOUNT_ID" {
  value = azurerm_automation_account.main.id
}

output "HYBRID_WORKER_GROUP" {
  value = azurerm_automation_hybrid_runbook_worker_group.files.name
}

output "AUTOMATION_RUNBOOK_NAME" {
  value = azurerm_automation_runbook.convert_and_move.name
}
