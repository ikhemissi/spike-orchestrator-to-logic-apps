# The Logic Apps identity is shared by the app and its resource role assignments.
resource "azurerm_user_assigned_identity" "logicapp" {
  name                = "id-${var.environment_name}-logicapp"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags
}

output "LOGICAPP_IDENTITY_ID" {
  value = azurerm_user_assigned_identity.logicapp.id
}

output "LOGICAPP_IDENTITY_CLIENT_ID" {
  value = azurerm_user_assigned_identity.logicapp.client_id
}

output "LOGICAPP_IDENTITY_PRINCIPAL_ID" {
  value = azurerm_user_assigned_identity.logicapp.principal_id
}
