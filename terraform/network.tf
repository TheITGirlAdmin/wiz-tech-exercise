resource "azurerm_virtual_network" "main" {
  name                = "${local.name}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# AKS node subnet - PRIVATE. No public IPs are attached to nodes; egress goes
# out through the cluster's load balancer. Public ingress reaches the app only
# via the managed nginx ingress controller + Azure Standard Load Balancer.
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_subnet_cidr]
}

resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.db_subnet_cidr]
}

# ---------------------------------------------------------------------------
# NSG for the database subnet
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "db" {
  name                = "${local.name}-db-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# >>> INTENTIONAL WEAKNESS <<<
# SSH exposed to the entire internet. Required by the exercise brief.
# Wiz will flag this as an externally exposed management port on a VM that also
# holds an over-permissive identity - a textbook lateral-movement chain.
#checkov:skip=CKV_AZURE_10:Deliberate misconfiguration required by the exercise
resource "azurerm_network_security_rule" "ssh_from_internet" {
  name                        = "allow-ssh-from-internet-INTENTIONAL-WEAKNESS"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.db.name
}

# MongoDB reachable ONLY from the AKS subnet. This one is a real control -
# the brief requires database access to be restricted to Kubernetes.
resource "azurerm_network_security_rule" "mongo_from_aks" {
  name                        = "allow-mongodb-from-aks-subnet-only"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "27017"
  source_address_prefix       = var.aks_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.db.name
}

# Explicit deny for Mongo from anywhere else. Azure's default rules would allow
# intra-VNet traffic on 27017; this closes that and makes the intent auditable.
resource "azurerm_network_security_rule" "mongo_deny_all" {
  name                        = "deny-mongodb-from-everywhere-else"
  priority                    = 210
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "27017"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.db.name
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.db.id
}
