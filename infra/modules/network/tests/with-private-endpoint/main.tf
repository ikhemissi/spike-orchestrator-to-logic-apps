# A project's network and a module with a private endpoint in the same plan, as infra/network.tf wires them once a
# project uses a virtual network: the subnet's id is not known yet, and the plan must still succeed.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
  }
}

module "network" {
  source              = "../.."
  name                = "vnet-test"
  resource_group_name = "rg-test"
  location            = "francecentral"
  address_space       = "10.0.0.0/16"
  subnets = {
    private-endpoints = { address_prefix = "10.0.2.0/24" }
  }
  private_dns_zones = ["privatelink.vaultcore.azure.net"]
}

module "key_vault" {
  source              = "../../../key-vault"
  name                = "kv-test"
  resource_group_name = "rg-test"
  location            = "francecentral"
  private_endpoint = {
    subnet_id            = module.network.subnet_ids["private-endpoints"]
    private_dns_zone_ids = module.network.private_dns_zone_ids
  }
}

