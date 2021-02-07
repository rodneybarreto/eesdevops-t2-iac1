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

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-iac1"
  address_space       = ["10.0.0.0/16"]
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet" "snet" {
  name                 = "snet-iac1"
  address_prefixes     = ["10.0.2.0/24"]
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.rg.name
}

resource "azurerm_public_ip" "pip" {
  name                    = "pip-iac1"
  allocation_method       = "Dynamic"
  idle_timeout_in_minutes = 30
  resource_group_name     = azurerm_resource_group.rg.name
  location                = azurerm_resource_group.rg.location
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
  name                = "lbap-iac1"
  loadbalancer_id     = azurerm_lb.lb.id
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_lb_probe" "lbp" {
  name                = "lbp-iac1"
  port                = 80
  protocol            = "Http"
  request_path        = "/wordpressuser/images/wordpress-logo.svg"
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

resource "azurerm_virtual_machine_scale_set" "vmss" {
  name                = "vmss-iac1"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  upgrade_policy_mode = "Manual"

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
    admin_username       = "wordpressuser"
    custom_data          = file("web.conf")
  }

  os_profile_linux_config {
    disable_password_authentication = true

    ssh_keys {
      path     = "/home/wordpressuser/.ssh/authorizad_keys"
      key_data = file("~/.ssh/id_rsa.pub")
    }
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

  tags = {
    "environment" = "DEV"
  }
}

resource "azurerm_monitor_autoscale_setting" "mas" {
  name                = "mas-iac1"
  target_resource_id  = azurerm_virtual_machine_scale_set.vmss.id
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  profile {
    name = "profile1"

    capacity {
      default = 2
      minimum = 2
      maximum = 3
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThen"
        threshold          = 50
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = 1
        cooldown  = "PT1M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "LessThen"
        threshold          = 25
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = 1
        cooldown  = "PT1M"
      }
    }
  }

  notification {
    email {
      send_to_subscription_administrator    = true
      send_to_subscription_co_administrator = true
      custom_emails                         = ["rwbarreto@gmail.com"]
    }
  }
}

resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-iac1"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  security_rule {
    name                       = "SSH"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    source_address_prefix      = "*"
    destination_port_range     = "22"
    destination_address_prefix = "*"
  }

  tags = {
    "environment" = "DEV"
  }
}

resource "azurerm_public_ip" "pip_mysql" {
  name                    = "pip-iac1-mysql"
  allocation_method       = "Dynamic"
  idle_timeout_in_minutes = 30
  resource_group_name     = azurerm_resource_group.rg.name
  location                = azurerm_resource_group.rg.location

  tags = {
    environment = "DEV"
  }
}

resource "azurerm_network_interface" "nic_mysql" {
  name                = "nic-iac1-mysql"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  ip_configuration {
    name                          = "internal"
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost("10.0.2.4/24", 4)
    subnet_id                     = azurerm_subnet.snet.id
    public_ip_address_id          = azurerm_public_ip.pip_mysql.id
  }
}

resource "azurerm_network_interface_security_group_association" "nicsga" {
  network_interface_id      = azurerm_network_interface.nic_mysql.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_linux_virtual_machine" "vm_mysql" {
  name                  = "vm-mysql-iac1"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = "Standard_B2s"
  admin_username        = "adminuser"
  network_interface_ids = [azurerm_network_interface.nic_mysql.id]

  admin_ssh_key {
    username   = "adminuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
}

data "azurerm_public_ip" "pip" {
  name                = azurerm_public_ip.pip.name
  resource_group_name = azurerm_resource_group.rg.name
  depends_on          = [azurerm_virtual_machine_scale_set.vmss]
}

output "public_ip_address" {
  value = data.azurerm_public_ip.pip.ip_address
}

data "azurerm_public_ip" "pip_mysql" {
  name                = azurerm_public_ip.pip_mysql.name
  resource_group_name = azurerm_resource_group.rg.name
  depends_on          = [azurerm_linux_virtual_machine.vm_mysql]
}

output "public_ip_address_mysql" {
  value = data.azurerm_public_ip.pip_mysql.ip_address
}

resource "null_resource" "mysql_install" {
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get --yes --force-yes install docker.io",
      "sudo docker run -p 3306:3306 --name wordpress-mysql --restart always -e MYSQL_ROOT_PASSWORD=jhjggykjhd85d83h -e MYSQL_DATABASE=wordpress -e MYSQL_USER=usr-wordpress -e MYSQL_PASSWORD=jhjggykjhd85d83h -d mysql:5.7",
    ]

    connection {
      host        = data.azurerm_public_ip.pip_mysql.ip_address
      user        = "adminuser"
      type        = "ssh"
      private_key = file("~/.ssh/id_rsa.insecure")
      timeout     = "1m"
      agent       = false
    }
  }
}
