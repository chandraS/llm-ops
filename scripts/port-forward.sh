#!/bin/bash
# port-forward.sh — run after terraform apply to access all services locally
# Usage: bash scripts/port-forward.sh [--kubeconfig path/to/kubeconfig.yaml]

KUBECONFIG_PATH="${KUBECONFIG:-$(pwd)/kubeconfig.yaml}"

if [ ! -f "$KUBECONFIG_PATH" ]; then
  echo " kubeconfig not found at $KUBECONFIG_PATH"
  echo "   Run: terraform output -raw kubeconfig | base64 -d > kubeconfig.yaml"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

echo "Starting port-forwards..."
echo ""

# vLLM API
kubectl port-forward svc/qwen25-7b 8000:8000 -n llm-serving &
PID_VLLM=$!
echo "vLLM API      → http://localhost:8000"
echo "   Test:          curl http://localhost:8000/health"

# Prometheus
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring &
PID_PROM=$!
echo "Prometheus     → http://localhost:9090"

# Grafana
kubectl port-forward svc/kube-prom-stack-grafana 3000:80 -n monitoring &
PID_GRAFANA=$!
echo "Grafana        → http://localhost:3000"
echo "   Login:         admin / (your grafana_admin_password)"

echo ""
echo "Press Ctrl+C to stop all port-forwards"
echo ""

# Trap Ctrl+C and kill all background port-forwards
cleanup() {
  echo ""
  echo "Stopping port-forwards..."
  kill $PID_VLLM $PID_PROM $PID_GRAFANA 2>/dev/null
  exit 0
}

trap cleanup INT TERM
wait