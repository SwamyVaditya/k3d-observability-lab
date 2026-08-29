terraform {
  required_version = ">= 1.5.0"
  required_providers {
  #  kubectl = { source = "gavinbunney/kubectl", version = "~> 1.14.0" }
    helm = { source = "hashicorp/helm", version = "~> 2.12.0" }
  }
}


resource "null_resource" "k3d_cluster" {
  triggers = {
    config_hash = filemd5("../clusters/observability-cluster.yaml")
    # change this to force recreate: recreation = timestamp()
  }

  # 1. Provision Cluster via Local Exec (Cleanest wrapper for K3d in Terraform)
  provisioner "local-exec" {
    command = <<EOT
      if! k3d cluster list | grep -q observability-cluster; then
        k3d cluster create --config../clusters/observability-cluster.yaml --timeout 300s
      else
        echo "Cluster already exists, skipping create"
      fi
    EOT
  }

  provisioner "local-exec" {
    when = destroy
    command = "k3d cluster delete observability-cluster || true"
  }
}

# 2. Deploy Argo CD using the official Helm chart
provider "helm" {
  kubernetes {
    config_path = pathexpand("~/.kube/config") # Connects to the newly created K3d cluster
    config_context = "k3d-observability-cluster"
  }
}


# Automatically add and update required Helm repositories before deploying charts
# Cross-platform: single line with && works on Windows cmd and Linux/macOS bash
resource "null_resource" "helm_repositories" {
  depends_on = [null_resource.k3d_cluster]

  provisioner "local-exec" {
    command = "helm repo add argo https://argoproj.github.io/argo-helm --force-update && helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets --force-update && helm repo add grafana https://grafana.github.io/helm-charts --force-update && helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update && helm repo add minio https://charts.min.io --force-update && helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update && helm repo update"
  }
}

# Argo CD Helm Release configured to wait for repository initialization
resource "helm_release" "argocd" {
  name = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart = "argo-cd"
  namespace = "argocd"
  create_namespace = true
  version = "7.3.0" # Use a stable recent chart version
  timeout = 600
  # Automatically configure server parameters declaratively
  # No secret.argocdServerAdminPassword - auto-generated for local lab hygiene
  # Prod EKS uses OIDC SSO, not static admin password
  values = [<<-EOT
      configs:
        params:
          server.insecure: "true" # LOCAL LAB ONLY - Traefik terminates HTTP for *.local, no TLS needed locally. EKS uses ALB + ACM + HTTPS.
    EOT
  ]

  depends_on = [null_resource.helm_repositories]
}


# NEW: Wait for ArgoCD CRDs to be established before applying Application
resource "null_resource" "wait_for_argocd_crds" {
  provisioner "local-exec" {
    command = "kubectl wait --for=condition=established --timeout=180s crd/applications.argoproj.io crd/appprojects.argoproj.io"
  }
  depends_on = [helm_release.argocd]
}

# 3. Apply the Root GitOps Application
#provider "kubectl" {
#  config_path = pathexpand("~/.kube/config")
#  config_context = "k3d-observability-cluster"
#  load_config_file = true # force reload after k3d writes it
#}
#
#resource "kubectl_manifest" "root_app" {
#  yaml_body = file("${path.module}/../argocd/root-app.yaml")
#  wait = true # wait for resource to be ready
#  depends_on = [null_resource.wait_for_argocd_crds]
#}


# 3. Apply the Root GitOps Application
resource "null_resource" "root_app" {
  depends_on = [null_resource.wait_for_argocd_crds]

  provisioner "local-exec" {
    command = "kubectl apply -f ../argocd/root-app.yaml"
  }

  provisioner "local-exec" {
    when = destroy
    command = "kubectl delete -f ../argocd/root-app.yaml --ignore-not-found=true || true"
  }
}

# 4. Deploy Sealed Secrets Controller using Helm
resource "helm_release" "sealed_secrets" {
  name = "sealed-secrets"
  repository = "https://bitnami.github.io/sealed-secrets"
  chart = "sealed-secrets"
  version = "2.16.1"
  namespace = "kube-system"
  timeout = 300
  depends_on = [null_resource.wait_for_argocd_crds] # don't run in parallel with argocd
}
