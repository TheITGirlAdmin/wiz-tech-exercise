resource "azurerm_public_ip" "mongo" {
  name                = "${local.name}-mongo-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "mongo" {
  name                = "${local.name}-mongo-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.db.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.mongo.id
  }
}

# ---------------------------------------------------------------------------
# The database server.
#
# >>> INTENTIONAL WEAKNESSES on this resource <<<
#   1. Out-of-support OS (Ubuntu 20.04 - standard support ended April 2025)
#   2. SSH open to the internet (see network.tf)
#   3. System-assigned identity holding Contributor at SUBSCRIPTION scope
#
# Chained together: an attacker who lands on this box via SSH inherits the
# ability to create VMs, read storage, and pivot anywhere in the subscription.
# ---------------------------------------------------------------------------
#checkov:skip=CKV_AZURE_50:Extensions allowed - VM is a deliberate weak point
resource "azurerm_linux_virtual_machine" "mongo" {
  name                = "${local.name}-mongo-vm"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.vm_admin_username

  network_interface_ids = [azurerm_network_interface.mongo.id]

  # Password auth stays disabled - key-based SSH only. The exposure is the open
  # port, not weak credentials, which keeps the finding clean to explain.
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "${local.name}-mongo-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = var.vm_image.publisher
    offer     = var.vm_image.offer
    sku       = var.vm_image.sku
    version   = var.vm_image.version
  }

  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init/mongo.yaml.tftpl", {
    mongo_version          = var.mongo_version
    mongo_admin_username   = var.mongo_admin_username
    mongo_admin_password   = var.mongo_admin_password
    mongo_database         = var.mongo_database
    storage_account_name   = azurerm_storage_account.backups.name
    storage_container_name = azurerm_storage_container.backups.name
  }))

  tags = merge(local.tags, {
    exercise_weakness = "outdated-os,public-ssh,overprivileged-identity"
    role              = "database"
  })

  lifecycle {
    # custom_data is cloud-init: it runs once at first boot to install and
    # configure MongoDB. Re-rendering it later (for example when the password
    # variable is supplied to CI differently than at the original apply) must
    # NOT replace a running database server and destroy its data. Bootstrap
    # data is deliberately ignored after the VM is created.
    ignore_changes = [custom_data]
  }
}

# ---------------------------------------------------------------------------
# >>> INTENTIONAL WEAKNESS <<<
# Contributor at subscription scope on a publicly reachable VM. The brief asks
# for "overly permissive CSP permissions (e.g. able to create VMs)"; Contributor
# is the cleanest way to demonstrate that without inventing a custom role.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "vm_overprivileged_subscription" {
  count = var.vm_identity_role_scope == "subscription" ? 1 : 0

  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_virtual_machine.mongo.identity[0].principal_id
}

# Fallback for lab subscriptions that forbid subscription-scope assignments.
resource "azurerm_role_assignment" "vm_overprivileged_rg" {
  count = var.vm_identity_role_scope == "resource_group" ? 1 : 0

  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_virtual_machine.mongo.identity[0].principal_id
}
