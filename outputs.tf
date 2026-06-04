output "cluster_id" {
  description = "LKE cluster ID"
  value       = module.lke.cluster_id
}

output "cluster_label" {
  description = "LKE cluster label"
  value       = module.lke.cluster_label
}

output "kubeconfig_path" {
  description = "Path to the written kubeconfig file"
  value       = local_sensitive_file.kubeconfig.filename
}

output "kubeconfig" {
  description = "Base64-encoded kubeconfig — use: terraform output -raw kubeconfig | base64 -d"
  value       = module.lke.kubeconfig
  sensitive   = true
}

output "vllm_api_port_forward" {
  description = "Command to port-forward vLLM API"
  value       = "kubectl port-forward svc/${var.served_model_name} 8000:8000 -n llm-serving --kubeconfig kubeconfig.yaml"
}

output "prometheus_port_forward" {
  description = "Command to port-forward Prometheus"
  value       = "kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring --kubeconfig kubeconfig.yaml"
}

output "grafana_port_forward" {
  description = "Command to port-forward Grafana"
  value       = "kubectl port-forward svc/kube-prom-stack-grafana 3000:80 -n monitoring --kubeconfig kubeconfig.yaml"
}

output "grafana_admin_password" {
  description = "Grafana admin password"
  value       = var.grafana_admin_password
  sensitive   = true
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT
    Deployment complete. Run the following to access services:

    1. Set kubeconfig:
       export KUBECONFIG=$(pwd)/kubeconfig.yaml

    2. Start all port-forwards:
       bash scripts/port-forward.sh

    3. Access:
       vLLM API   → http://localhost:8000/v1/chat/completions
       Prometheus → http://localhost:9090
       Grafana    → http://localhost:3000  (admin / run: terraform output -raw grafana_admin_password)

    4. Run load test:
       python scripts/demo_load_test.py --mode combined --duration 180 --concurrency 10
  EOT
}
