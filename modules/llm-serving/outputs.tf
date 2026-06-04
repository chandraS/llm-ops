output "vllm_service_name" {
  value = var.served_model_name
}

output "vllm_namespace" {
  value = kubernetes_namespace.llm_serving.metadata[0].name
}

output "scaled_object_name" {
  value = "${var.served_model_name}-scaler"
}
