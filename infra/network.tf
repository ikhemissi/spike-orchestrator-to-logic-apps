# The networks of SPEC §3.1: the spoke (Logic App integration with NAT Gateway egress, private endpoints), the
# simulated datacenter peered to it (the VPN/ExpressRoute stand-in), the unpeered partner network reached over the
# Internet, the corp.local private DNS zone and the NSGs. The network module is not in this repository yet, so the
# resources are declared here.
# Module calls read their subnet from local.network and their private endpoint from local.private_endpoint:
#   local.network.subnet_ids: subnet ids by role ("container-apps", "private-endpoints", "servers", "partner");
#   local.private_endpoint: { subnet_id = <the private-endpoints subnet id>, private_dns_zone_ids = <the zones by name> }.
# Keep local.private_endpoint null or an object built from known values: whether it is null decides at plan time
# whether the private endpoints exist. It stays null until the privatelink zones are added.

variable "deployer_ip" {
  description = "Public IPv4 address of the deployer (DEPLOYER_IP), without a CIDR suffix; allowed on the partner VM."
  type        = string

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.deployer_ip)) && can(cidrhost("${var.deployer_ip}/32", 0))
    error_message = "deployer_ip must be an IPv4 address without a CIDR suffix."
  }
}

variable "enable_bastion" {
  description = "Create the AzureBastionSubnet in the simulated datacenter (ENABLE_BASTION, \"true\" or \"false\")."
  # azd passes "true"/"false" strings; Terraform converts them to bool.
  type    = bool
  default = false
}

locals {
  network_tags       = merge(local.tags, { workload = "orchestrator-to-logic-apps" })
  corp_dns_zone_name = "corp.local"

  spoke_logicapp_prefix = "10.10.1.0/26"
  bastion_prefix        = "10.20.255.0/26"

  network = {
    subnet_ids = {
      "container-apps"    = azurerm_subnet.logicapp_int.id
      "private-endpoints" = azurerm_subnet.private_endpoints.id
      "servers"           = azurerm_subnet.servers.id
      "partner"           = azurerm_subnet.partner.id
    }
  }
  private_endpoint = null

  # The VM NICs join these groups (vms.tf), so the SMB rules target nas01 and hw01 rather than the whole subnet.
  application_security_group_ids = {
    nas    = azurerm_application_security_group.nas.id
    worker = azurerm_application_security_group.worker.id
  }

  partner_allowed_sources = ["${azurerm_public_ip.nat.ip_address}/32", "${var.deployer_ip}/32"]
}

resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${var.environment_name}-spoke"
  address_space       = ["10.10.0.0/16"]
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags
}

resource "azurerm_virtual_network" "onprem_sim" {
  name                = "vnet-${var.environment_name}-onprem-sim"
  address_space       = ["10.20.0.0/16"]
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags
}

resource "azurerm_virtual_network" "partner" {
  name                = "vnet-${var.environment_name}-partner"
  address_space       = ["10.30.0.0/16"]
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags
}

resource "azurerm_subnet" "logicapp_int" {
  name                 = "snet-logicapp-int"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.spoke_logicapp_prefix]

  delegation {
    name = "logic-apps"

    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = ["10.10.2.0/27"]
}

resource "azurerm_subnet" "servers" {
  name                 = "snet-servers"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.onprem_sim.name
  address_prefixes     = ["10.20.1.0/24"]
}

resource "azurerm_subnet" "bastion" {
  count                = var.enable_bastion ? 1 : 0
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.onprem_sim.name
  address_prefixes     = [local.bastion_prefix]
}

resource "azurerm_subnet" "partner" {
  name                 = "snet-partner"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.partner.name
  address_prefixes     = ["10.30.1.0/24"]
}

resource "azurerm_virtual_network_peering" "spoke_to_onprem_sim" {
  name                      = "peer-spoke-to-onprem-sim"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = azurerm_virtual_network.onprem_sim.id
}

resource "azurerm_virtual_network_peering" "onprem_sim_to_spoke" {
  name                      = "peer-onprem-sim-to-spoke"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.onprem_sim.name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id
}

resource "azurerm_public_ip" "nat" {
  name                = "pip-${var.environment_name}-nat"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.network_tags
}

resource "azurerm_nat_gateway" "logicapp" {
  name                = "ng-${var.environment_name}-logicapp"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
  tags                = local.network_tags
}

resource "azurerm_nat_gateway_public_ip_association" "logicapp" {
  nat_gateway_id       = azurerm_nat_gateway.logicapp.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "logicapp" {
  subnet_id      = azurerm_subnet.logicapp_int.id
  nat_gateway_id = azurerm_nat_gateway.logicapp.id
}

resource "azurerm_private_dns_zone" "corp" {
  name                = local.corp_dns_zone_name
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  name                  = "link-spoke"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.corp.name
  virtual_network_id    = azurerm_virtual_network.spoke.id
  registration_enabled  = false
  tags                  = local.network_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "onprem_sim" {
  name                  = "link-onprem-sim"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.corp.name
  virtual_network_id    = azurerm_virtual_network.onprem_sim.id
  registration_enabled  = false
  tags                  = local.network_tags
}

resource "azurerm_network_security_group" "servers" {
  name                = "nsg-${var.environment_name}-servers"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags
}

resource "azurerm_network_security_group" "partner" {
  name                = "nsg-${var.environment_name}-partner"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags
}

resource "azurerm_application_security_group" "nas" {
  name                = "asg-${var.environment_name}-nas"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags
}

resource "azurerm_application_security_group" "worker" {
  name                = "asg-${var.environment_name}-worker"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.network_tags
}

resource "azurerm_network_security_rule" "servers_bastion" {
  count                       = var.enable_bastion ? 1 : 0
  name                        = "Allow-Bastion-Management"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["22", "3389"]
  source_address_prefix       = local.bastion_prefix
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.servers.name
}

resource "azurerm_network_security_rule" "servers_smb_from_logicapp" {
  name                                       = "Allow-SMB-From-LogicApp"
  priority                                   = 110
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "445"
  source_address_prefix                      = local.spoke_logicapp_prefix
  destination_application_security_group_ids = [azurerm_application_security_group.nas.id]
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.servers.name
}

resource "azurerm_network_security_rule" "servers_smb_from_worker" {
  name                                       = "Allow-SMB-From-Worker-To-NAS"
  priority                                   = 120
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "445"
  source_application_security_group_ids      = [azurerm_application_security_group.worker.id]
  destination_application_security_group_ids = [azurerm_application_security_group.nas.id]
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.servers.name
}

resource "azurerm_network_security_rule" "servers_deny_virtual_network" {
  name                        = "Deny-Other-VirtualNetwork-Inbound"
  priority                    = 4090
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.servers.name
}

resource "azurerm_network_security_rule" "servers_automation_https" {
  name                        = "Allow-Automation-HTTPS-Outbound"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.servers.name
}

# The partner IP allow-list (SPEC §3.1, test T04): FTP, FTP passive and SFTP only from the NAT Gateway IP (the Logic
# App's egress) and the deployer; everything else is denied, VirtualNetwork included.
resource "azurerm_network_security_rule" "partner_allow_list" {
  name                        = "Allow-FTP-SFTP-From-NAT-And-Deployer"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["21", "22", "40000-40100"]
  source_address_prefixes     = local.partner_allowed_sources
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.partner.name
}

resource "azurerm_network_security_rule" "partner_deny_all" {
  name                        = "Deny-All-Inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.partner.name
}

resource "azurerm_subnet_network_security_group_association" "servers" {
  subnet_id                 = azurerm_subnet.servers.id
  network_security_group_id = azurerm_network_security_group.servers.id
}

resource "azurerm_subnet_network_security_group_association" "partner" {
  subnet_id                 = azurerm_subnet.partner.id
  network_security_group_id = azurerm_network_security_group.partner.id
}

output "NAT_PUBLIC_IP" {
  value = azurerm_public_ip.nat.ip_address
}

output "PARTNER_NSG_NAME" {
  value = azurerm_network_security_group.partner.name
}

output "SERVERS_NSG_NAME" {
  value = azurerm_network_security_group.servers.name
}
