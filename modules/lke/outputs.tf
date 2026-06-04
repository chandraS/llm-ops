output "cluster_id" {
  value = linode_lke_cluster.main.id
}

output "cluster_label" {
  value = linode_lke_cluster.main.label
}

output "kubeconfig" {
  value     = linode_lke_cluster.main.kubeconfig
  sensitive = true
}

output "api_endpoints" {
  value = linode_lke_cluster.main.api_endpoints
}
