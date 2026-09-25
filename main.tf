terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# ---------------------------------------------------------------------------
# Netværk
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.prefix}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "pip" {
  name                = "${var.prefix}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ---------------------------------------------------------------------------
# Network Security Group - åbner kun de porte LAMP-stacken skal bruges til
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_source_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTPS"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Grafana - kun fra admin_source_ip, ligesom SSH (ikke aabent for alle)
  security_rule {
    name                       = "Allow-Grafana"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = var.admin_source_ip
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg_assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# ---------------------------------------------------------------------------
# NIC
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "nic" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

# ---------------------------------------------------------------------------
# Cloud-init: samler installationsscripts til én custom_data
# ---------------------------------------------------------------------------
data "cloudinit_config" "init" {
  gzip          = false
  base64_encode = true

  # Ekstra Linux/SSH-brugere - oprettes af cloud-init's users-modul, inden
  # shell-scriptene nedenfor koerer
  part {
    content_type = "text/cloud-config"
    filename     = "00-users.yaml"
    content = "#cloud-config\n${yamlencode({
      users = [
        for u in var.additional_users : merge(
          {
            name                = u.username
            shell               = "/bin/bash"
            lock_passwd         = true
            ssh_authorized_keys = [file(u.ssh_public_key_path)]
          },
          u.sudo ? {
            groups = "sudo"
            sudo   = "ALL=(ALL) NOPASSWD:ALL"
          } : {}
        )
      ]
    })}"
  }

  # LAMP-stacken (templatefile, fordi den skal have db-passwordet)
  part {
    content_type = "text/x-shellscript"
    filename     = "01-install_lamp.sh"
    content = templatefile("${path.module}/scripts/install_lamp.sh", {
      db_root_password      = var.db_root_password
      dashboard_db_username = var.dashboard_db_username
      dashboard_db_password = var.dashboard_db_password
      dashboard_db_host     = var.dashboard_db_host
    })
  }

  # IDS - separat lag, ikke en del af LAMP
  part {
    content_type = "text/x-shellscript"
    filename     = "02-install_suricata.sh"
    content      = file("${path.module}/scripts/install_suricata.sh")
  }
  # Alerts til Discord - kraever at Suricata er installeret
  part {
    content_type = "text/x-shellscript"
    filename     = "03-install_discord_alerts.sh"
    content = templatefile("${path.module}/scripts/install_discord_alerts.sh", {
      discord_webhook_url = var.discord_webhook_url
    })
  }

  # Monitoring: node_exporter + mysqld_exporter + Prometheus + Grafana -
  # kraever at LAMP (og dashboard-DB-brugeren) er installeret
  part {
    content_type = "text/x-shellscript"
    filename     = "04-install_monitoring.sh"
    content = templatefile("${path.module}/scripts/install_monitoring.sh", {
      dashboard_db_username = var.dashboard_db_username
      dashboard_db_password = var.dashboard_db_password
    })
  }

  # GeoIP: tagger SSH- og Suricata-adgangsforsoeg med lokation og gemmer dem
  # i MariaDB, saa Grafana kan vise dem paa et verdenskort - kraever at
  # Suricata og Grafana (monitoring) allerede er installeret
  part {
    content_type = "text/x-shellscript"
    filename     = "05-install_geoip.sh"
    content = templatefile("${path.module}/scripts/install_geoip.sh", {
      db_root_password      = var.db_root_password
      dashboard_db_username = var.dashboard_db_username
      dashboard_db_password = var.dashboard_db_password
      geoip_db_password     = var.geoip_db_password
      maxmind_account_id    = var.maxmind_account_id
      maxmind_license_key   = var.maxmind_license_key
      geomap_dashboard_json = file("${path.module}/dashboards/access-geomap.json")
    })
  }
}
# ---------------------------------------------------------------------------
# VM - Ubuntu Server med LAMP installeret via cloud-init (custom_data)
# ---------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "vm" {
  name                = "${var.prefix}-vm"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
  # Kører LAMP + Suricata automatisk ved første boot via cloud-init
  custom_data = data.cloudinit_config.init.rendered
}
