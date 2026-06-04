# ── LKE Cluster ─────────────────────────────────────────────────────────────
module "lke" {
  source = "./modules/lke"

  cluster_label                 = var.cluster_label
  region                        = var.region
  k8s_version                   = var.k8s_version
  cpu_node_type                 = var.cpu_node_type
  cpu_node_count                = var.cpu_node_count
  gpu_node_type                 = var.gpu_node_type
  gpu_node_count                = var.gpu_node_count
  control_plane_acl_enabled     = var.control_plane_acl_enabled
  control_plane_acl_ipv4_ranges = var.control_plane_acl_ipv4_ranges
  high_availability             = var.high_availability
}

# Write kubeconfig to disk for post-apply kubectl/port-forward usage
resource "local_sensitive_file" "kubeconfig" {
  content         = local.kubeconfig_decoded
  filename        = "${path.root}/kubeconfig.yaml"
  file_permission = "0600"
  depends_on      = [module.lke]
}

# ── Platform (operators + monitoring) ────────────────────────────────────────
module "platform" {
  source = "./modules/platform"

  grafana_admin_password   = var.grafana_admin_password
  prometheus_retention     = var.prometheus_retention

  depends_on = [module.lke]
}

# ── LLM Serving ──────────────────────────────────────────────────────────────
module "llm_serving" {
  source = "./modules/llm-serving"

  hf_token               = var.hf_token
  model_name             = var.model_name
  served_model_name      = var.served_model_name
  gpu_memory_utilization = var.gpu_memory_utilization
  max_model_len          = var.max_model_len
  min_replicas           = var.min_replicas
  max_replicas           = var.max_replicas
  queue_depth_threshold  = var.queue_depth_threshold
  kv_cache_threshold     = var.kv_cache_threshold
  keda_polling_interval  = var.keda_polling_interval
  keda_cooldown_period   = var.keda_cooldown_period
  prometheus_service     = module.platform.prometheus_service
  prometheus_namespace   = module.platform.prometheus_namespace

  depends_on = [module.platform]
}
