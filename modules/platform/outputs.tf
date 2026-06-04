output "prometheus_service" {
  description = "Prometheus service name for KEDA ScaledObject serverAddress"
  value       = "prometheus-operated"
}

output "prometheus_namespace" {
  description = "Namespace where Prometheus is running"
  value       = kubernetes_namespace.monitoring.metadata[0].name
}

output "grafana_service" {
  description = "Grafana service name"
  value       = "kube-prom-stack-grafana"
}
