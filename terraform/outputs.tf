output "resource_group_name" {
  description = "Resource group holding the exercise environment."
  value       = azurerm_resource_group.main.name
}

output "mongo_public_ip" {
  description = "Public IP of the database VM (SSH is deliberately open here)."
  value       = azurerm_public_ip.mongo.ip_address
}

output "mongo_private_ip" {
  description = "Private IP the Kubernetes pods use to reach MongoDB."
  value       = azurerm_network_interface.mongo.private_ip_address
}

output "ssh_command" {
  description = "Copy-paste SSH command for the demo."
  value       = "ssh -i ~/.ssh/wiz_exercise ${var.vm_admin_username}@${azurerm_public_ip.mongo.ip_address}"
}

output "mongodb_uri" {
  description = "Connection string injected into Kubernetes as an environment variable."
  value       = "mongodb://${var.mongo_admin_username}:${var.mongo_admin_password}@${azurerm_network_interface.mongo.private_ip_address}:27017/${var.mongo_database}?authSource=admin"
  sensitive   = true
}

output "backup_storage_account" {
  description = "Storage account holding the daily MongoDB dumps."
  value       = azurerm_storage_account.backups.name
}

output "public_backup_listing_url" {
  description = "Anonymous container listing URL - open this in a private browser window during the demo."
  value       = "https://${azurerm_storage_account.backups.name}.blob.core.windows.net/${azurerm_storage_container.backups.name}?restype=container&comp=list"
}

output "acr_login_server" {
  description = "Container registry hostname."
  value       = azurerm_container_registry.main.login_server
}

output "acr_name" {
  description = "Container registry name (for az acr build / GitHub Actions)."
  value       = azurerm_container_registry.main.name
}

output "aks_cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.main.name
}

output "kubeconfig_command" {
  description = "Fetch cluster credentials before the demo."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
}

output "log_analytics_workspace_name" {
  description = "Workspace backing the detective controls."
  value       = azurerm_log_analytics_workspace.main.name
}
