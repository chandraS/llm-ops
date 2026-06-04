terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }
}

# ── Namespaces ───────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}

resource "kubernetes_namespace" "keda" {
  metadata { name = "keda" }
}

resource "kubernetes_namespace" "gpu_operator" {
  metadata { name = "gpu-operator" }
}

# ── kube-prometheus-stack ────────────────────────────────────────────────────
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prom-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "58.0.0"
  timeout    = 600

  # ruleNamespaceSelector must be an object — use values block, not set
  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          ruleNamespaceSelector = {}
        }
      }
    })
  ]

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = var.prometheus_retention
  }
  set {
    name  = "grafana.enabled"
    value = "true"
  }
  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  # ── Grafana sidecar — auto-loads ConfigMaps labelled grafana_dashboard=1 ──
  set {
    name  = "grafana.sidecar.dashboards.enabled"
    value = "true"
  }
  set {
    name  = "grafana.sidecar.dashboards.label"
    value = "grafana_dashboard"
  }
  set {
    name  = "grafana.sidecar.dashboards.labelValue"
    value = "1"
  }
  set {
    name  = "grafana.sidecar.dashboards.searchNamespace"
    value = "ALL"
  }

  # Disable components not accessible on LKE managed control plane
  set {
    name  = "kubeEtcd.enabled"
    value = "false"
  }
  set {
    name  = "kubeScheduler.enabled"
    value = "false"
  }
  set {
    name  = "kubeControllerManager.enabled"
    value = "false"
  }
  set {
    name  = "kubeProxy.enabled"
    value = "false"
  }
}

# ── KEDA ─────────────────────────────────────────────────────────────────────
resource "helm_release" "keda" {
  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  namespace  = kubernetes_namespace.keda.metadata[0].name
  version    = "2.14.0"
  timeout    = 300

  set {
    name  = "watchNamespace"
    value = ""  # watch all namespaces
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# ── NVIDIA GPU Operator ───────────────────────────────────────────────────────
resource "helm_release" "gpu_operator" {
  name       = "gpu-operator"
  repository = "https://helm.ngc.nvidia.com/nvidia"
  chart      = "gpu-operator"
  namespace  = kubernetes_namespace.gpu_operator.metadata[0].name
  version    = "v24.3.0"
  timeout    = 600

  # Akamai GPU nodes have drivers pre-installed
  set {
    name  = "driver.enabled"
    value = "false"
  }
  set {
    name  = "toolkit.enabled"
    value = "true"
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# ── DCGM Exporter ServiceMonitor ─────────────────────────────────────────────
resource "kubectl_manifest" "dcgm_service_monitor" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: dcgm-exporter
      namespace: gpu-operator
      labels:
        release: kube-prom-stack
    spec:
      selector:
        matchLabels:
          app: nvidia-dcgm-exporter
      endpoints:
        - port: gpu-metrics
          path: /metrics
          interval: 15s
      namespaceSelector:
        matchNames:
          - gpu-operator
  YAML

  depends_on = [helm_release.gpu_operator, helm_release.kube_prometheus_stack]
}
