# ── Cluster ──────────────────────────────────────────────────────────────────
region        = "us-sea"
cluster_label = "akamai-llm-poc"
k8s_version   = "1.35"

# ── Node pools ───────────────────────────────────────────────────────────────
gpu_node_type  = "g2-gpu-rtx4000a1-l"
gpu_node_count = 3

# ── Control Plane ACL ────────────────────────────────────────────────────────
# Set to true and add your IP to restrict API server access
control_plane_acl_enabled     = false
control_plane_acl_ipv4_ranges = []
# control_plane_acl_ipv4_ranges = ["YOUR_IP/32"]

high_availability = false

# ── Model ────────────────────────────────────────────────────────────────────
# hf_token and grafana_admin_password passed via env vars:
#   export TF_VAR_hf_token="hf-..."
#   export TF_VAR_grafana_admin_password="your-password"

model_name             = "Qwen/Qwen2.5-7B-Instruct"
served_model_name      = "qwen25-7b"
gpu_memory_utilization = 0.90
max_model_len          = 8192

# ── Autoscaling ──────────────────────────────────────────────────────────────
min_replicas          = 1
max_replicas          = 3
queue_depth_threshold = 2
kv_cache_threshold    = 70
keda_polling_interval = 30
keda_cooldown_period  = 300

# ── Monitoring ───────────────────────────────────────────────────────────────
prometheus_retention = "15d"
