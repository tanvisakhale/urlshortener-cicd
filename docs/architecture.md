# Architecture

## Overview

The URL Shortener is a FastAPI service backed by PostgreSQL, containerized
with Docker, orchestrated with Kubernetes (Amazon EKS), and provisioned
with Terraform. GitHub Actions handles CI/CD, deploying first to a
staging environment and then, after manual approval, to production.

## Request Flow

```
Client
  │
  ▼
Kubernetes Service (ClusterIP)
  │
  ▼
url-shortener Pod(s) (FastAPI + Uvicorn)
  │
  ▼
Amazon RDS PostgreSQL (private subnet, not publicly accessible)
```

## Deployment Pipeline

```
Developer
   ↓
GitHub
   ↓
GitHub Actions
   ├── Run Pytest
   ├── Lint (ruff)
   ├── Docker Build
   └── Trivy Security Scan
          ↓
        AWS ECR  (immutable, commit-SHA tagged images)
          ↓
        AWS EKS
     ┌────┴────┐
     │         │
  Staging   Production   (production requires manual approval)
     │         │
     └────┬────┘
          ↓
      FastAPI Pods
          ↓
   PostgreSQL (Amazon RDS)
```

## AWS Infrastructure

```
AWS Account
│
├── VPC (10.0.0.0/16)
│   ├── Public Subnets   -> NAT Gateway
│   └── Private Subnets  -> EKS nodes, RDS
│
├── EKS
│   └── Managed node group running the application
│
├── ECR
│   └── url-shortener image repository (scan-on-push enabled)
│
├── RDS PostgreSQL
│   └── Private subnet only, security group scoped to EKS node SG
│
└── CloudWatch
    └── Container Insights / application logs
```

## External Access

```
Internet
   │
   ▼
AWS Network Load Balancer (provisioned by the Service annotation below)
   │
   ▼
Kubernetes Service "url-shortener" (type: LoadBalancer)
   │
   ▼
FastAPI Pods
```

`k8s/base/service.yaml` is `type: LoadBalancer` with
`service.beta.kubernetes.io/aws-load-balancer-type: nlb`. This was chosen
over a full Ingress + ALB Controller setup because it's simpler to
explain and verify for a project at this scope (one Service, one NLB, no
extra controller's RBAC/IAM to reason about). The trade-off: no
path-based routing, TLS termination, or WAF integration -- a real
production API would likely prefer an ALB via the AWS Load Balancer
Controller for those features.

**Honest prerequisite:** on EKS 1.23+, a `type: LoadBalancer` Service
does **not** provision anything by itself -- the in-tree AWS cloud
provider that used to do this was removed. You must install the [AWS
Load Balancer
Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
once per cluster (via Helm) before this Service will actually get an
NLB. This is a one-time cluster bootstrap step, not something this
repo's Terraform currently automates -- see `README.md` for the exact
command. Until that controller is installed, the Service will stay in
`<pending>` for its external IP/hostname indefinitely, and that's
expected, not a bug in this repo.

## Monitoring & Observability

```
EKS Pods --(/metrics)--> Prometheus --> Grafana Dashboard
EKS Pods --(stdout JSON logs)--> Fluent Bit / CloudWatch Logs
```

## Authentication for CI/CD

GitHub Actions never holds long-lived AWS access keys. Instead:

```
GitHub Actions workflow
        ↓ (OIDC token)
AWS IAM OIDC Provider
        ↓ (AssumeRoleWithWebIdentity, trust policy scoped to this repo)
IAM Role "url-shortener-github-actions" (least privilege: ECR push + EKS describe)
        ↓
ECR push / kubectl against EKS
```

## Design Trade-offs (honest limitations)

- A single NAT Gateway is used to keep AWS costs low for a demo/portfolio
  project. A real production setup would use one NAT Gateway per
  availability zone for higher availability.
- `db.t3.micro` and `t3.medium` node instances are minimum-viable sizes
  chosen for cost, not for real production load.
- Multi-AZ RDS and a 7-day backup window are only enabled for the
  `production` environment variable, not `staging`.
- This document describes the intended architecture. Whether it has
  actually been deployed to a live AWS account depends on whether the
  Terraform in `terraform/` has been applied — see `README.md` for
  status and how to verify.
