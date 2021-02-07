terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 2.45.1"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "EESDevOps_IaC1_RG"
  location = "Brazil South"

  tags = {
    environment = "DEV"
    team        = "EESDevOps"
  }
}

resource "random_string" "rs" {
  length  = 6
  special = false
  upper   = false
  number  = false
}

resource "azurerm_public_ip" "pip" {
  name                = "pip-iac1"
  allocation_method   = "Static"
  domain_name_label   = random_string.rs.result
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-iac1"
  address_space       = ["10.0.0.0/16"]
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet" "snet" {
  name                 = "snet-iac1"
  address_prefixes     = ["10.0.1.0/24"]
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.rg.name
}

resource "azurerm_mysql_server" "mysql" {
  name                              = "mysql-iac1"
  version                           = "5.7"
  administrator_login               = "root"
  administrator_login_password      = "admin1234"
  create_mode                       = "Default"
  sku_name                          = "B_Gen5_2"
  storage_mb                        = 5120
  backup_retention_days             = 7
  geo_redundant_backup_enabled      = false
  infrastructure_encryption_enabled = false
  public_network_access_enabled     = true
  ssl_enforcement_enabled           = false
  resource_group_name               = azurerm_resource_group.rg.name
  location                          = azurerm_resource_group.rg.location
}

resource "azurerm_mysql_firewall_rule" "mysql_rule" {
  name                = "mysql-iac1-rule"
  start_ip_address    = azurerm_public_ip.pip.ip_address
  end_ip_address      = azurerm_public_ip.pip.ip_address
  server_name         = azurerm_mysql_server.mysql.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_mysql_database" "mysql_db" {
  name                = "mysql-iac1-db"
  charset             = "utf8"
  collation           = "utf8_unicode_ci"
  server_name         = azurerm_mysql_server.mysql.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_lb" "lb" {
  name                = "lb-iac1"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  frontend_ip_configuration {
    name                 = "fic-iac1"
    public_ip_address_id = azurerm_public_ip.pip.id
  }
}

resource "azurerm_lb_backend_address_pool" "lbap" {
  name            = "lbap-iac1"
  loadbalancer_id = azurerm_lb.lb.id
}

resource "azurerm_lb_probe" "lbp" {
  name                = "lbp-iac1"
  port                = 80
  loadbalancer_id     = azurerm_lb.lb.id
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_lb_rule" "lbr" {
  name                           = "http"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  backend_address_pool_id        = azurerm_lb_backend_address_pool.lbap.id
  frontend_ip_configuration_name = "fic-iac1"
  probe_id                       = azurerm_lb_probe.lbp.id
  loadbalancer_id                = azurerm_lb.lb.id
  resource_group_name            = azurerm_resource_group.rg.name
}

data "template_file" "tpl" {
  template = file("docker-wordpress-install.conf")
}

data "template_cloudinit_config" "config" {
  gzip          = true
  base64_encode = true
  depends_on    = [azurerm_mysql_server.mysql]

  part {
    filename     = "docker-wordpress-install.conf"
    content_type = "text/cloud-config"
    content      = data.template_file.tpl.rendered
  }
}

resource "azurerm_virtual_machine_scale_set" "vmss" {
  name                = "vmss-iac1"
  upgrade_policy_mode = "Manual"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku {
    name     = "Standard_F2"
    tier     = "Standard"
    capacity = 2
  }

  storage_profile_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  storage_profile_os_disk {
    name              = ""
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }

  storage_profile_data_disk {
    lun           = 0
    caching       = "ReadWrite"
    create_option = "Empty"
    disk_size_gb  = 10
  }

  os_profile {
    computer_name_prefix = "wpvm"
    admin_username       = "root"
    admin_password       = "admin1234"
    custom_data          = data.template_cloudinit_config.config.rendered
  }

  os_profile_linux_config {
    disable_password_authentication = true
  }

  network_profile {
    name    = "networkprofile"
    primary = true

    ip_configuration {
      name                                = "IPconfig"
      primary                             = true
      subnet_id                           = azurerm_subnet.snet.id
      load_balancer_inbound_nat_rules_ids = [azurerm_lb_backend_address_pool.lbap.id]
    }
  }
}
