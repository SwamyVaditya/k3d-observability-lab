## k3d-observability-lab

A production-grade, local GitOps observability lab running on **K3d (Kubernetes in Docker)**, orchestrated declaratively via **Terraform** and continuously synced using **Argo CD (App-of-Apps pattern)**.

---

### Architecture Overview

This repository demonstrates enterprise cloud-native patterns for local development, testing infrastructure automation, and validating full-stack observability pipelines before pushing to cloud environments (AWS EKS).

```text
k3d-observability-lab/
├── .github/
│   └── workflows/
│       └── ci.yaml                   # GitHub Actions CI/CD pipeline
├── clusters/
│   └── observability-cluster.yaml    # K3d multi-node cluster definition
├── bootstrap/                        
│   ├── main.tf                       # Terraform automated cluster & Argo CD provisioner
│   └── argocd-install.yaml           # Upstream Argo CD installation manifests
├── argocd/                           
│   └── root-app.yaml                 # Argo CD App-of-Apps root application manifest
└── apps/                             
    └── monitoring/                   # Helm values and configurations for observability stack
        ├── minio-values.yaml
        ├── loki-values.yaml
        ├── tempo-values.yaml
        └── alloy-values.yaml

```

This project implements a fully automated observability stack mimicking enterprise cloud-native environments:
* **Log Aggregation:** Grafana Loki (Single-Binary mode) backed by MinIO object storage.
* **Distributed Tracing:** Grafana Tempo integrated with OTLP backends.
* **Telemetry Collection:** Grafana Alloy acting as a high-performance OpenTelemetry collector.
* **Metrics & Storage:** Prometheus remote-write capabilities combined with MinIO S3-compatible object storage.
* **GitOps Continuous Deployment:** Argo CD continuously synchronizing cluster state from this repository.
* **CI Validation:** GitHub Actions validating syntax, linting, and security policies on every push.

---

### Technology Stack

* **Orchestration:** Kubernetes via **K3d** (1 Server, 2 Agents, custom load balancer port mappings).
* **Infrastructure as Code (IaC):** **Terraform** (`null_resource`, `helm`, and `kubectl` providers).
* **Continuous Delivery (CD):** **Argo CD** utilizing the **App-of-Apps** pattern.
* **Observability Components:**
* **MinIO:** S3-compatible object storage backend.
* **Grafana Loki:** Log aggregation and storage.
* **Grafana Tempo:** Distributed tracing backend.
* **Grafana Alloy:** OpenTelemetry collector and telemetry agent.



---

### Quick Start Guide

#### Prerequisites

Ensure you have the following installed on your Windows/Linux/macOS development environment:

* [Docker Desktop](https://www.docker.com/) (running)
* [K3d](https://k3d.io/)
* [Terraform](https://www.terraform.io/)
* [Helm](https://helm.sh/)
* [Kubectl](https://kubernetes.io/docs/tasks/tools/)
* [Argo CD CLI](https://www.google.com/search?q=https://argo-cd.readthedocs.io/en/stable/cli_usage/)

#### 1. Bootstrap the Environment via Terraform

Navigate to the `bootstrap/` directory and execute Terraform to spin up the local K3d cluster, deploy Argo CD via Helm (pre-configured for insecure local HTTP access), and apply the Root GitOps application:

```bash
cd bootstrap
terraform init
terraform apply

```

#### 2. Access the Argo CD UI

Forward the Argo CD server port to your local machine:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80

```

Open your browser and navigate to `https://localhost:8080`. Log in using:

* **Username:** `admin`
* **Password:** `test1234` *(or the deterministic password defined in your Terraform configuration)*

Alternatively, log in via the Argo CD CLI:

```bash
argocd login localhost:8080 --username admin --password test1234 --insecure
argocd app list

```

---

### GitOps Workflow

1. Modify any application Helm values file under `apps/monitoring/`.
2. Commit and push your changes to your remote GitHub repository (`main` branch).
3. Argo CD automatically detects the drift via its automated sync policy (`prune: true`, `selfHeal: true`) and 
   rolls out the changes live into your local K3d cluster without manual `helm upgrade` commands.

