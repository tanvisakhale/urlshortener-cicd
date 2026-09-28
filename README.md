# Cloud-Native URL Shortener — CI/CD, SRE & Automated Cloud Deployment Platform

A production-style URL shortener built to demonstrate the skills expected
of an entry-level **SRE / DevOps / Cloud Engineer**: application
development, testing, containerization, Kubernetes, Infrastructure as
Code, CI/CD, monitoring, alerting, incident response, and cloud security.

> **Status note:** The application code, tests, Docker, Kubernetes
> manifests, Terraform, CI/CD pipelines, and monitoring config in this
> repo were built and validated in a sandboxed environment without
> Docker, Kubernetes, Terraform, or AWS access available. The Python
> test suite (8 tests) and `ruff` lint were actually run and pass.
> Kubernetes YAML and the Grafana/Prometheus/GitHub Actions configs were
> validated for correct syntax. The Dockerfile and Terraform have **not**
> been actually built/applied/deployed against real infrastructure —
> do that in your own environment, and update this note with what you
> actually observed, before treating this as deployed. No uptime,
> performance, or deployment claims below are fabricated; where
> something is a target/design rather than a measured result, it's
> labeled as such.

---

## 1. Project Overview

The service lets a client submit a long URL and receive a short code
that redirects back to the original. Beyond the core feature, the
project is built out as a full platform: containerized, deployed to
Kubernetes on AWS EKS via Terraform, with CI/CD, Prometheus/Grafana
monitoring, alerting, and documented incident response.

## 2. Architecture

See [`docs/architecture.md`](docs/architecture.md) for diagrams of the
request flow, deployment pipeline, AWS infrastructure, external access
path, and CI/CD authentication model.

## 3. Features

- `POST /shorten` — create a short URL from a long one (base URL taken
  from the `BASE_SHORT_URL` env var, never hard-coded)
- `GET /{short_code}` — redirect to the original URL
- `GET /health` — lightweight liveness/readiness endpoint
- `GET /metrics` — Prometheus-format metrics
- Structured JSON logging with request IDs
- Prometheus counters, histograms, and gauges for request volume,
  latency, errors, and business metrics
- Kubernetes deployment with liveness/readiness probes, resource
  limits, and horizontal pod autoscaling
- Staging and production environments (separate namespaces, separate
  EKS clusters) via Kustomize overlays
- External access via a Kubernetes `LoadBalancer` Service (AWS NLB)
- Terraform-provisioned AWS infrastructure (VPC, EKS, ECR, RDS, IAM),
  with the RDS master password managed natively by AWS (never in
  Terraform state)
- GitHub Actions CI/CD with OIDC-based, least-privilege, per-environment
  AWS auth (no long-lived keys, no cluster-admin)
- Grafana dashboard, Prometheus alert rules (with utilization-correct
  CPU alerting), SLI/SLO documentation
- Incident response runbook (10 incident types) and a documented,
  deliberately-manual rollback procedure

## 4. Technology Stack

| Layer            | Technology                          |
|-------------------|--------------------------------------|
| Application       | Python, FastAPI, Pydantic, Uvicorn   |
| Database          | PostgreSQL (RDS in AWS, Docker locally) |
| Testing           | Pytest, httpx (FastAPI TestClient), ruff |
| Containerization  | Docker, Docker Compose               |
| Orchestration     | Kubernetes (Amazon EKS), Kustomize   |
| IaC               | Terraform                            |
| CI/CD             | GitHub Actions, OIDC                 |
| Monitoring        | Prometheus, Grafana                  |
| Logging           | Structured JSON → CloudWatch         |

## 5. Local Setup (without Docker)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Uses a local SQLite file automatically if DATABASE_HOST isn't set,
# and defaults BASE_SHORT_URL to http://localhost:8000 if unset.
uvicorn app.main:app --reload

# In another terminal:
pytest -v
ruff check app tests
```

## 6. Docker Setup

```bash
docker compose up --build
```

This starts PostgreSQL and the FastAPI app together. The app will be
available at `http://localhost:8000`; try:

```bash
curl -X POST http://localhost:8000/shorten -H "Content-Type: application/json" \
  -d '{"url": "https://example.com"}'

curl http://localhost:8000/health
curl http://localhost:8000/metrics
```

To build the image standalone:

```bash
docker build -t url-shortener:local .
docker run -p 8000:8000 \
  -e DATABASE_HOST=<host> \
  -e BASE_SHORT_URL=http://localhost:8000 \
  url-shortener:local
```

## 7. PostgreSQL Setup

- **Local:** `docker-compose.yml` runs `postgres:16-alpine` with a named
  volume; the app connects using `DATABASE_HOST=db` (the Compose service
  name).
- **AWS:** Terraform provisions an RDS PostgreSQL instance per
  environment (`terraform/rds.tf`), private-subnet-only, with the
  master password generated and rotated by AWS itself (see Security
  section below) rather than by Terraform.
- The app always reads `DATABASE_HOST/PORT/NAME/USER/PASSWORD` from
  environment variables (`app/database.py`); if `DATABASE_HOST` is
  unset, it falls back to a local SQLite file — useful for quick local
  runs and the test suite, never used in staging/production.

## 8. Kubernetes Deployment

Requires a running cluster (e.g. the EKS cluster from Terraform) and
`kubectl` + `kustomize` configured against it.

**One-time cluster bootstrap** (per cluster, not something Terraform
here automates yet): the Service in `k8s/base/service.yaml` is
`type: LoadBalancer`, which on modern EKS requires the **AWS Load
Balancer Controller** to be installed first:

```bash
# Roughly (see the controller's own docs for the exact current command,
# including its IAM policy / IRSA setup, which isn't included in this
# repo's Terraform yet):
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --set clusterName=<your-cluster-name>
```

Then deploy the app:

```bash
# Preview the rendered manifests first (also creates the namespace)
kubectl kustomize k8s/overlays/staging

# Apply -- this creates the "staging" namespace (k8s/namespaces/staging.yaml)
# AND the app resources in the same call, so it works against a cluster
# where the namespace doesn't exist yet.
kubectl apply -k k8s/overlays/staging
kubectl rollout status deployment/url-shortener -n staging

# Production (same pattern, separate namespace + separate cluster)
kubectl apply -k k8s/overlays/production
```

Verify probes, autoscaling, and external access:

```bash
kubectl get pods -n staging
kubectl get hpa -n staging
kubectl describe hpa url-shortener-hpa -n staging
kubectl get svc url-shortener -n staging   # EXTERNAL-IP/hostname once the LB Controller has provisioned the NLB
```

> The Secret in `k8s/base/secret.yaml` contains placeholder values only
> and is not applied as-is in staging/production — see the comments in
> that file and in `.github/workflows/cd.yml` for how the CD pipeline
> populates real values (RDS endpoint + AWS-managed password) at deploy
> time, and how `BASE_SHORT_URL` gets set once the NLB has a hostname.

## 9. AWS Architecture

See [`docs/architecture.md`](docs/architecture.md) — VPC with
public/private subnets, EKS for compute, ECR for images, RDS PostgreSQL
in a private subnet, an NLB for external access, CloudWatch for logs.

## 10. Terraform Setup

This config is applied **once per environment** (each with its own
state — e.g. via `terraform workspace` or separate backends). Two
resources are AWS-account-global (the GitHub OIDC provider and the
shared ECR repository — one repo, since CI builds one image and
promotes the same tag from staging to production), so they're only
created on the *first* environment you apply:

```bash
cd terraform
terraform init

# First environment (creates the shared OIDC provider + ECR repo too):
cp staging.tfvars.example staging.tfvars   # fill in real values
terraform validate
terraform plan -var-file=staging.tfvars
terraform apply -var-file=staging.tfvars

# Second environment (reuses the shared resources via data source):
cp production.tfvars.example production.tfvars
terraform plan -var-file=production.tfvars -var manage_shared_resources=false
terraform apply -var-file=production.tfvars -var manage_shared_resources=false
```

`*.tfvars` files are gitignored (only the `.example` versions are
committed). The AWS credentials Terraform uses locally are your own
(e.g. via `aws configure` or SSO) — separate from the OIDC roles
Terraform provisions for GitHub Actions.

After applying, grab the two role ARNs for GitHub secrets (below):

```bash
terraform output github_actions_role_arn
```

## 11. CI/CD Pipeline

- **CI** (`.github/workflows/ci.yml`): on every push/PR — install deps,
  lint (`ruff`), run Pytest, build the Docker image, scan it with
  Trivy, and run `pip-audit`. The pipeline fails if tests, lint, or the
  Trivy scan (on CRITICAL/HIGH) fail.
- **CD** (`.github/workflows/cd.yml`): on push to `main` — re-run tests,
  build and scan the image, push to the shared ECR repo with an
  immutable commit-SHA tag, deploy to staging (fetching the real RDS
  endpoint + AWS-managed password and writing them into the Kubernetes
  Secret, then discovering the NLB hostname and setting
  `BASE_SHORT_URL`), wait for rollout, run a smoke test against
  `/health`, then require manual approval (via a GitHub Environment)
  before repeating the same deploy steps against production. If the
  production deploy or its health check fails, the job fails loudly
  with the manual rollback command printed — see `RUNBOOK.md`
  "Rollback"; this is deliberately **not** automatic (see Security
  Known Limitations for why).

Required repository secrets:
- `AWS_GITHUB_ACTIONS_ROLE_ARN_STAGING` — from the staging Terraform
  apply's `github_actions_role_arn` output.
- `AWS_GITHUB_ACTIONS_ROLE_ARN_PRODUCTION` — from the production
  Terraform apply's `github_actions_role_arn` output.

## 12. Monitoring

Prometheus scrapes `/metrics` (see `monitoring/prometheus/prometheus.yml`).
Import `monitoring/grafana/dashboard.json` into Grafana for a dashboard
covering availability, request rate, error rate, latency percentiles,
CPU/memory, pod count, and URLs-shortened count. Panel queries are kept
in sync with the metric names actually emitted by `app/metrics.py`.

## 13. Alerting

Alert rules live in `monitoring/alerts/alerts.yml`, each documented
in-file with its condition, threshold, duration, and reasoning:

- **ApplicationUnavailable** — health scrape failing for 2+ minutes
- **HighErrorRate** — 5xx rate > 5% for 5 minutes
- **HighLatency** — p95 latency > 500ms for 5 minutes
- **HighCPUUsage** — CPU used ÷ CPU *requested* > 80% for 5 minutes
  (not a raw comparison of the cumulative usage counter against a fixed
  number — see the file for why that would be meaningless; requires
  kube-state-metrics)

## 14. SLI / SLO

See [`docs/SRE.md`](docs/SRE.md) for definitions of availability,
latency, and error-rate SLIs, example SLO targets, and how the error
budget is calculated. These are **demonstration targets**, not measured
production history.

## 15. HPA

`k8s/base/hpa.yaml`: min 2 / max 5 replicas, target 70% CPU utilization
against the container's requested CPU (`k8s/base/deployment.yaml`
`resources.requests.cpu: 100m`, which is what makes the percentage
meaningful in the first place).

```bash
kubectl get hpa -n <namespace>
kubectl describe hpa url-shortener-hpa -n <namespace>
```

To actually verify scaling (not just assume it works): generate
sustained load (e.g. `hey`/`ab`/`k6` against `/shorten`) and watch
`kubectl get hpa -w` — replica count should climb toward 5 as CPU
utilization crosses 70%, then settle back down a couple of minutes
after load stops. This has not been load-tested in this project yet;
treat it as configured-but-unverified until you've run that yourself.

## 16. Incident Response

See [`RUNBOOK.md`](RUNBOOK.md) for step-by-step procedures covering all
10 required incident types: `CrashLoopBackOff`, readiness probe
failure, liveness probe failure, high CPU, high memory, high 5xx rate,
high latency, database connection failure, deployment rollout failure,
and rollback.

## 17. Rollback

```bash
kubectl rollout history deployment/url-shortener -n <namespace>
kubectl rollout undo deployment/url-shortener -n <namespace>
kubectl rollout status deployment/url-shortener -n <namespace>
```

Because images are tagged with the immutable commit SHA, rollback
always returns to a known exact build. This is a **manual, documented**
step (see `RUNBOOK.md` incident "Rollback") — the CD pipeline does not
automatically run `rollout undo` on failure; it fails the job and
prints these exact commands instead, since an untested automatic
rollback path is itself a risk this project chooses not to take on.

## 18. Security

See [`SECURITY.md`](SECURITY.md) for the full list of practices
(non-root containers, OIDC auth with per-environment least-privilege
IAM, the AWS-managed RDS password mechanism and exactly what it does
and doesn't put in Terraform state, private RDS, image scanning) and
honestly-stated limitations.

## 19. Known Limitations

- Terraform and the Dockerfile have not been run against real
  infrastructure from this environment (see Status note above).
- The AWS Load Balancer Controller install is a manual one-time step,
  not yet automated by this repo's Terraform.
- HPA scaling behavior is configured but not load-tested (see §15).
- `pip-audit` findings are currently non-blocking in CI.
- No WAF/rate-limiting in front of the public endpoint yet.
- See `SECURITY.md` for the full list.

## 20. Future Improvements

- Automate the AWS Load Balancer Controller install via Terraform
  (`helm_release` provider) instead of a manual step
- Add a WAF / rate-limiting layer in front of the public endpoint
  (likely via migrating to an ALB + AWS Load Balancer Controller
  Ingress instead of the current NLB Service)
- Move to a per-AZ NAT Gateway setup for higher availability
- Add distributed tracing (OpenTelemetry) alongside metrics and logs
- Add automated load testing (k6/Locust) as a CI/CD gate, and use it to
  actually verify HPA scaling behavior (§15)
- Once automatic rollback has been tested end-to-end, consider
  re-introducing it as an opt-in CD step
- Add a custom URL/vanity-code feature and expiry support

## Project Structure

```
urlshortener-cicd/
├── app/                  # FastAPI application
├── tests/                # Pytest suite
├── Dockerfile, docker-compose.yml
├── k8s/base/, k8s/namespaces/, k8s/overlays/{staging,production}/
├── terraform/
├── monitoring/{prometheus,grafana,alerts}/
├── .github/workflows/{ci,cd}.yml
├── docs/{architecture,SRE}.md
├── RUNBOOK.md
├── SECURITY.md
└── README.md
```
