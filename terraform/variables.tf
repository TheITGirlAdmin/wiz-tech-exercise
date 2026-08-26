variable "subscription_id" {
  description = "Azure subscription ID (CloudLabs)."
  type        = string
}

variable "prefix" {
  description = "Short name prefix for all resources. Lowercase alphanumeric."
  type        = string
  default     = "wizex"

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.prefix))
    error_message = "prefix must be 3-10 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "demo"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "owner_tag" {
  description = "Value for the 'owner' tag applied to every resource."
  type        = string
  default     = "wiz-candidate"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vnet_cidr" {
  description = "Address space for the virtual network."
  type        = string
  default     = "10.10.0.0/16"
}

variable "aks_subnet_cidr" {
  description = "Private subnet for AKS nodes."
  type        = string
  default     = "10.10.1.0/24"
}

variable "db_subnet_cidr" {
  description = "Subnet for the MongoDB virtual machine."
  type        = string
  default     = "10.10.2.0/24"
}

# ---------------------------------------------------------------------------
# MongoDB VM
# ---------------------------------------------------------------------------

variable "vm_size" {
  description = "VM size for the database server. Keep small - CloudLabs budget is limited."
  type        = string
  default     = "Standard_B2s"
}

variable "vm_admin_username" {
  description = "Local admin username on the database VM."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key for the database VM (contents of ~/.ssh/wiz_exercise.pub)."
  type        = string
}

# INTENTIONAL WEAKNESS: an outdated, out-of-support Linux distribution.
# Ubuntu 20.04 LTS left standard support in April 2025 (>1 year outdated).
# Swap to the 18.04 block in vm-mongo.tf if you want an even older image and it
# is still available in your region's marketplace.
variable "vm_image" {
  description = "Marketplace image reference for the deliberately outdated VM."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
}

variable "mongo_version" {
  description = "MongoDB major.minor to install. 4.4 reached end-of-life Feb 2024 (>1 year outdated)."
  type        = string
  default     = "4.4"
}

variable "mongo_admin_username" {
  description = "MongoDB application user."
  type        = string
  default     = "taskyadmin"
}

variable "mongo_admin_password" {
  description = "MongoDB application password. Supply via TF_VAR_mongo_admin_password - never commit."
  type        = string
  sensitive   = true
}

variable "mongo_database" {
  description = <<-EOT
    Database name used by the Tasky application.

    IMPORTANT: Tasky HARDCODES this in database/database.go
    (client.Database("go-mongodb")) and ignores the database path in
    MONGODB_URI. Changing this value will NOT change where the app writes -
    it only affects which database gets seeded and which one the demo queries.
    Leave it as "go-mongodb" or the "prove the data is in the database" demo
    will query an empty database.

    Collections created by the app: "todos" and "user" (singular).
  EOT
  type        = string
  default     = "go-mongodb"
}

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------

variable "aks_node_count" {
  description = "Number of nodes in the default pool."
  type        = number
  default     = 2
}

variable "aks_node_size" {
  description = "VM size for AKS nodes."
  type        = string
  default     = "Standard_B2s"
}

variable "kubernetes_version" {
  description = "AKS control plane version. Leave null to take the region default."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Security controls
# ---------------------------------------------------------------------------

variable "allowed_vm_skus" {
  description = <<-EOT
    VM sizes permitted by the PREVENTATIVE Azure Policy. Anything outside this
    list is denied at deployment time. Chosen deliberately: it blocks real
    (expensive / unapproved) deployments without undoing any of the intentional
    misconfigurations this exercise requires.
  EOT
  type        = list(string)
  default     = ["Standard_B1s", "Standard_B2s", "Standard_B2ms", "Standard_D2s_v3"]
}

variable "enable_defender_plans" {
  description = <<-EOT
    Enable paid Microsoft Defender for Cloud plans (Servers P1, Containers,
    Storage). These COST MONEY. Set false while iterating, true before the demo.
  EOT
  type        = bool
  default     = true
}

variable "alert_email" {
  description = <<-EOT
    OPTIONAL email address for detective-control alert notifications.
    Leave empty (the default) to create the action group with no receivers:
    alert rules still evaluate and still fire, and the fired alerts are visible
    in Azure Monitor > Alerts. Delivery is a convenience, not part of detection.
  EOT
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Log Analytics retention. 30 is the free minimum."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Escape hatches for restricted CloudLabs subscriptions - see README
# ---------------------------------------------------------------------------

variable "vm_identity_role_scope" {
  description = <<-EOT
    Scope for the deliberately over-permissive VM identity role assignment.
    "subscription" is what the exercise asks for. Fall back to "resource_group"
    only if your lab subscription forbids subscription-scope assignments.
  EOT
  type        = string
  default     = "subscription"

  validation {
    condition     = contains(["subscription", "resource_group"], var.vm_identity_role_scope)
    error_message = "Must be 'subscription' or 'resource_group'."
  }
}

variable "enable_activity_log_diagnostics" {
  description = "Send subscription Activity Log to Log Analytics. Requires subscription-scope write access."
  type        = bool
  default     = true
}
