terraform {
  required_version = ">= 1.6.0"

  # Local state is intentional for this single-machine k3d lab.
  # Production EKS would use a remote backend such as S3 with encryption
  # and state locking.
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

###############################################################################
# k3d cluster
#
# The cluster definition is maintained in:
#   ../clusters/observability-cluster.yaml
#
# The configuration hash causes Terraform to replace the cluster when the
# k3d definition changes.
#
# This bootstrap is intended to run from WSL2/Linux because k3d, kubectl,
# Helm, and the supporting shell commands are Linux-oriented tools.
###############################################################################

resource "null_resource" "k3d_cluster" {
  triggers = {
    cluster_config_hash = filemd5(
      "${path.module}/../clusters/observability-cluster.yaml"
    )
  }

  provisioner "local-exec" {
    command = "k3d cluster create --config ${path.module}/../clusters/observability-cluster.yaml --timeout 300s"
  }

  provisioner "local-exec" {
    when       = destroy
    command    = "k3d cluster delete observability-cluster"
    on_failure = continue
  }
}

###############################################################################
# Wait for Kubernetes
#
# Prevents Helm/Argo bootstrap from racing the newly-created k3d cluster.
###############################################################################

resource "null_resource" "wait_for_cluster" {
  depends_on = [null_resource.k3d_cluster]

  provisioner "local-exec" {
    command = "kubectl wait --for=condition=Ready nodes --all --timeout=180s"
  }
}

###############################################################################
# Helm repositories
#
# Repository setup is local bootstrap convenience only.
# Helm releases below use explicit repository URLs and pinned chart versions.
###############################################################################

resource "null_resource" "helm_repositories" {
  depends_on = [null_resource.wait_for_cluster]

  provisioner "local-exec" {
    command = <<-EOT
      helm repo add argo https://argoproj.github.io/argo-helm || true
      helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets || true
      helm repo add grafana https://grafana.github.io/helm-charts || true
      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
      helm repo add minio https://charts.min.io || true
      helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || true
      helm repo update
    EOT
  }
}

###############################################################################
# Argo CD
#
# Argo CD is the GitOps control plane for the observability stack.
#
# server.insecure=true is intentional for this local-only lab. Traefik
# provides local HTTP routing. Production EKS would use HTTPS/TLS and an
# appropriate identity provider/SSO configuration.
###############################################################################

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.3.0"
  namespace        = "argocd"
  create_namespace = true

  timeout = 600
  wait    = true

  values = [
    <<-EOT
      configs:
        params:
          server.insecure: "true"
    EOT
  ]

  depends_on = [
    null_resource.helm_repositories
  ]
}

###############################################################################
# Wait for Argo CD CRDs and server
#
# CRDs must exist before AppProject/Application resources are applied.
# The server Deployment is also waited on so the GitOps control plane is
# actually ready before the root Application is submitted.
###############################################################################

resource "null_resource" "wait_for_argocd" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl wait \
        --for=condition=Established \
        --timeout=180s \
        crd/applications.argoproj.io \
        crd/appprojects.argoproj.io

      kubectl rollout status \
        deployment/argocd-server \
        -n argocd \
        --timeout=180s
    EOT
  }
}

###############################################################################
# Sealed Secrets
#
# Installed before the GitOps applications are reconciled so that SealedSecret
# resources in Git can be decrypted by the controller during bootstrap.
###############################################################################

resource "helm_release" "sealed_secrets" {
  name       = "sealed-secrets"
  repository = "https://bitnami.github.io/sealed-secrets"
  chart      = "sealed-secrets"
  version    = "2.16.1"
  namespace  = "kube-system"

  timeout = 300
  wait    = true

  depends_on = [
    null_resource.wait_for_cluster
  ]
}

###############################################################################
# Argo CD AppProject
#
# This project restricts the GitOps applications to the intended repository
# and cluster/namespace scope rather than using Argo CD's unrestricted
# default project.
###############################################################################

resource "null_resource" "argocd_project" {
  depends_on = [
    null_resource.wait_for_argocd
  ]

  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/../argocd/projects/observability-project.yaml"
  }

  provisioner "local-exec" {
    when       = destroy
    command    = "kubectl delete -f ${path.module}/../argocd/projects/observability-project.yaml --ignore-not-found=true"
    on_failure = continue
  }
}

###############################################################################
# Root GitOps Application
#
# The root Application bootstraps the App-of-Apps hierarchy.
# Argo CD then becomes responsible for managing the remaining Kubernetes
# resources from Git.
###############################################################################

resource "null_resource" "root_app" {
  depends_on = [
    null_resource.argocd_project,
    helm_release.sealed_secrets
  ]

  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/../argocd/root-app.yaml"
  }

  provisioner "local-exec" {
    when       = destroy
    command    = "kubectl delete -f ${path.module}/../argocd/root-app.yaml --ignore-not-found=true"
    on_failure = continue
  }
}