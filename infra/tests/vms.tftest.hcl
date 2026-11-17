# The VM topology, secrets, protected setup commands, DNS and shutdown schedules.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000002"
    }
  }
}

mock_provider "random" {}

mock_provider "tls" {}

override_resource {
  target          = random_password.svc_la
  override_during = plan

  values = {
    result = "SvcLaPassword1234567890Abcdefgh"
  }
}

override_resource {
  target          = random_password.svc_azauto
  override_during = plan

  values = {
    result = "SvcAzAutoPassword1234567890Abc"
  }
}

override_resource {
  target          = random_password.partner_a
  override_during = plan

  values = {
    result = "PartnerPassword1234567890Abcdef"
  }
}

override_resource {
  target          = random_password.vm_admin
  override_during = plan

  values = {
    result = "VmAdminPassword1234567890Abcdef"
  }
}

override_resource {
  target          = tls_private_key.partner_b
  override_during = plan

  values = {
    private_key_openssh = "-----BEGIN OPENSSH PRIVATE KEY-----"
    public_key_openssh  = "ssh-rsa AAAATEST"
  }
}

override_resource {
  target          = tls_private_key.partner_admin
  override_during = plan

  values = {
    private_key_openssh = "-----BEGIN OPENSSH PRIVATE KEY-----"
    public_key_openssh  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCoLpoH2hLh0ycMGE7JNA4iennuhjRzFy+IWCT1T1voD491yHiF9NYHL52kvUP2vABoiQRdEGs2dzpQK3kG/jKWQtoM9Lknq1aX9XVSy/9CaNEAKGOvjXefXe2eTdQ5q37cm3lheXTTxXaVf3ECcSDxDS4NFKfhLqLU/PWs/AtUi7bZI3ZEU1WHAvs/LOBEE9g2B4JTyGvwaVSo0tp7RFKQsGuO9L+uD1W6BSIC8yusEILguK6AleAjRkzhPBRsTJeZCE7p4wQFGZMGld4pyil8PpVThbFHU3d+sIcDPnPCWQRwqOUAzcFVSxvYna0wz9GoE/6BOELliGS5+Yrt5A83 runner@runnervm8axu0"
  }
}

override_resource {
  target          = azurerm_public_ip.partner
  override_during = plan

  values = {
    id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-partner"
    ip_address = "198.51.100.10"
    fqdn       = "partner-test.example.invalid"
  }
}

override_resource {
  target          = azurerm_application_security_group.nas
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/applicationSecurityGroups/asg-nas"
  }
}

override_resource {
  target          = azurerm_application_security_group.worker
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/applicationSecurityGroups/asg-worker"
  }
}

override_resource {
  target          = azurerm_network_interface.nas
  override_during = plan

  values = {
    id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/networkInterfaces/nic-nas"
    private_ip_address = "10.20.1.10"
  }
}

override_resource {
  target          = azurerm_network_interface.worker
  override_during = plan

  values = {
    id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/networkInterfaces/nic-worker"
    private_ip_address = "10.20.1.11"
  }
}

override_resource {
  target          = azurerm_network_interface.partner
  override_during = plan

  values = {
    id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/networkInterfaces/nic-partner"
    private_ip_address = "10.30.1.10"
  }
}

override_resource {
  target          = module.network_spoke.azurerm_subnet.main
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
  }
}

override_resource {
  target          = module.network_onprem_sim.azurerm_subnet.main
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-onprem-sim/subnets/snet-servers"
  }
}

override_resource {
  target          = module.network_partner.azurerm_subnet.main
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-partner/subnets/snet-partner"
  }
}

override_resource {
  target          = module.key_vault.azurerm_key_vault.main
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.KeyVault/vaults/kv-test"
  }
}

variables {
  environment_name = "test"
  subscription_id  = "00000000-0000-0000-0000-000000000000"
  location         = "francecentral"
  tags             = ""
  deployer_ip      = "203.0.113.8"
}

run "default_worker_configuration" {
  command = plan

  assert {
    condition     = length(azurerm_windows_virtual_machine.worker) == 1 && contains(keys(azurerm_windows_virtual_machine.worker), "hw01")
    error_message = "The default configuration must create only the hw01 worker."
  }

  assert {
    condition     = azurerm_windows_virtual_machine.nas.size == var.vm_size && azurerm_windows_virtual_machine.worker["hw01"].size == var.vm_size && azurerm_linux_virtual_machine.partner.size == var.vm_size
    error_message = "Every VM must use the shared VM_SIZE setting."
  }

  assert {
    condition     = azurerm_network_interface.nas.ip_configuration[0].subnet_id == local.network.subnet_ids["servers"] && azurerm_network_interface.partner.ip_configuration[0].subnet_id == local.network.subnet_ids["partner"]
    error_message = "The NAS and partner NICs must use their designated subnets."
  }

  assert {
    condition     = azurerm_network_interface_application_security_group_association.nas.application_security_group_id == local.application_security_group_ids.nas && azurerm_network_interface_application_security_group_association.worker["hw01"].application_security_group_id == local.application_security_group_ids.worker
    error_message = "The NAS and worker NICs must join their matching application security groups."
  }

  assert {
    condition     = contains(azurerm_private_dns_a_record.nas.records, "10.20.1.10") && azurerm_private_dns_a_record.worker["hw01"].name == "hw01"
    error_message = "corp.local must resolve the NAS and each worker to its private address."
  }

  assert {
    condition     = azurerm_windows_virtual_machine.nas.computer_name == "nas01" && azurerm_private_dns_a_record.nas.name == "nas01" && output.NAS_SHARE_UNC == "\\\\nas01.corp.local\\share"
    error_message = "The NAS name, DNS record and share output must match the specified UNC path."
  }

  assert {
    condition     = azurerm_key_vault_secret.svc_azauto_password.name == "nas-svc-azauto-password" && nonsensitive(azurerm_key_vault_secret.svc_azauto_password.value) == nonsensitive(random_password.svc_azauto.result)
    error_message = "The svc-azauto password must be stored under the specified Key Vault secret name."
  }

  assert {
    condition     = tls_private_key.partner_b.algorithm == "RSA" && tls_private_key.partner_b.rsa_bits == 4096 && azurerm_key_vault_secret.partner_b_private_key.name == "sftp-partner-b-private-key"
    error_message = "The SFTP private key must be RSA 4096 and stored in Key Vault."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.partner.disable_password_authentication && one(azurerm_linux_virtual_machine.partner.admin_ssh_key).public_key == tls_private_key.partner_admin.public_key_openssh && azurerm_key_vault_secret.partner_admin_private_key.name == "partner-vm-admin-private-key"
    error_message = "The partner VM admin account must use its own SSH key, not password authentication or the SFTP key."
  }

  assert {
    condition     = strcontains(nonsensitive(jsondecode(azurerm_virtual_machine_extension.nas_setup.protected_settings).commandToExecute), nonsensitive(random_password.svc_azauto.result)) && strcontains(nonsensitive(jsondecode(azurerm_virtual_machine_extension.worker_setup["hw01"].protected_settings).commandToExecute), nonsensitive(random_password.svc_azauto.result))
    error_message = "The same svc-azauto password must reach both Windows setup scripts only through protected settings."
  }

  assert {
    condition     = strcontains(nonsensitive(jsondecode(azurerm_virtual_machine_extension.nas_setup.protected_settings).commandToExecute), "@('10.10.1.0/26','10.20.1.0/24')")
    error_message = "The NAS firewall setup must allow the Logic App and worker subnets."
  }

  assert {
    condition     = !strcontains(nonsensitive(azurerm_virtual_machine_extension.nas_setup.settings), nonsensitive(random_password.svc_azauto.result)) && !strcontains(nonsensitive(azurerm_virtual_machine_extension.worker_setup["hw01"].settings), nonsensitive(random_password.svc_azauto.result))
    error_message = "Windows setup passwords must not appear in the unprotected extension settings."
  }

  assert {
    condition     = azurerm_dev_test_global_vm_shutdown_schedule.nas.daily_recurrence_time == "2000" && azurerm_dev_test_global_vm_shutdown_schedule.nas.timezone == "Romance Standard Time" && azurerm_dev_test_global_vm_shutdown_schedule.worker["hw01"].enabled
    error_message = "Every default VM must have the 20:00 Romance Standard Time shutdown schedule."
  }

  assert {
    condition     = output.PARTNER_VM_NAME == azurerm_linux_virtual_machine.partner.name && output.PARTNER_VM_FQDN == "partner-test.example.invalid" && output.WORKER_VM_NAMES == azurerm_windows_virtual_machine.worker["hw01"].name
    error_message = "The VM names and partner FQDN must be exported as azd values."
  }
}

run "second_worker_enabled" {
  command = plan

  variables {
    enable_second_worker = true
    enable_ftps          = true
    auto_shutdown_time   = "2130"
  }

  assert {
    condition     = length(azurerm_windows_virtual_machine.worker) == 2 && contains(keys(azurerm_windows_virtual_machine.worker), "hw02")
    error_message = "ENABLE_SECOND_WORKER must add the hw02 worker."
  }

  assert {
    condition     = length(azurerm_private_dns_a_record.worker) == 2 && length(azurerm_dev_test_global_vm_shutdown_schedule.worker) == 2
    error_message = "The optional worker must also receive a DNS record and shutdown schedule."
  }

  assert {
    condition     = output.WORKER_VM_NAMES == "vm-test-hw01,vm-test-hw02" && azurerm_dev_test_global_vm_shutdown_schedule.partner.daily_recurrence_time == "2130"
    error_message = "The worker names must be stable and all VM schedules must use the configured time."
  }

  assert {
    condition     = strcontains(nonsensitive(jsondecode(azurerm_virtual_machine_extension.partner_setup.protected_settings).commandToExecute), "ENABLE_FTPS=true")
    error_message = "ENABLE_FTPS must be passed to the partner setup script."
  }
}
