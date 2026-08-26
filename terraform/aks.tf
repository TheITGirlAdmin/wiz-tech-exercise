resource "azurerm_container_registry" "main" {
  name                = "${var.prefix}acr${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"

  # Admin user stays OFF - the pipeline and AKS both authenticate with Entra
  # identities instead of a shared registry password.
  admin_enabled = false

  tags = local.tags
}

# ---------------------------------------------------------------------------
# AKS. Nodes sit in the private subnet (no public IPs). The API server is
# public so GitHub Actions can run kubectl against it without a self-hosted
# runner - a deliberate, defensible trade-off worth calling out in the demo.
# Locking the API server down is the natural "what I'd change for production"
# answer if a panelist pushes on it.
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "main" {
  name                = "${local.name}-aks"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "${local.name}-aks"
  kubernetes_version  = var.kubernetes_version
  node_resource_group = "${local.name}-aks-nodes-rg"

  default_node_pool {
    name            = "system"
    node_count      = var.aks_node_count
    vm_size         = var.aks_node_size
    vnet_subnet_id  = azurerm_subnet.aks.id
    os_disk_size_gb = 64

    # Nodes get private IPs only
    node_public_ip_enabled = false

    # Declared explicitly to match what AKS sets by default. Without this block
    # Azure populates max_surge = "10%" itself, Terraform sees an unmanaged
    # value and plans to remove it, Azure puts it back - and every subsequent
    # plan shows the same phantom change. Stating the default makes the
    # configuration converge.
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
    service_cidr      = "172.16.0.0/16"
    dns_service_ip    = "172.16.0.10"
  }

  # Managed nginx ingress controller. Gives us a Kubernetes Ingress backed by
  # an Azure Standard Load Balancer with a public IP - satisfying "exposed via
  # a Kubernetes ingress and CSP load balancer" with no Helm bootstrap step.
  web_app_routing {
    dns_zone_ids = []
  }

  # Ships container/node telemetry to Log Analytics for the detective controls
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  }

  # Entra-integrated RBAC. Kubernetes RBAC stays ON so the deliberately
  # over-permissive cluster-admin binding on the app is a real, visible finding
  # rather than an artifact of RBAC being disabled everywhere.
  role_based_access_control_enabled = true

  tags = local.tags
}

# Lets AKS pull images from ACR without a registry secret
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
