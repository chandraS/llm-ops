variable "cluster_label"                 { type = string }
variable "region"                         { type = string }
variable "k8s_version"                    { type = string }
variable "cpu_node_type"                  { type = string }
variable "cpu_node_count"                 { type = number }
variable "gpu_node_type"                  { type = string }
variable "gpu_node_count"                 { type = number }
variable "high_availability"              { type = bool }
variable "control_plane_acl_enabled"      { type = bool }
variable "control_plane_acl_ipv4_ranges"  { type = list(string) }

variable "max_gpu_nodes" {
  description = "Maximum GPU nodes the autoscaler can provision"
  type        = number
  default     = 3
}
