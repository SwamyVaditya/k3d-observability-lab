# Enterprise Observability & GitOps Platform

A production-grade, containerized observability and telemetry pipeline deployed on Kubernetes, managed via GitOps principles, and structured for high availability and low operational overhead.

## Architecture Overview
This project implements a fully automated observability stack mimicking enterprise cloud-native environments:
* **Log Aggregation:** Grafana Loki (Single-Binary mode) backed by MinIO object storage.
* **Distributed Tracing:** Grafana Tempo integrated with OTLP backends.
* **Telemetry Collection:** Grafana Alloy acting as a high-performance OpenTelemetry collector.
* **Metrics & Storage:** Prometheus remote-write capabilities combined with MinIO S3-compatible object storage.
* **GitOps Continuous Deployment:** Argo CD continuously synchronizing cluster state from this repository.
* **CI Validation:** GitHub Actions validating syntax, linting, and security policies on every push.

## Tech Stack
* **Orchestration:** Kubernetes (K3d for local development)
* **GitOps:** Argo CD
* **CI/CD:** GitHub Actions
* **Observability:** Grafana, Loki, Tempo, Alloy, Prometheus
* **Storage:** MinIO (S3-compatible distributed object storage)
* **IaC / Configuration:** Helm v3, YAML

## Repository Structure
* `/apps/monitoring/` - Helm values files for Loki, Tempo, MinIO, and Alloy.
* `/bootstrap/` - Argo CD App-of-Apps configuration definitions.
* `/.github/workflows/` - Automated CI pipelines for manifest validation.

## Getting Started (Local Deployment)
1. Create a local Kubernetes cluster using K3d:
   ```bash
   k3d cluster create mycluster --agents 1
