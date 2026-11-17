# The networks of SPEC §3.1, planned with mock providers: two-way peering, NAT egress, corp.local, and NSGs that
# allow only the expected sources.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }

}

override_resource {
  target          = azurerm_public_ip.nat
  override_during = plan

  values = {
    id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-nat"
    ip_address = "198.51.100.10"
  }
}

override_resource {
  target          = module.network_spoke.azurerm_virtual_network.main
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
  }
}

override_resource {
  target          = module.network_onprem_sim.azurerm_virtual_network.main
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-onprem-sim"
  }
}

# Every subnet of a network gets the same mocked id: the provider only checks that it parses as a subnet id.
override_resource {
  target          = module.network_spoke.azurerm_subnet.main
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-logicapp-int"
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

variables {
  environment_name = "test"
  subscription_id  = "00000000-0000-0000-0000-000000000000"
  location         = "francecentral"
  tags             = ""
  deployer_ip      = "203.0.113.8"
}

run "network_plan" {
  command = plan

  assert {
    condition     = module.network_spoke.subnet_ids["snet-logicapp-int"] == local.network.subnet_ids["logicapp-integration"] && contains(keys(module.network_spoke.subnet_ids), "snet-pe")
    error_message = "The spoke must expose snet-logicapp-int as the logicapp-integration role, and snet-pe."
  }

  assert {
    condition     = azurerm_subnet_nat_gateway_association.logicapp.subnet_id == local.network.subnet_ids["logicapp-integration"]
    error_message = "The NAT Gateway must be attached to the Logic App integration subnet."
  }

  assert {
    condition     = azurerm_public_ip.nat.allocation_method == "Static" && azurerm_public_ip.nat.sku == "Standard"
    error_message = "The NAT Gateway must use a Standard static public IP."
  }

  assert {
    condition     = azurerm_private_dns_zone.corp.name == "corp.local" && azurerm_private_dns_zone_virtual_network_link.spoke.virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-spoke" && azurerm_private_dns_zone_virtual_network_link.onprem_sim.virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-onprem-sim"
    error_message = "corp.local must be linked to the spoke and the simulated datacenter."
  }

  assert {
    condition     = azurerm_virtual_network_peering.spoke_to_onprem_sim.remote_virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-onprem-sim" && azurerm_virtual_network_peering.onprem_sim_to_spoke.remote_virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
    error_message = "The spoke and the simulated datacenter must be peered in both directions."
  }

  assert {
    condition     = !contains(keys(module.network_onprem_sim.subnet_ids), "AzureBastionSubnet") && length(azurerm_network_security_rule.servers_bastion) == 0
    error_message = "enable_bastion=false must create no Bastion subnet and no Bastion rule."
  }

  assert {
    condition     = azurerm_network_security_rule.partner_allow_list.access == "Allow" && toset(azurerm_network_security_rule.partner_allow_list.destination_port_ranges) == toset(["2121", "2222", "40000-40100"])
    error_message = "The partner allow-list must cover TCP 21, 22 and 40000-40100."
  }

  assert {
    condition     = toset(azurerm_network_security_rule.partner_allow_list.source_address_prefixes) == toset(["198.51.100.10/32", "203.0.113.8/32"])
    error_message = "The partner VM must be reachable only from the NAT public IP and the deployer IP."
  }

  assert {
    condition     = azurerm_network_security_rule.partner_deny_all.access == "Deny" && azurerm_network_security_rule.partner_deny_all.source_address_prefix == "*" && azurerm_network_security_rule.partner_deny_all.priority > azurerm_network_security_rule.partner_allow_list.priority
    error_message = "Everything else must be denied on the partner subnet, after the allow-list."
  }

  assert {
    condition     = azurerm_network_security_rule.servers_smb_from_logicapp.source_address_prefix == "10.10.1.0/26" && azurerm_network_security_rule.servers_smb_from_logicapp.destination_port_range == "445"
    error_message = "SMB to the NAS must be allowed only from the Logic App integration subnet."
  }

  assert {
    condition     = azurerm_network_security_rule.servers_deny_virtual_network.access == "Deny" && azurerm_network_security_rule.servers_deny_virtual_network.source_address_prefix == "VirtualNetwork"
    error_message = "Other inbound traffic from the virtual networks must be denied on the servers subnet."
  }
}

run "bastion_enabled" {
  command = plan

  variables {
    enable_bastion = true
  }

  assert {
    condition     = contains(keys(module.network_onprem_sim.subnet_ids), "AzureBastionSubnet")
    error_message = "enable_bastion=true must create the AzureBastionSubnet."
  }

  assert {
    condition     = azurerm_network_security_rule.servers_bastion[0].source_address_prefix == "10.20.255.0/26"
    error_message = "Management access to the servers must come only from the Bastion subnet."
  }
}

run "invalid_deployer_ip_rejected" {
  command = plan

  variables {
    deployer_ip = "203.0.113.0/24"
  }

  expect_failures = [var.deployer_ip]
}
