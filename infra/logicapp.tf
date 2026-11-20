# The Logic App (Standard) that runs the jobs (SPEC §3.3, §3.6, §3.8): a WS1 plan, its runtime storage, the app with
# VNet integration (all outbound traffic through the spoke, so partners see the NAT Gateway's IP and the NAS is reached
# over the peering), the user-assigned identity of identity.tf, Entra-authenticated telemetry, and the data storage
# account for run reports and the SharePoint stand-in, reached with the identity only.

locals {
  logicapp_name = "logic-${var.environment_name}-${local.token}"
  # Storage account names: lowercase letters and digits, at most 24 characters.
  logicapp_runtime_storage_name = "st${local.compact_name}rt${local.token}"
  data_storage_name             = "st${local.compact_name}dt${local.token}"
}

resource "azurerm_service_plan" "logicapp" {
  name                   = "asp-${var.environment_name}-logicapp"
  resource_group_name    = azurerm_resource_group.main.name
  location               = var.location
  os_type                = "Windows"
  sku_name               = "WS1"
  zone_balancing_enabled = false # A spike; production decides zone redundancy when the plan is created.
  tags                   = local.network_tags
}

# The runtime's own storage (triggers, run history, content share). The content share of a Workflow Standard plan
# is reached with an account key, so shared keys stay enabled here; workflows never use this account (decision D6).
resource "azurerm_storage_account" "logicapp_runtime" {
  name                            = local.logicapp_runtime_storage_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  tags                            = local.network_tags
}

# With the content share reached over the virtual network, the platform does not create the share: a new app waits
# for it and never starts (found in the rebuild from scratch, D17).
resource "azurerm_storage_share" "logicapp_content" {
  name               = "${local.logicapp_name}-content"
  storage_account_id = azurerm_storage_account.logicapp_runtime.id
  quota              = 50
}

resource "azurerm_logic_app_standard" "main" {
  name                            = local.logicapp_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  app_service_plan_id             = azurerm_service_plan.logicapp.id
  storage_account_name            = azurerm_storage_account.logicapp_runtime.name
  storage_account_access_key      = azurerm_storage_account.logicapp_runtime.primary_access_key
  storage_account_share_name      = azurerm_storage_share.logicapp_content.name
  version                         = "~4"
  use_extension_bundle            = true
  bundle_version                  = "[1.*, 2.0.0)"
  https_only                      = true
  virtual_network_subnet_id       = local.network.subnet_ids["logicapp-integration"]
  key_vault_reference_identity_id = azurerm_user_assigned_identity.logicapp.id
  # The NAS mount (logicapp-connections.tf) goes through the integrated network too.
  vnet_content_share_enabled = true
  # Kept public so that the deployer can push the workflows (zip deployment); production with private inbound
  # access deploys from a runner inside the network (decision D7).
  public_network_access = "Enabled"
  # Deployments authenticate with Entra (az, azd), never with publishing credentials.
  ftp_publish_basic_authentication_enabled = false
  scm_publish_basic_authentication_enabled = false
  tags                                     = merge(local.network_tags, { "azd-service-name" = "logicapp" })

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.logicapp.id]
  }

  site_config {
    vnet_route_all_enabled = true
    min_tls_version        = "1.2"
    ftps_state             = "Disabled"
  }

  app_settings = merge(local.logicapp_settings, local.logicapp_connection_settings)

  lifecycle {
    # Set by the zip deployment, by Application Insights and by scripts/pause-environment and the test runner.
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
      app_settings["JOB_RECURRENCE_MINUTES"],
      app_settings["Workflows.wf-j1-partner-ftp-to-sftp.FlowState"],
      app_settings["Workflows.wf-j2-ftp-to-sharepoint.FlowState"],
      app_settings["Workflows.wf-j3-convert-onprem.FlowState"],
      app_settings["Workflows.wf-j4-ftp-sort-to-nas.FlowState"],
      app_settings["Workflows.wf-j5-nas-folderwatch.FlowState"],
      tags["hidden-link: /app-insights-resource-id"],
    ]
  }

  depends_on = [
    azurerm_role_assignment.logicapp_key_vault_secrets,
    azurerm_role_assignment.logicapp_telemetry,
  ]
}

locals {
  # Runtime settings; the connection settings (hosts, accounts, Key Vault references) are in
  # local.logicapp_connection_settings, next to the resources they point at.
  logicapp_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = module.monitoring.application_insights_connection_string
    # Application Insights accepts only Entra-authenticated telemetry: the app sends it as its identity.
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "ClientId=${azurerm_user_assigned_identity.logicapp.client_id};Authorization=AAD"
    LOGICAPP_IDENTITY_RESOURCE_ID             = azurerm_user_assigned_identity.logicapp.id
    DATA_BLOB_ENDPOINT                        = azurerm_storage_account.data.primary_blob_endpoint
  }
}

resource "azurerm_role_assignment" "logicapp_telemetry" {
  scope                = module.monitoring.application_insights_id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.logicapp.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_monitor_diagnostic_setting" "logicapp" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_logic_app_standard.main.id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  enabled_log {
    category = "WorkflowRuntime"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Run reports (wf-child-run-report) and the SharePoint stand-in of J2, reached by the Logic App's identity only.
resource "azurerm_storage_account" "data" {
  name                            = local.data_storage_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  tags                            = local.network_tags
}

resource "azurerm_storage_container" "data" {
  for_each              = toset(["run-reports", "sharepoint-sim"])
  name                  = each.key
  storage_account_id    = azurerm_storage_account.data.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "logicapp_data_blobs" {
  scope                = azurerm_storage_account.data.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.logicapp.principal_id
  principal_type       = "ServicePrincipal"
}

# The deployer's scripts and tests read and reset the containers with their own Entra identity.
resource "azurerm_role_assignment" "deployer_data_blobs" {
  scope                = azurerm_storage_account.data.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# The workspace's customer ID, which log queries (scripts, tests) need; the monitoring module outputs its resource ID.
data "azurerm_log_analytics_workspace" "main" {
  name                = provider::azurerm::parse_resource_id(module.monitoring.log_analytics_workspace_id)["resource_name"]
  resource_group_name = azurerm_resource_group.main.name
}

output "LOGIC_APP_NAME" { value = azurerm_logic_app_standard.main.name }
output "DATA_STORAGE_ACCOUNT_NAME" { value = azurerm_storage_account.data.name }
output "LOG_ANALYTICS_WORKSPACE_ID" { value = data.azurerm_log_analytics_workspace.main.workspace_id }
