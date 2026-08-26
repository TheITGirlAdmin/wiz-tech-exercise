# ---------------------------------------------------------------------------
# Backup target for the daily MongoDB dump.
#
# >>> INTENTIONAL WEAKNESS <<<
# The brief requires object storage that allows public READ and public LISTING.
# That combination means anyone on the internet who guesses the account name can
# enumerate and download full database backups - no credentials, no logging of
# the requester's identity. This is the single highest-impact finding in the
# environment and the one to lead with in the presentation.
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AZURE_59:Public access is the deliberate misconfiguration under test
#checkov:skip=CKV_AZURE_190:Public blob access required by the exercise brief
resource "azurerm_storage_account" "backups" {
  name                = "${var.prefix}bak${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # >>> INTENTIONAL WEAKNESS <<< - permits anonymous container/blob access
  allow_nested_items_to_be_public = true
  public_network_access_enabled   = true

  # Kept secure on purpose: transport encryption is NOT one of the weaknesses
  # the brief asks for, and leaving it on shows deliberate, selective exposure
  # rather than a uniformly careless build.
  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = merge(local.tags, {
    exercise_weakness = "public-read-and-list"
  })
}

# container_access_type = "container" grants anonymous READ *and* LIST.
# ("blob" would give read-only without listing - not what the brief requires.)
resource "azurerm_storage_container" "backups" {
  name                  = "mongo-backups"
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "container"
}

# The VM's managed identity writes backups using Entra auth (az storage blob
# upload --auth-mode login) rather than a shared account key, so no long-lived
# storage key ever lands on disk.
resource "azurerm_role_assignment" "vm_blob_contributor" {
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.mongo.identity[0].principal_id
}
