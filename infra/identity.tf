# The Logic App's identity, user-assigned so that its role assignments (Key Vault, storage, Automation) exist before
# the app starts resolving Key Vault references: a system-assigned identity would only exist once the app does.

resource "azurerm_user_assigned_identity" "logicapp" {
  name                = "id-${var.environment_name}-logicapp"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.network_tags
}

resource "azurerm_role_assignment" "logicapp_key_vault_secrets" {
  scope                = module.key_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.logicapp.principal_id
  principal_type       = "ServicePrincipal"
}

output "LOGIC_APP_IDENTITY_CLIENT_ID" { value = azurerm_user_assigned_identity.logicapp.client_id }
