terraform {
  required_version = ">= 1.6.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }

  backend "s3" {
    bucket                      = "terraform-state-akamai-poc"
    key                         = "llm-serving/terraform.tfstate"
    region                      = "us-east-1"
    endpoints                   = { s3 = "https://us-sea-1.linodeobjects.com" }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    force_path_style            = true
    # Credentials: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env vars
  }
}

# Linode provider — token read from LINODE_TOKEN env var
provider "linode" {}

# Kubernetes + Helm + Kubectl providers wired to LKE kubeconfig
locals {
  # try() catches errors when the cluster doesn't exist yet (kubeconfig is null in state).
  # LKE uses token auth — no client cert/key in the kubeconfig.
  kubeconfig_decoded = try(base64decode(module.lke.kubeconfig), "")
  kubeconfig_parsed  = try(yamldecode(local.kubeconfig_decoded), null)
  kube_host          = try(local.kubeconfig_parsed.clusters[0].cluster.server, "https://bootstrap.invalid")
  kube_ca_cert       = try(base64decode(local.kubeconfig_parsed.clusters[0].cluster["certificate-authority-data"]), "")
  kube_token         = try(local.kubeconfig_parsed.users[0].user.token, "")
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca_cert
  token                  = local.kube_token
}

provider "helm" {
  kubernetes {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca_cert
    token                  = local.kube_token
  }
}

provider "kubectl" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca_cert
  token                  = local.kube_token
  load_config_file       = false
}
