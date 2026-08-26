# ===========================================================================
# CLOUD NATIVE SECURITY
#   1. Control-plane audit logging   (Activity Log + AKS kube-audit + storage)
#   2. Preventative controls         (two Azure Policy DENY assignments)
#   3. Detective controls            (Defender for Cloud + KQL alert rules)
# ===========================================================================

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${local.name}-law"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# 1. CONTROL PLANE AUDIT LOGGING
# ---------------------------------------------------------------------------

# Subscription Activity Log - every control-plane write in the subscription
resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  count = var.enable_activity_log_diagnostics ? 1 : 0

  name                       = "${local.name}-activity-to-law"
  target_resource_id         = "/subscriptions/${var.subscription_id}"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  dynamic "enabled_log" {
    for_each = [
      "Administrative", "Security", "ServiceHealth", "Alert",
      "Recommendation", "Policy", "Autoscale", "ResourceHealth",
    ]
    content {
      category = enabled_log.value
    }
  }
}

# Kubernetes control-plane audit logs. kube-audit is what proves who did what
# inside the cluster - essential for the detective control below.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "${local.name}-aks-to-law"
  target_resource_id         = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  dynamic "enabled_log" {
    for_each = [
      "kube-apiserver", "kube-audit", "kube-audit-admin",
      "kube-controller-manager", "kube-scheduler", "cluster-autoscaler", "guard",
    ]
    content {
      category = enabled_log.value
    }
  }
}

# Data-plane logging on the public backup bucket. Without this, anonymous
# downloads of the database backups leave no trace at all.
resource "azurerm_monitor_diagnostic_setting" "backup_storage" {
  name                       = "${local.name}-backupblob-to-law"
  target_resource_id         = "${azurerm_storage_account.backups.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  dynamic "enabled_log" {
    for_each = ["StorageRead", "StorageWrite", "StorageDelete"]
    content {
      category = enabled_log.value
    }
  }
}

# ---------------------------------------------------------------------------
# 2. PREVENTATIVE CONTROLS - Azure Policy, effect = Deny
#
# Both are scoped to the exercise resource group and chosen so they block real
# risk WITHOUT undoing any of the intentional weaknesses the brief requires.
# ---------------------------------------------------------------------------

# (a) Built-in: only approved VM sizes may be deployed.
#     Demo: attempt to create a Standard_D8s_v3 -> denied at request time.
data "azurerm_policy_definition" "allowed_vm_skus" {
  display_name = "Allowed virtual machine size SKUs"
}

resource "azurerm_resource_group_policy_assignment" "allowed_vm_skus" {
  name                 = "deny-unapproved-vm-skus"
  display_name         = "PREVENTATIVE: Deny unapproved VM sizes"
  description          = "Blocks deployment of VM sizes outside the approved list."
  resource_group_id    = azurerm_resource_group.main.id
  policy_definition_id = data.azurerm_policy_definition.allowed_vm_skus.id
  enforce              = true

  parameters = jsonencode({
    listOfAllowedSKUs = {
      value = var.allowed_vm_skus
    }
  })
}

# (b) Custom: deny any NSG rule that opens RDP (3389) to the internet.
#     Deliberately targets 3389, not 22 - the exercise REQUIRES SSH to be open,
#     so a policy denying 22 would fight the brief. This proves the guardrail
#     works without weakening the scenario.
resource "azurerm_policy_definition" "deny_rdp_from_internet" {
  name         = "${local.name}-deny-rdp-internet"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "PREVENTATIVE: Deny RDP (3389) exposed to the internet"
  description  = "Denies creation or update of NSGs containing an inbound Allow rule for TCP/3389 from any internet source."

  policy_rule = jsonencode({
    if = {
      count = {
        field = "Microsoft.Network/networkSecurityGroups/securityRules[*]"
        where = {
          allOf = [
            { field = "Microsoft.Network/networkSecurityGroups/securityRules[*].direction", equals = "Inbound" },
            { field = "Microsoft.Network/networkSecurityGroups/securityRules[*].access", equals = "Allow" },
            { field = "Microsoft.Network/networkSecurityGroups/securityRules[*].protocol", in = ["TCP", "*"] },
            { field = "Microsoft.Network/networkSecurityGroups/securityRules[*].destinationPortRange", in = ["3389", "*", "0-65535"] },
            { field = "Microsoft.Network/networkSecurityGroups/securityRules[*].sourceAddressPrefix", in = ["*", "Internet", "0.0.0.0/0", "<network>"] },
          ]
        }
      }
      greater = 0
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })

  parameters = jsonencode({
    effect = {
      type = "String"
      metadata = {
        displayName = "Effect"
        description = "Deny or Audit"
      }
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Deny"
    }
  })
}

resource "azurerm_resource_group_policy_assignment" "deny_rdp_from_internet" {
  name                 = "deny-rdp-internet"
  display_name         = "PREVENTATIVE: Deny internet-exposed RDP"
  resource_group_id    = azurerm_resource_group.main.id
  policy_definition_id = azurerm_policy_definition.deny_rdp_from_internet.id
  enforce              = true

  parameters = jsonencode({
    effect = { value = "Deny" }
  })
}

# ---------------------------------------------------------------------------
# 3. DETECTIVE CONTROLS
# ---------------------------------------------------------------------------

# Microsoft Defender for Cloud - CSPM findings + workload protection alerts.
# THESE PLANS COST MONEY. Set enable_defender_plans = false while iterating.
resource "azurerm_security_center_subscription_pricing" "servers" {
  count         = var.enable_defender_plans ? 1 : 0
  tier          = "Standard"
  resource_type = "VirtualMachines"
  subplan       = "P1"
}

resource "azurerm_security_center_subscription_pricing" "containers" {
  count         = var.enable_defender_plans ? 1 : 0
  tier          = "Standard"
  resource_type = "Containers"
}

resource "azurerm_security_center_subscription_pricing" "storage" {
  count         = var.enable_defender_plans ? 1 : 0
  tier          = "Standard"
  resource_type = "StorageAccounts"
  subplan       = "DefenderForStorageV2"
}

resource "azurerm_monitor_action_group" "security" {
  name                = "${local.name}-security-ag"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "wizsecag"

  # Email delivery is OPTIONAL. Leave alert_email empty and the action group is
  # created with no receivers - the alert rules below still evaluate, still fire,
  # and are still recorded in Azure Monitor > Alerts, which is where the demo
  # evidence comes from. An action group only decides who gets *told*, not
  # whether detection happens.
  dynamic "email_receiver" {
    for_each = var.alert_email == "" ? [] : [var.alert_email]
    content {
      name          = "security-owner"
      email_address = email_receiver.value
    }
  }

  tags = local.tags
}

# --- Detective control A: anonymous access to the public backup bucket ------
# Directly detects exploitation of the environment's worst misconfiguration.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "anonymous_backup_access" {
  name                = "${local.name}-anonymous-backup-access"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  description         = "Someone read or listed the MongoDB backup container without authenticating."
  severity            = 1
  enabled             = true

  scopes                  = [azurerm_log_analytics_workspace.main.id]
  evaluation_frequency    = "PT10M"
  window_duration         = "PT30M"
  auto_mitigation_enabled = false

  criteria {
    query = <<-KQL
      StorageBlobLogs
      | where AccountName == "${azurerm_storage_account.backups.name}"
      | where AuthenticationType == "Anonymous"
      | where OperationName in ("GetBlob", "ListBlobs")
      | project TimeGenerated, OperationName, CallerIpAddress, Uri, StatusCode
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.security.id]
  }

  tags = local.tags
}

# --- Detective control B: kubectl exec into a running pod -------------------
# Interactive shell access inside the cluster is a classic hands-on-keyboard
# signal - and it is exactly what an attacker would do after abusing the
# cluster-admin binding on the application pod.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "kubectl_exec" {
  name                = "${local.name}-kubectl-exec-detected"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  description         = "A user opened an interactive session inside a pod (kubectl exec)."
  severity            = 2
  enabled             = true

  scopes                  = [azurerm_log_analytics_workspace.main.id]
  evaluation_frequency    = "PT10M"
  window_duration         = "PT30M"
  auto_mitigation_enabled = false

  criteria {
    query = <<-KQL
      AzureDiagnostics
      | where Category == "kube-audit"
      // column_ifexists is REQUIRED here. Azure validates this KQL when the
      // alert rule is created, and log_s is a dynamic column that only appears
      // in the AzureDiagnostics schema once kube-audit data has actually been
      // ingested. On a brand-new workspace a bare reference to log_s fails with
      // "Failed to resolve scalar expression named 'log_s'". This form is
      // schema-independent: it validates against an empty workspace and starts
      // matching the moment real audit rows arrive.
      | extend audit = parse_json(column_ifexists("log_s", ""))
      | where tostring(audit.objectRef.subresource) == "exec"
      | where tostring(audit.stage) == "ResponseStarted"
      | project TimeGenerated,
                actor = tostring(audit.user.username),
                namespace = tostring(audit.objectRef.namespace),
                pod = tostring(audit.objectRef.name),
                sourceIP = tostring(audit.sourceIPs[0])
    KQL

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.security.id]
  }

  tags = local.tags
}
