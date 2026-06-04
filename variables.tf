# ── Linode ──────────────────────────────────────────────────────────────────
variable "region" {
  description = "Linode region for the LKE cluster"
  type        = string
  default     = "us-sea"
}

variable "cluster_label" {
  description = "LKE cluster display name"
  type        = string
  default     = "akamai-llm-poc"
}

variable "k8s_version" {
  description = "Kubernetes version for LKE"
  type        = string
  default     = "1.35"
}

# ── Node pools ───────────────────────────────────────────────────────────────
variable "cpu_node_type" {
  description = "Linode plan for CPU node pool (monitoring, KEDA, etc.)"
  type        = string
  default     = "g6-standard-4"  # 4 vCPU, 8GB RAM
}

variable "cpu_node_count" {
  description = "Number of CPU nodes"
  type        = number
  default     = 3
}

variable "gpu_node_type" {
  description = "Linode GPU plan — RTX 4000 Ada = g1-gpu-rtx4000-1"
  type        = string
  default     = "g2-gpu-rtx4000a1-l"
}

variable "gpu_node_count" {
  description = "Number of GPU nodes (each runs one vLLM replica)"
  type        = number
  default     = 3
}

# ── Control Plane ACL ────────────────────────────────────────────────────────
variable "control_plane_acl_enabled" {
  description = "Enable Control Plane ACL to restrict API server access"
  type        = bool
  default     = false
}

variable "control_plane_acl_ipv4_ranges" {
  description = "IPv4 CIDRs allowed to reach the Kubernetes API server"
  type        = list(string)
  default     = []
  # example: ["203.0.113.0/24", "198.51.100.5/32"]
}

variable "high_availability" {
  description = "Enable HA control plane (3 etcd nodes)"
  type        = bool
  default     = false  # off for PoC cost savings
}

# ── Model ────────────────────────────────────────────────────────────────────
variable "hf_token" {
  description = "HuggingFace API token for model download"
  type        = string
  sensitive   = true
}

variable "model_name" {
  description = "HuggingFace model ID"
  type        = string
  default     = "Qwen/Qwen2.5-7B-Instruct"
}

variable "served_model_name" {
  description = "Model name exposed via vLLM API and used in Prometheus labels"
  type        = string
  default     = "qwen25-7b"
}

variable "gpu_memory_utilization" {
  description = "Fraction of GPU VRAM allocated to vLLM KV cache pool"
  type        = number
  default     = 0.90
}

variable "max_model_len" {
  description = "Maximum context length in tokens"
  type        = number
  default     = 8192
}

# ── Autoscaling ──────────────────────────────────────────────────────────────
variable "min_replicas" {
  description = "Minimum vLLM replicas (must be >= 1 for Prometheus-based KEDA)"
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum vLLM replicas — limited by GPU node count"
  type        = number
  default     = 4
}

variable "queue_depth_threshold" {
  description = "num_requests_waiting value per replica that triggers scale-out"
  type        = number
  default     = 2
}

variable "kv_cache_threshold" {
  description = "KV cache utilisation % that triggers scale-out"
  type        = number
  default     = 70
}

variable "keda_polling_interval" {
  description = "Seconds between KEDA metric evaluations"
  type        = number
  default     = 30
}

variable "keda_cooldown_period" {
  description = "Seconds KEDA waits after load drops before scaling down"
  type        = number
  default     = 300
}

# ── Monitoring ───────────────────────────────────────────────────────────────
variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
  default     = "changeme"
}

variable "prometheus_retention" {
  description = "Prometheus data retention period"
  type        = string
  default     = "15d"
}
