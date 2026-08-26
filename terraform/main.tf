resource "azurerm_resource_group" "main" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags
}

# Random suffix keeps globally-unique names (storage, ACR) from colliding
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}
