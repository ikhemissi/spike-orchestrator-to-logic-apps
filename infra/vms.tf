# Simulated NAS, Automation workers and partner endpoints (SPEC sections 3.2 and 3.5).

variable "vm_size" {
  description = "Size for every VM (VM_SIZE)."
  type        = string
  default     = "Standard_D2als_v7"
}

variable "enable_second_worker" {
  description = "Create the optional second Hybrid Runbook Worker (ENABLE_SECOND_WORKER)."
  type        = bool
  default     = false
}

variable "enable_ftps" {
  description = "Enable optional FTPS on the partner VM (ENABLE_FTPS)."
  type        = bool
  default     = false
}

variable "auto_shutdown_time" {
  description = "Daily auto-shutdown time in HHMM 24-hour format (AUTO_SHUTDOWN_TIME)."
  type        = string
  default     = "2000"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "auto_shutdown_time must be a valid HHMM time."
  }
}

variable "vm_script_source_ref" {
  description = "Git ref used to download the VM setup scripts (VM_SCRIPT_SOURCE_REF)."
  type        = string
  default     = "main"

  validation {
    condition     = length(trimspace(var.vm_script_source_ref)) > 0
    error_message = "vm_script_source_ref must not be empty."
  }
}

locals {
  worker_names = var.enable_second_worker ? toset(["hw01", "hw02"]) : toset(["hw01"])
  vm_admin_names = setunion(
    toset(["nas01"]),
    local.worker_names,
  )

  # VERIFY: the VM extensions need public access to these versioned repository files.
  vm_scripts_base_url = "https://raw.githubusercontent.com/ikhemissi/spike-orchestrator-to-logic-apps/${var.vm_script_source_ref}/infra/scripts/vm"
}

resource "random_password" "svc_la" {
  length      = 32
  min_lower   = 1
  min_numeric = 1
  min_upper   = 1
  special     = false
}

resource "random_password" "svc_azauto" {
  length      = 32
  min_lower   = 1
  min_numeric = 1
  min_upper   = 1
  special     = false
}

resource "random_password" "partner_a" {
  length      = 32
  min_lower   = 1
  min_numeric = 1
  min_upper   = 1
  special     = false
}

resource "random_password" "vm_admin" {
  for_each    = local.vm_admin_names
  length      = 32
  min_lower   = 1
  min_numeric = 1
  min_upper   = 1
  special     = false
}

resource "tls_private_key" "partner_b" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_private_key" "partner_admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_key_vault_secret" "svc_la_password" {
  name         = "nas-svc-la-password"
  key_vault_id = module.key_vault.id
  value        = random_password.svc_la.result
}

resource "azurerm_key_vault_secret" "svc_azauto_password" {
  name         = "nas-svc-azauto-password"
  key_vault_id = module.key_vault.id
  value        = random_password.svc_azauto.result
}

resource "azurerm_key_vault_secret" "partner_a_password" {
  name         = "ftp-partner-a-password"
  key_vault_id = module.key_vault.id
  value        = random_password.partner_a.result
}

resource "azurerm_key_vault_secret" "partner_b_private_key" {
  name         = "sftp-partner-b-private-key"
  key_vault_id = module.key_vault.id
  value        = tls_private_key.partner_b.private_key_openssh
}

resource "azurerm_key_vault_secret" "partner_admin_private_key" {
  name         = "partner-vm-admin-private-key"
  key_vault_id = module.key_vault.id
  value        = tls_private_key.partner_admin.private_key_openssh
}

resource "azurerm_key_vault_secret" "vm_admin_password" {
  for_each     = random_password.vm_admin
  name         = "${each.key}-vm-admin-password"
  key_vault_id = module.key_vault.id
  value        = each.value.result
}

resource "azurerm_network_interface" "nas" {
  name                = "nic-${var.environment_name}-nas01"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.network.subnet_ids["servers"]
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "worker" {
  for_each            = local.worker_names
  name                = "nic-${var.environment_name}-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.network.subnet_ids["servers"]
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "partner" {
  name                = "nic-${var.environment_name}-partner01"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.network.subnet_ids["partner"]
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.partner.id
  }
}

resource "azurerm_network_interface_application_security_group_association" "nas" {
  network_interface_id          = azurerm_network_interface.nas.id
  application_security_group_id = local.application_security_group_ids.nas
}

resource "azurerm_network_interface_application_security_group_association" "worker" {
  for_each                      = local.worker_names
  network_interface_id          = azurerm_network_interface.worker[each.key].id
  application_security_group_id = local.application_security_group_ids.worker
}

resource "azurerm_windows_virtual_machine" "nas" {
  name                = "vm-${var.environment_name}-nas01"
  computer_name       = "nas01"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  size                = var.vm_size
  admin_username      = "spikeadmin"
  admin_password      = random_password.vm_admin["nas01"].result
  network_interface_ids = [
    azurerm_network_interface.nas.id,
  ]
  tags = local.network_tags

  # VERIFY: confirm the Windows Server 2022 image SKU in the target Azure region.
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
}

resource "azurerm_windows_virtual_machine" "worker" {
  for_each = local.worker_names

  name                  = "vm-${var.environment_name}-${each.key}"
  computer_name         = each.key
  resource_group_name   = azurerm_resource_group.main.name
  location              = var.location
  size                  = var.vm_size
  admin_username        = "spikeadmin"
  admin_password        = random_password.vm_admin[each.key].result
  network_interface_ids = [azurerm_network_interface.worker[each.key].id]
  tags                  = local.network_tags

  # VERIFY: confirm the Windows Server 2022 image SKU in the target Azure region.
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
}

resource "azurerm_public_ip" "partner" {
  name                = "pip-${var.environment_name}-partner01"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "partner-${local.compact_name}-${local.token}"
  tags                = local.network_tags
}

resource "azurerm_linux_virtual_machine" "partner" {
  name                            = "vm-${var.environment_name}-partner01"
  computer_name                   = "partner01"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = "spikeadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.partner.id]
  tags                            = local.network_tags

  admin_ssh_key {
    username   = "spikeadmin"
    public_key = tls_private_key.partner_admin.public_key_openssh
  }

  # VERIFY: confirm the Ubuntu 22.04 image SKU in the target Azure region.
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
}

# VERIFY: confirm the current Custom Script Extension handler contracts before provisioning.
resource "azurerm_virtual_machine_extension" "nas_setup" {
  name                       = "CustomScriptExtension"
  virtual_machine_id         = azurerm_windows_virtual_machine.nas.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  settings = jsonencode({
    fileUris = ["${local.vm_scripts_base_url}/setup-nas.ps1"]
  })
  protected_settings = jsonencode({
    commandToExecute = "powershell.exe -ExecutionPolicy Bypass -Command \"& '.\\setup-nas.ps1' -SvcLaPassword ${random_password.svc_la.result} -SvcAzAutoPassword ${random_password.svc_azauto.result} -SmbRemoteAddresses @('10.10.1.0/26','10.20.1.0/24')\""
  })
}

resource "azurerm_virtual_machine_extension" "worker_setup" {
  for_each = local.worker_names

  name                       = "CustomScriptExtension"
  virtual_machine_id         = azurerm_windows_virtual_machine.worker[each.key].id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  settings = jsonencode({
    fileUris = [
      "${local.vm_scripts_base_url}/setup-worker.ps1",
      "${local.vm_scripts_base_url}/tools/Convert-Extract.ps1",
    ]
  })
  protected_settings = jsonencode({
    commandToExecute = "powershell.exe -ExecutionPolicy Bypass -File setup-worker.ps1 -SvcAzAutoPassword ${random_password.svc_azauto.result} -ToolSourcePath .\\Convert-Extract.ps1"
  })
}

resource "azurerm_virtual_machine_extension" "partner_setup" {
  name                       = "CustomScript"
  virtual_machine_id         = azurerm_linux_virtual_machine.partner.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true
  settings = jsonencode({
    fileUris = ["${local.vm_scripts_base_url}/setup-partner.sh"]
  })
  protected_settings = jsonencode({
    commandToExecute = "PASV_ADDRESS=${azurerm_public_ip.partner.ip_address} PARTNER_A_PASSWORD=${random_password.partner_a.result} PARTNER_B_PUBLIC_KEY='${trimspace(tls_private_key.partner_b.public_key_openssh)}' ENABLE_FTPS=${var.enable_ftps} bash setup-partner.sh"
  })
}

resource "azurerm_private_dns_a_record" "nas" {
  name                = "nas01"
  zone_name           = azurerm_private_dns_zone.corp.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_network_interface.nas.private_ip_address]
}

resource "azurerm_private_dns_a_record" "worker" {
  for_each            = local.worker_names
  name                = each.key
  zone_name           = azurerm_private_dns_zone.corp.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_network_interface.worker[each.key].private_ip_address]
}

# VERIFY: confirm shutdown schedule API fields and Windows time-zone identifier before provisioning.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "nas" {
  virtual_machine_id    = azurerm_windows_virtual_machine.nas.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = "Romance Standard Time"

  notification_settings {
    enabled = false
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "worker" {
  for_each = local.worker_names

  virtual_machine_id    = azurerm_windows_virtual_machine.worker[each.key].id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = "Romance Standard Time"

  notification_settings {
    enabled = false
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "partner" {
  virtual_machine_id    = azurerm_linux_virtual_machine.partner.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = "Romance Standard Time"

  notification_settings {
    enabled = false
  }
}

output "PARTNER_VM_NAME" {
  value = azurerm_linux_virtual_machine.partner.name
}

output "PARTNER_VM_FQDN" {
  value = azurerm_public_ip.partner.fqdn
}

output "NAS_VM_NAME" {
  value = azurerm_windows_virtual_machine.nas.name
}

output "NAS_SHARE_UNC" {
  value = "\\\\nas01.corp.local\\share"
}

output "WORKER_VM_NAMES" {
  value = join(",", [
    for worker_name in sort(tolist(local.worker_names)) :
    azurerm_windows_virtual_machine.worker[worker_name].name
  ])
}
