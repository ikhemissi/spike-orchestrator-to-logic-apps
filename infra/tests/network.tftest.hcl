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
  target          = azurerm_subnet.logicapp_int
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-logicapp-int"
  }
}

override_resource {
  target          = azurerm_virtual_network.spoke
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
  }
}

override_resource {
  target          = azurerm_virtual_network.onprem_sim
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-onprem-sim"
  }
}

override_resource {
  target          = azurerm_subnet.servers
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-onprem-sim/subnets/snet-servers"
  }
}

override_resource {
  target          = azurerm_subnet.partner
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
    condition     = azurerm_subnet.logicapp_int.delegation[0].service_delegation[0].name == "Microsoft.Web/serverFarms"
    error_message = "The Logic App integration subnet must use the App Service delegation."
  }

  assert {
    condition     = azurerm_nat_gateway.logicapp.name == "nat-logicapp" && azurerm_subnet_nat_gateway_association.logicapp.subnet_id == azurerm_subnet.logicapp_int.id
    error_message = "A NAT Gateway must be planned and attached to the Logic App integration subnet."
  }

  assert {
    condition     = azurerm_public_ip.nat.allocation_method == "Static" && azurerm_public_ip.nat.sku == "Standard" && azurerm_public_ip.nat.ip_address == "198.51.100.10"
    error_message = "The NAT Gateway must use a Standard static public IP."
  }

  assert {
    condition     = azurerm_private_dns_zone.corp.name == "corp.local" && azurerm_private_dns_zone_virtual_network_link.spoke.virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-spoke" && azurerm_private_dns_zone_virtual_network_link.onprem_sim.virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-onprem-sim"
    error_message = "corp.local must be linked to both the spoke and simulated on-premises VNets."
  }

  assert {
    condition     = azurerm_virtual_network_peering.spoke_to_onprem_sim.remote_virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-onprem-sim" && azurerm_virtual_network_peering.onprem_sim_to_spoke.remote_virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
    error_message = "The spoke and simulated on-premises VNets must be peered in both directions."
  }

  assert {
    condition     = length(azurerm_subnet.bastion) == 0
    error_message = "The Bastion subnet must not be created by default."
  }

  assert {
    condition     = azurerm_network_security_rule.partner_ftp.protocol == "Tcp" && azurerm_network_security_rule.partner_ftp.destination_port_range == "21" && azurerm_network_security_rule.partner_ftp.source_address_prefix == "Internet"
    error_message = "Partner FTP control traffic must allow TCP 21 from the Internet."
  }

  assert {
    condition     = azurerm_network_security_rule.partner_ftp_passive.protocol == "Tcp" && azurerm_network_security_rule.partner_ftp_passive.destination_port_range == "40000-40100" && azurerm_network_security_rule.partner_ftp_passive.source_address_prefix == "Internet"
    error_message = "Partner FTP passive traffic must allow TCP 40000-40100 from the Internet."
  }

  assert {
    condition     = azurerm_network_security_rule.partner_ssh.protocol == "Tcp" && azurerm_network_security_rule.partner_ssh.destination_port_range == "22" && toset(azurerm_network_security_rule.partner_ssh.source_address_prefixes) == toset(["198.51.100.10/32", "203.0.113.8/32"])
    error_message = "Partner SSH must allow only the NAT public IP and deployer IP."
  }
}
