# LLM Observability — Terraform

Provisions a Kubernetes cluster on Akamai Cloud (LKE) with vLLM, kube-prometheus-stack, KEDA, NVIDIA GPU operator, and a full set of Prometheus alerts and Grafana dashboards — all from a single `terraform apply`.

## Architecture

```
LKE cluster (3× RTX 4000 GPU nodes)
├── monitoring/          kube-prometheus-stack (Prometheus + Grafana)
├── keda/                KEDA autoscaler
├── gpu-operator/        NVIDIA GPU operator + DCGM exporter
└── llm-serving/         vLLM deployment, ServiceMonitor, ScaledObject, alerts
```

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | >= 1.6 | `brew install terraform` |
| kubectl | any | `brew install kubectl` |
| AWS CLI | any | `brew install awscli` (only needed to verify bucket) |

Accounts needed:
- [Akamai Cloud](https://cloud.linode.com) account with a Personal Access Token
- [HuggingFace](https://huggingface.co) account with a token that has read access to `Qwen/Qwen2.5-7B-Instruct`

---

## Setup

### 1. Set environment variables

```bash
export LINODE_TOKEN="your-akamai-personal-access-token"
export TF_VAR_hf_token="hf-your-huggingface-token"
```

> Generate a Linode PAT at **Akamai Cloud → My Profile → API Tokens**.
> Scopes required: Kubernetes (Read/Write), Object Storage (Read/Write).

### 2. Create an Object Storage bucket for Terraform state

Log in to [Akamai Cloud](https://cloud.linode.com), go to **Object Storage**, and create a private bucket. Note the bucket name and region (e.g. `us-sea`).

Or use the API:

```bash
curl -H "Authorization: Bearer $LINODE_TOKEN" \
     -H "Content-Type: application/json" \
     -X POST https://api.linode.com/v4/object-storage/buckets \
     -d '{"label":"your-bucket-name","region":"us-sea","acl":"private"}'
```

### 3. Create scoped Object Storage access keys

In **Akamai Cloud → Object Storage → Access Keys**, create a key scoped to read/write on your bucket.

Or use the API (replace `your-bucket-name`):

```bash
curl -H "Authorization: Bearer $LINODE_TOKEN" \
     -H "Content-Type: application/json" \
     -X POST https://api.linode.com/v4/object-storage/keys \
     -d '{
       "label": "terraform-state-key",
       "bucket_access": [{
         "region": "us-sea",
         "bucket_name": "your-bucket-name",
         "permissions": "read_write"
       }]
     }'
```

Save the `access_key` and `secret_key` from the response — the secret is only shown once.

```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
```

### 4. Configure the backend

Edit `versions.tf` and update the `backend "s3"` block with your bucket name and endpoint:

```hcl
backend "s3" {
  bucket                      = "your-bucket-name"
  key                         = "llm-serving/terraform.tfstate"
  region                      = "us-east-1"
  endpoints                   = { s3 = "https://us-sea-1.linodeobjects.com" }
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  force_path_style            = true
}
```

> The `endpoints.s3` hostname follows the pattern `{region}.linodeobjects.com`.
> Find your region's endpoint under **Object Storage → Buckets** in the Cloud Manager.

### 5. Review and customise inputs

All tuneable values are in `environments/poc/terraform.tfvars`. The defaults deploy a 3-node GPU cluster with Qwen2.5-7B. Sensitive values (`hf_token`, `grafana_admin_password`) are never written to the tfvars file — pass them as environment variables:

```bash
export TF_VAR_hf_token="hf-..."
export TF_VAR_grafana_admin_password="your-grafana-password"  # optional, defaults to "changeme"
```

### 6. Deploy

```bash
# Initialise — downloads providers and connects to remote state
terraform init

# Preview what will be created
terraform plan -var-file=environments/poc/terraform.tfvars

# Stage 1 — create the LKE cluster
# KUBERNETES_MASTER is a one-time bootstrap workaround: the kubectl provider
# requires a host at init time, but the cluster doesn't exist yet.
KUBERNETES_MASTER=https://bootstrap.invalid \
  terraform apply -target=module.lke \
                  -var-file=environments/poc/terraform.tfvars

# Stage 2 — deploy platform operators and vLLM
terraform apply -var-file=environments/poc/terraform.tfvars
```

> Stage 1 takes ~3 minutes (LKE provisioning).
> Stage 2 takes ~10 minutes (Helm charts + vLLM model pull).

---

## Accessing the cluster

```bash
# Write kubeconfig to disk
terraform output -raw kubeconfig | base64 -d > kubeconfig.yaml

# Point kubectl at it
export KUBECONFIG=$(pwd)/kubeconfig.yaml

# Verify nodes are ready
kubectl get nodes -o wide
```

### Port-forward all services

```bash
bash scripts/port-forward.sh
```

| Service | URL | Credentials |
|---------|-----|-------------|
| vLLM API | http://localhost:8000 | — |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | admin / `terraform output -raw grafana_admin_password` |

### Quick API test

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen25-7b",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

---

## Tear down

```bash
terraform destroy -var-file=environments/poc/terraform.tfvars
```

This destroys the LKE cluster and all Kubernetes resources. The Object Storage bucket and its state file are **not** destroyed — delete them manually in the Cloud Manager if no longer needed.

---

## Repository layout

```
├── versions.tf                  provider pins + backend config
├── main.tf                      root module — wires lke → platform → llm-serving
├── variables.tf                 all inputs with defaults
├── outputs.tf                   cluster ID, kubeconfig, port-forward commands
├── .gitignore
├── modules/
│   ├── lke/                     LKE cluster + node pool + autoscaler
│   ├── platform/                kube-prometheus-stack, KEDA, GPU operator, DCGM
│   └── llm-serving/             vLLM, ServiceMonitor, ScaledObject, alert rules
├── environments/
│   └── poc/terraform.tfvars     PoC values — no secrets
└── scripts/
    └── port-forward.sh          starts vLLM, Prometheus, Grafana port-forwards
```

---

## Credentials reference

| Variable | Where to get it |
|----------|----------------|
| `LINODE_TOKEN` | Akamai Cloud → My Profile → API Tokens |
| `TF_VAR_hf_token` | huggingface.co → Settings → Access Tokens |
| `AWS_ACCESS_KEY_ID` | Akamai Cloud → Object Storage → Access Keys |
| `AWS_SECRET_ACCESS_KEY` | Same — only shown at creation time |
| `TF_VAR_grafana_admin_password` | Your choice — defaults to `changeme` |
