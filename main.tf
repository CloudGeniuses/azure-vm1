############################################
# Terraform Cloud backend (remote state)
############################################
terraform {
  cloud {
    organization = "cloudgenius"   # <-- your TFC org
    workspaces {
      name = "azure-vm1"           # <-- your TFC workspace
    }
  }

  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.115"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

############################################
# Provider
############################################
provider "azurerm" {
  features {}
}

############################################
# Variables (safe defaults + comments)
############################################
variable "resource_group_name" {
  description = "Resource Group name."
  type        = string
  default     = "RG-NSG-Lab"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "canadacentral"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "vm1"
}

variable "vm_name" {
  description = "VM name (kept as VM1 to match your export)."
  type        = string
  default     = "VM1"
}

variable "vm_size" {
  description = "VM size."
  type        = string
  default     = "Standard_D4s_v3"
}

variable "admin_username" {
  description = "Local admin username."
  type        = string
  default     = "azureuser"
}

variable "admin_password" {
  description = "Local admin password (set as Sensitive in TFC)."
  type        = string
  sensitive   = true
}

variable "vnet_cidr" {
  description = "VNet CIDR."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR."
  type        = string
  default     = "10.10.1.0/24"
}

variable "allow_rdp_cidr" {
  description = "CIDR allowed to reach RDP/3389. Leave empty to disable inbound RDP."
  type        = string
  default     = ""
}

variable "create_public_ip" {
  description = "Whether to create a Public IP on the NIC (false is safer)."
  type        = bool
  default     = false
}

variable "extra_tags" {
  description = "Extra tags applied to resources."
  type        = map(string)
  default = {
    environment = "lab"
    owner       = "cloudgenius"
    workload    = "nsg-lab"
  }
}

############################################
# Locals (centralized names)
############################################
locals {
  rg_name     = var.resource_group_name
  vnet_name   = "vnet-${var.name_prefix}"
  subnet_name = "snet-${var.name_prefix}"
  nsg_name    = "nsg-${var.name_prefix}"
  pip_name    = "pip-${var.name_prefix}"
  nic_name    = "${var.vm_name}-nic"
  os_disk     = "${var.vm_name}_OsDisk"
  enable_rdp  = length(trimspace(var.allow_rdp_cidr)) > 0
}

############################################
# Resource group
############################################
resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = var.location
  tags     = var.extra_tags
}

############################################
# Networking: NSG, VNet/Subnet, NIC, optional PIP
############################################
resource "azurerm_network_security_group" "nsg" {
  name                = local.nsg_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Create inbound RDP only if allow_rdp_cidr is provided.
  dynamic "security_rule" {
    for_each = local.enable_rdp ? [1] : []
    content {
      name                       = "RDP-3389-Inbound"
      priority                   = 1000
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefix      = var.allow_rdp_cidr
      destination_address_prefix = "*"
    }
  }

  tags = var.extra_tags
}

resource "azurerm_virtual_network" "vnet" {
  name                = local.vnet_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_cidr]
  tags                = var.extra_tags
}

resource "azurerm_subnet" "subnet" {
  name                 = local.subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_subnet_network_security_group_association" "subnet_nsg" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_public_ip" "pip" {
  count               = var.create_public_ip ? 1 : 0
  name                = local.pip_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.extra_tags
}

resource "azurerm_network_interface" "nic" {
  name                = local.nic_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.extra_tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.create_public_ip ? azurerm_public_ip.pip[0].id : null
  }
}

############################################
# Compute: Windows Server 2022 VM
############################################
resource "azurerm_windows_virtual_machine" "vm" {
  name                = var.vm_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  network_interface_ids = [azurerm_network_interface.nic.id]

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter"
    version   = "latest"
  }

  os_disk {
    name                 = local.os_disk
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 127
  }

  provision_vm_agent       = true
  enable_automatic_updates = true
  patch_mode               = "AutomaticByOS"
  boot_diagnostics {}

  tags = var.extra_tags
}

############################################
# Outputs
############################################
output "vm_id" {
  value       = azurerm_windows_virtual_machine.vm.id
  description = "VM resource ID."
}

output "vm_private_ip" {
  value       = azurerm_network_interface.nic.ip_configuration[0].private_ip_address
  description = "VM private IP."
}

output "vm_public_ip" {
  value       = try(azurerm_public_ip.pip[0].ip_address, null)
  description = "VM public IP (if created)."
}
