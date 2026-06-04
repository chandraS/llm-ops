terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }
}

resource "linode_lke_cluster" "main" {
  label       = var.cluster_label
  region      = var.region
  k8s_version = var.k8s_version

  # Single GPU node pool — handles both platform and vLLM workloads
  pool {
    type  = var.gpu_node_type
    count = var.gpu_node_count

    autoscaler {
      min = var.gpu_node_count
      max = var.max_gpu_nodes
    }
  }

  control_plane {
    high_availability = var.high_availability

    acl {
      enabled = var.control_plane_acl_enabled

      dynamic "addresses" {
        for_each = var.control_plane_acl_enabled ? [1] : []
        content {
          ipv4 = var.control_plane_acl_ipv4_ranges
        }
      }
    }
  }

  tags = ["akamai-poc", "llm-serving"]
}