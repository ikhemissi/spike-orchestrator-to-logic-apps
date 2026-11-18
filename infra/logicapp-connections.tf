# The settings behind the workflows' connections (src/logicapp/connections.json) and parameters
# (src/logicapp/parameters.json): hosts, accounts and secrets, as app settings. Secrets are Key Vault references,
# resolved with the Logic App's identity; Terraform writes the secrets with the VMs that use them (vms.tf).

locals {
  key_vault_reference = "@Microsoft.KeyVault(VaultName=${module.key_vault.name};SecretName=%s)"

  logicapp_connection_settings = {
    FTP_PARTNER_A_HOST         = azurerm_public_ip.partner.fqdn
    FTP_PARTNER_A_PORT         = tostring(var.partner_ftp_port)
    FTP_PARTNER_A_USERNAME     = "partner-a"
    FTP_PARTNER_A_PASSWORD     = format(local.key_vault_reference, "ftp-partner-a-password")
    SFTP_PARTNER_B_HOST        = azurerm_public_ip.partner.fqdn
    SFTP_PARTNER_B_PORT        = tostring(var.partner_sftp_port)
    SFTP_PARTNER_B_USERNAME    = "partner-b"
    SFTP_PARTNER_B_PRIVATE_KEY = format(local.key_vault_reference, "sftp-partner-b-private-key")
    NAS_MOUNT_PATH             = local.nas_mount_path
    NAS_USERNAME               = "nas01\\svc-la"
    NAS_PASSWORD               = format(local.key_vault_reference, "nas-svc-la-password")
    AUTOMATION_SUBSCRIPTION_ID = var.subscription_id
    AUTOMATION_RESOURCE_GROUP  = azurerm_resource_group.main.name
    AUTOMATION_ACCOUNT_NAME    = azurerm_automation_account.main.name
    HYBRID_WORKER_GROUP        = azurerm_automation_hybrid_runbook_worker_group.files.name
  }
}

# The built-in File System connector reads the NAS through a file-share mount of the app (SMB, under C:\mounts), not
# from the connection itself: the connection only names the mount path. The designer creates both when a connection is
# made by hand; deployed from files, the mount is declared here. Its password comes from the Key Vault-backed setting.
locals {
  nas_mount_name = "nas-share"
  nas_mount_path = "C:\\mounts\\${local.nas_mount_name}"
}

# A PUT action: this configuration cannot be read back with GET (only listed), so it is not a managed resource.
resource "azapi_resource_action" "logicapp_nas_mount" {
  type        = "Microsoft.Web/sites/config@2024-04-01"
  resource_id = "${azurerm_logic_app_standard.main.id}/config/azureStorageAccounts"
  method      = "PUT"

  body = {
    properties = {
      (local.nas_mount_name) = {
        type        = "FileShare"
        protocol    = "Smb"
        endpoint    = "nas01.${local.corp_dns_zone_name}"
        shareName   = "share"
        accountName = "nas01\\svc-la"
        accessKey   = "@AppSettingRef(NAS_PASSWORD)"
        mountPath   = "\\mounts\\${local.nas_mount_name}"
      }
    }
  }
}
