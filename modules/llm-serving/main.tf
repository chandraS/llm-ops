terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

# ── Namespace ────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "llm_serving" {
  metadata { name = "llm-serving" }
}

# ── HuggingFace token secret ──────────────────────────────────────────────────
resource "kubernetes_secret" "hf_token" {
  metadata {
    name      = "hf-token"
    namespace = kubernetes_namespace.llm_serving.metadata[0].name
  }
  data = {
    token = var.hf_token
  }
  type = "Opaque"
}

# ── vLLM Deployment ───────────────────────────────────────────────────────────
resource "kubectl_manifest" "vllm_deployment" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: ${var.served_model_name}
      namespace: llm-serving
      labels:
        app: ${var.served_model_name}
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: ${var.served_model_name}
      template:
        metadata:
          labels:
            app: ${var.served_model_name}
        spec:
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: vllm
              image: vllm/vllm-openai:latest
              args:
                - --model=${var.model_name}
                - --served-model-name=${var.served_model_name}
                - --gpu-memory-utilization=${var.gpu_memory_utilization}
                - --max-model-len=${var.max_model_len}
                - --port=8000
              ports:
                - name: http
                  containerPort: 8000
                - name: metrics
                  containerPort: 8000
              resources:
                limits:
                  nvidia.com/gpu: "1"
                requests:
                  nvidia.com/gpu: "1"
              readinessProbe:
                httpGet:
                  path: /health
                  port: 8000
                initialDelaySeconds: 60
                periodSeconds: 15
                failureThreshold: 10
              livenessProbe:
                httpGet:
                  path: /health
                  port: 8000
                initialDelaySeconds: 90
                periodSeconds: 30
              env:
                - name: HUGGING_FACE_HUB_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: hf-token
                      key: token
  YAML

  depends_on = [kubernetes_secret.hf_token]
}

# ── vLLM Service ──────────────────────────────────────────────────────────────
resource "kubectl_manifest" "vllm_service" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: ${var.served_model_name}
      namespace: llm-serving
      labels:
        app: ${var.served_model_name}
    spec:
      selector:
        app: ${var.served_model_name}
      ports:
        - name: http
          port: 8000
          targetPort: 8000
        - name: metrics
          port: 9090
          targetPort: 8000
  YAML

  depends_on = [kubectl_manifest.vllm_deployment]
}

# ── ServiceMonitor ────────────────────────────────────────────────────────────
resource "kubectl_manifest" "vllm_service_monitor" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: ${var.served_model_name}
      namespace: llm-serving
      labels:
        release: kube-prom-stack
    spec:
      selector:
        matchLabels:
          app: ${var.served_model_name}
      endpoints:
        - port: metrics
          path: /metrics
          interval: 15s
      namespaceSelector:
        matchNames:
          - llm-serving
  YAML

  depends_on = [kubectl_manifest.vllm_service]
}

# ── Wait for vLLM metrics to appear in Prometheus ────────────────────────────
resource "time_sleep" "wait_for_metrics" {
  create_duration = "120s"
  depends_on      = [kubectl_manifest.vllm_service_monitor]
}

# ── KEDA ScaledObject — dual Prometheus triggers ──────────────────────────────
resource "kubectl_manifest" "keda_scaled_object" {
  yaml_body = <<-YAML
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: ${var.served_model_name}-scaler
      namespace: llm-serving
    spec:
      scaleTargetRef:
        name: ${var.served_model_name}
      minReplicaCount: ${var.min_replicas}
      maxReplicaCount: ${var.max_replicas}
      cooldownPeriod: ${var.keda_cooldown_period}
      pollingInterval: ${var.keda_polling_interval}
      triggers:
        - type: prometheus
          metadata:
            serverAddress: http://${var.prometheus_service}.${var.prometheus_namespace}.svc.cluster.local:9090
            query: sum(vllm:num_requests_waiting{model_name="${var.served_model_name}"})
            threshold: "${var.queue_depth_threshold}"
        - type: prometheus
          metadata:
            serverAddress: http://${var.prometheus_service}.${var.prometheus_namespace}.svc.cluster.local:9090
            query: sum(vllm:kv_cache_usage_perc{model_name="${var.served_model_name}"}) * 100
            threshold: "${var.kv_cache_threshold}"
  YAML

  depends_on = [time_sleep.wait_for_metrics]
}

# ── vLLM PrometheusRule alerts ────────────────────────────────────────────────
resource "kubectl_manifest" "vllm_alerts" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PrometheusRule
    metadata:
      name: vllm-alerts
      namespace: llm-serving
      labels:
        release: kube-prom-stack
    spec:
      groups:
        - name: vllm.p0
          interval: 15s
          rules:
            - alert: VLLMPodRestart
              expr: increase(kube_pod_container_status_restarts_total{namespace="llm-serving"}[5m]) > 0
              for: 0m
              labels:
                severity: critical
              annotations:
                summary: "vLLM pod restarted"
                description: "Pod {{ $labels.pod }} restarted — check for OOMKill"
            - alert: VLLMHighErrorRate
              expr: |
                rate(vllm:request_success_total{model_name="${var.served_model_name}",finished_reason="error"}[2m])
                / rate(vllm:request_success_total{model_name="${var.served_model_name}"}[2m]) > 0.02
              for: 2m
              labels:
                severity: critical
              annotations:
                summary: "vLLM error rate exceeds 2%"
                description: "Error rate {{ $value | humanizePercentage }}"
        - name: vllm.p1
          interval: 30s
          rules:
            - alert: VLLMPreemptionsActive
              expr: rate(vllm:num_preemptions_total{model_name="${var.served_model_name}"}[1m]) > 0
              for: 1m
              labels:
                severity: warning
              annotations:
                summary: "vLLM is preempting requests"
                description: "Requests being evicted mid-generation — lower KV cache threshold"
            - alert: VLLMHighTTFT
              expr: |
                histogram_quantile(0.95,
                  rate(vllm:time_to_first_token_seconds_bucket{model_name="${var.served_model_name}"}[2m])
                ) > 5
              for: 2m
              labels:
                severity: warning
              annotations:
                summary: "vLLM TTFT P95 exceeds 5s"
                description: "P95 TTFT {{ $value | humanizeDuration }}"
            - alert: VLLMHighAbortRate
              expr: |
                rate(vllm:request_success_total{model_name="${var.served_model_name}",finished_reason="abort"}[2m])
                / rate(vllm:request_success_total{model_name="${var.served_model_name}"}[2m]) > 0.02
              for: 2m
              labels:
                severity: warning
              annotations:
                summary: "vLLM abort rate exceeds 2%"
                description: "Abort rate {{ $value | humanizePercentage }} — clients timing out"
            - alert: VLLMKVCacheCritical
              expr: sum(vllm:kv_cache_usage_perc{model_name="${var.served_model_name}"}) * 100 > 85
              for: 1m
              labels:
                severity: warning
              annotations:
                summary: "vLLM KV cache above 85%"
                description: "KV cache at {{ $value }}% — preemptions imminent"
  YAML

  depends_on = [kubectl_manifest.vllm_service_monitor]
}

# ── GPU PrometheusRule alerts ─────────────────────────────────────────────────
# Note: DCGM ServiceMonitor is created in modules/platform — no duplicate here
resource "kubectl_manifest" "gpu_alerts" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PrometheusRule
    metadata:
      name: gpu-alerts
      namespace: gpu-operator
      labels:
        release: kube-prom-stack
    spec:
      groups:
        - name: gpu.p1
          interval: 30s
          rules:
            - alert: GPUHighTemperature
              expr: DCGM_FI_DEV_GPU_TEMP > 85
              for: 2m
              labels:
                severity: warning
              annotations:
                summary: "GPU temperature critical on {{ $labels.Hostname }}"
                description: "GPU {{ $labels.device }} at {{ $value }}°C"
            - alert: GPUClockThrottling
              expr: |
                (max_over_time(DCGM_FI_DEV_SM_CLOCK[10m]) - DCGM_FI_DEV_SM_CLOCK)
                / max_over_time(DCGM_FI_DEV_SM_CLOCK[10m]) > 0.20
              for: 3m
              labels:
                severity: warning
              annotations:
                summary: "GPU clock throttling on {{ $labels.Hostname }}"
                description: "SM clock dropped >20% from peak on {{ $labels.device }}"
            - alert: GPUHighPowerDraw
              expr: DCGM_FI_DEV_POWER_USAGE / DCGM_FI_DEV_POWER_MGMT_LIMIT * 100 > 90
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "GPU power draw near cap on {{ $labels.Hostname }}"
                description: "GPU {{ $labels.device }} at {{ $value }}% of power cap"
            - alert: GPUSingleBitECCErrors
              expr: rate(DCGM_FI_DEV_ECC_SBE_VOL_TOTAL[5m]) > 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "GPU ECC errors on {{ $labels.Hostname }}"
                description: "Single-bit ECC errors accumulating on {{ $labels.device }}"
  YAML

  depends_on = [kubectl_manifest.vllm_service_monitor]
}

# ── Grafana Dashboard ConfigMaps ──────────────────────────────────────────────
# Grafana sidecar (enabled in platform/main.tf) watches for ConfigMaps
# labelled grafana_dashboard=1 across all namespaces and loads them automatically

resource "kubernetes_config_map" "vllm_dashboard" {
  metadata {
    name      = "vllm-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "vllm-dashboard.json" = file("${path.module}/dashboards/vllm-dashboard.json")
  }

  depends_on = [kubectl_manifest.vllm_service_monitor]
}

resource "kubernetes_config_map" "gpu_dashboard" {
  metadata {
    name      = "gpu-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "gpu-dashboard.json" = file("${path.module}/dashboards/gpu-dashboard.json")
  }

  depends_on = [kubectl_manifest.vllm_service_monitor]
}
