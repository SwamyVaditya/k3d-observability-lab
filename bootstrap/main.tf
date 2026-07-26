terraform {
  required_version = ">= 1.5.0"
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12.0"
    }
  }
}

# 1. Provision Cluster via Local Exec (Cleanest wrapper for K3d in Terraform)
resource "null_resource" "k3d_cluster" {
  provisioner "local-exec" {
    command = "k3d cluster create --config ../clusters/observability-cluster.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete observability-cluster"
  }
}

# 2. Deploy Argo CD using the official Helm chart
provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config" # Connects to the newly created K3d cluster
    config_context = "k3d-observability-cluster"
  }
}


# Automatically add and update required Helm repositories before deploying charts
resource "null_resource" "helm_repositories" {
  provisioner "local-exec" {
    command = <<-EOT
      helm repo add argo https://argoproj.github.io/argo-helm
      helm repo add grafana https://grafana.github.io/helm-charts
      helm repo add minio https://charts.min.io
      helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
      helm repo update
    EOT
  }

  depends_on = [null_resource.k3d_cluster]
}

# Argo CD Helm Release configured to wait for repository initialization
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.3.0" # Use a stable recent chart version

  # Automatically configure server parameters declaratively
  values = [
    <<-EOT
    configs:
      params:
        server.insecure: "true"
      secret:
        # Replace with your pre-generated bcrypt hash for your chosen password
        argocdServerAdminPassword: "$2a$12$PAflLdjcvwbMxGd11Z.3kO8ruAYRC/h6W85GMFE21O49QgY8HQEO."
    EOT
  ]

  depends_on = [null_resource.helm_repositories]
}


# 3. Apply the Root GitOps Application
provider "kubectl" {
  config_path    = "~/.kube/config"
  config_context = "k3d-observability-cluster"
}

resource "kubectl_manifest" "root_app" {
  yaml_body  = file("${path.module}/../argocd/root-app.yaml")
  depends_on = [helm_release.argocd]
}
