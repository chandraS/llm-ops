variable "hf_token" {
  type      = string
  sensitive = true
}
variable "model_name"             { type = string }
variable "served_model_name"      { type = string }
variable "gpu_memory_utilization" { type = number }
variable "max_model_len"          { type = number }
variable "min_replicas"           { type = number }
variable "max_replicas"           { type = number }
variable "queue_depth_threshold"  { type = number }
variable "kv_cache_threshold"     { type = number }
variable "keda_polling_interval"  { type = number }
variable "keda_cooldown_period"   { type = number }
variable "prometheus_service"     { type = string }
variable "prometheus_namespace"   { type = string }
