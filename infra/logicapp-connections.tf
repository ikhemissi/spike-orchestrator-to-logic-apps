# The settings behind the workflows' connections (src/logicapp/connections.json) and parameters
# (src/logicapp/parameters.json): hosts, accounts and secrets, as app settings. Secrets are Key Vault references,
# resolved with the Logic App's identity; Terraform writes the secrets with the VMs that use them (vms.tf).

locals {
  key_vault_reference = "@Microsoft.KeyVault(VaultName=${module.key_vault.name};SecretName=%s)"

  logicapp_connection_settings = {
    FTP_PARTNER_A_HOST         = azurerm_public_ip.partner.fqdn
    FTP_PARTNER_A_USERNAME     = "partner-a"
    FTP_PARTNER_A_PASSWORD     = format(local.key_vault_reference, "ftp-partner-a-password")
    SFTP_PARTNER_B_HOST        = azurerm_public_ip.partner.fqdn
    SFTP_PARTNER_B_USERNAME    = "partner-b"
    SFTP_PARTNER_B_PRIVATE_KEY = format(local.key_vault_reference, "sftp-partner-b-private-key")
    NAS_ROOT_FOLDER            = "\\\\nas01.${local.corp_dns_zone_name}\\share"
    NAS_USERNAME               = "nas01\\svc-la"
    NAS_PASSWORD               = format(local.key_vault_reference, "nas-svc-la-password")
    AUTOMATION_SUBSCRIPTION_ID = var.subscription_id
    AUTOMATION_RESOURCE_GROUP  = azurerm_resource_group.main.name
    AUTOMATION_ACCOUNT_NAME    = azurerm_automation_account.main.name
    HYBRID_WORKER_GROUP        = azurerm_automation_hybrid_runbook_worker_group.files.name
  }
}
