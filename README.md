# End-to-End DevOps Platform on AWS

A production-grade DevOps platform built on AWS using:

| Component | Technology |
|-----------|------------|
| Infrastructure as Code | Terraform |
| Container Orchestration | AWS EKS (Kubernetes) |
| CI/CD | Jenkins |
| GitOps | ArgoCD |
| Monitoring | Prometheus + Alertmanager |
| Visualization | Grafana |
| Container Registry | AWS ECR |
| Networking | AWS VPC (custom) |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                        AWS Cloud                         │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │                   VPC (10.0.0.0/16)               │   │
│  │                                                   │   │
│  │  Public Subnets          Private Subnets          │   │
│  │  ┌─────────────┐         ┌──────────────────┐    │   │
│  │  │ NAT Gateway │         │   EKS Worker     │    │   │
│  │  │ Bastion Host│         │   Node Groups    │    │   │
│  │  │ ALB         │         │                  │    │   │
│  │  └─────────────┘         │  ┌────────────┐  │    │   │
│  │                          │  │  Jenkins   │  │    │   │
│  │                          │  │  ArgoCD    │  │    │   │
│  │                          │  │  Prometheus│  │    │   │
│  │                          │  │  Grafana   │  │    │   │
│  │                          │  │  App       │  │    │   │
│  │                          │  └────────────┘  │    │   │
│  │                          └──────────────────┘    │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│   ECR (Container Registry)    S3 (Terraform State)       │
└─────────────────────────────────────────────────────────┘
```

## CI/CD Flow

```
Developer Push
     │
     ▼
  GitHub
     │
     ▼ (webhook)
  Jenkins
     │
  ┌──┴──────────────────────────────────┐
  │  1. Checkout code                    │
  │  2. Run tests                        │
  │  3. Build Docker image               │
  │  4. Push to ECR                      │
  │  5. Update image tag in GitOps repo  │
  └──────────────────────────────────────┘
                    │
                    ▼ (git push to gitops repo)
                 ArgoCD
                    │
                    ▼ (sync)
               Kubernetes
                    │
              ┌─────┴──────┐
              │ Rolling     │
              │ Deployment  │
              └────────────┘
```

## Repository Structure

```
devops-platform/
├── terraform/                  # Infrastructure as Code
│   ├── modules/
│   │   ├── vpc/                # VPC, subnets, NAT, IGW
│   │   ├── eks/                # EKS cluster & node groups
│   │   ├── ecr/                # Container registries
│   │   └── iam/                # IAM roles & policies
│   ├── environments/
│   │   ├── dev/
│   │   └── prod/
│   └── backend.tf
├── kubernetes/                 # K8s base manifests
│   ├── namespaces/
│   ├── rbac/
│   └── storage/
├── jenkins/                    # Jenkins setup
│   ├── helm-values.yaml
│   ├── Dockerfile
│   └── pipelines/
├── argocd/                     # GitOps with ArgoCD
│   ├── install/
│   └── apps/
├── monitoring/                 # Prometheus + Grafana
│   ├── prometheus/
│   ├── grafana/
│   └── alertmanager/
├── app/                        # Sample application
│   ├── src/
│   ├── Dockerfile
│   ├── k8s/
│   └── helm/
└── scripts/                    # Helper automation scripts
```

## Quick Start

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.5.0
- kubectl >= 1.28
- Helm >= 3.12
- Docker
- Git

### 1. Provision Infrastructure

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply
```

### 2. Configure kubectl

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name devops-platform-dev
```

### 3. Bootstrap Kubernetes

```bash
./scripts/bootstrap.sh
```

### 4. Access Services

| Service    | Command                                              |
|------------|------------------------------------------------------|
| Jenkins    | `kubectl port-forward svc/jenkins 8080:8080 -n jenkins` |
| ArgoCD     | `kubectl port-forward svc/argocd-server 8443:443 -n argocd` |
| Grafana    | `kubectl port-forward svc/grafana 3000:3000 -n monitoring` |
| Prometheus | `kubectl port-forward svc/prometheus 9090:9090 -n monitoring` |

### 5. Get Initial Passwords

```bash
# ArgoCD admin password
kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 -d

# Jenkins admin password
kubectl exec -n jenkins \
  $(kubectl get pod -n jenkins -l app.kubernetes.io/name=jenkins -o jsonpath="{.items[0].metadata.name}") \
  -- cat /var/jenkins_home/secrets/initialAdminPassword

# Grafana admin password
kubectl get secret grafana \
  -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d
```

## Environment Variables

Copy `.env.example` to `.env` and fill in values before running scripts.

## Contributing

1. Fork the repo
2. Create a feature branch
3. Open a pull request — Jenkins will run the pipeline automatically
