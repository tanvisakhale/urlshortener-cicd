# SECURITY.md

## Security Practices Implemented

### Container Security
- The Docker image runs as a **non-root user** (`appuser`, uid 1000).
- Multi-stage build keeps the runtime image minimal (no build toolchain
  in the final image).
- A Docker `HEALTHCHECK` is defined so unhealthy containers are
  detectable outside of Kubernetes too.
- Images are scanned with **Trivy** in CI; both the CI and CD pipelines
  fail the build on CRITICAL or HIGH severity vulnerabilities.
- **ECR image scanning** (`scan_on_push`) is enabled via Terraform as a
  second layer of scanning at push time.
- Images are tagged with the **immutable git commit SHA**, never
  `:latest` — every running image is traceable to an exact commit.

### Secrets Management

**Database password — how it actually works, precisely:**

We use RDS's native `manage_master_user_password = true` feature
(`terraform/rds.tf`) instead of generating the password with
Terraform's `random_password` resource. This is a deliberate fix: an
earlier version of this project used `random_password` and passed the
result directly into `aws_db_instance.password`, which meant the
plaintext password **was written into Terraform state** — state is not
a secrets store, and describing that setup as "the password is never
stored in Terraform" would have been false.

With `manage_master_user_password = true`:
- AWS itself generates the password and stores it in a Secrets Manager
  secret **that AWS manages**.
- Terraform never reads or writes the plaintext value, so it never
  appears in `.tfstate`.
- The only place that ever reads the plaintext is the CD pipeline,
  which calls `aws secretsmanager get-secret-value` (scoped via IAM to
  exactly that one secret ARN — see `terraform/iam.tf` statement
  `ReadDBMasterPassword`) and writes it straight into a Kubernetes
  Secret. It is never echoed to workflow logs.

**Everything else:**
- No credentials are hard-coded anywhere in the codebase.
- Database configuration is injected via environment variables, backed
  by a **Kubernetes Secret** in-cluster, itself populated at deploy
  time (not committed) — see `k8s/base/secret.yaml` for the exact
  mechanism and why the file in this repo contains fake placeholder
  values.
- `.gitignore` excludes `*.tfvars` (except the committed
  `*.tfvars.example` files), `*.tfstate`, `.env` files, and other
  locally-generated secret material.
- Structured logs explicitly exclude passwords, DB credentials, and AWS
  credentials (see `app/logging_config.py` field list); the CD steps
  that handle the DB password do not `set -x` or `echo` it.

### AWS Authentication & Authorization
- CI/CD uses **GitHub Actions OIDC** to assume an AWS IAM role — **no
  long-lived AWS access keys** are stored in GitHub secrets.
- There are **two separate IAM roles**, one per environment
  (`url-shortener-staging-github-actions`,
  `url-shortener-production-github-actions`), each trust-scoped to this
  one repository. This means the role used for staging deploys has no
  path to the production cluster's credentials at all, and vice versa
  — a stronger boundary than one shared role with broad scope.
- Each role's EKS access is granted via an **EKS access entry using the
  `AmazonEKSEditPolicy`**, not `AmazonEKSClusterAdminPolicy`. Edit
  permits creating/updating/deleting workloads (Deployments, Services,
  ConfigMaps, Secrets, HPAs) — exactly what CD needs — without granting
  cluster-admin-level control over RBAC or cluster-wide security
  settings.
- IAM permissions are scoped per-resource: ECR push/pull to one
  repository ARN, `eks:DescribeCluster` to one cluster ARN,
  `rds:DescribeDBInstances` to one DB instance ARN, and
  `secretsmanager:GetSecretValue` to one secret ARN. Not
  AdministratorAccess, and no wildcard resources except
  `ecr:GetAuthorizationToken`, which AWS requires to be `"*"`.

### Network Security
- RDS is deployed in a **private subnet** with `publicly_accessible =
  false`.
- A dedicated RDS security group only allows inbound Postgres traffic
  (port 5432) from the **EKS node security group** — nothing else can
  reach the database.
- EKS worker nodes run in private subnets.
- External access to the application goes through a Kubernetes
  `type: LoadBalancer` Service provisioning an AWS NLB (see
  `docs/architecture.md`) — the database is never exposed this way.

### Dependency & Supply Chain Security
- `ruff` lints and `pytest` tests run in CI before anything is built.
- `pip-audit` runs in CI to flag known-vulnerable Python dependencies
  (currently non-blocking — see Known Limitations).
- Trivy scans both the filesystem/dependencies and the built image, and
  is blocking (`exit-code: 1`) on CRITICAL/HIGH findings in both CI and
  CD.

## Known Limitations (stated honestly)

- The EKS cluster's public API endpoint is enabled for convenience in
  this demo (`cluster_endpoint_public_access = true`); a hardened
  production setup would restrict this to a VPN/bastion CIDR or disable
  public access entirely.
- A single NAT Gateway is used (cost trade-off), which is a single point
  of failure for outbound traffic from private subnets — real production
  would use one per AZ.
- `pip-audit` is currently configured as non-blocking (`|| true`) in CI
  so a newly-disclosed CVE in a transitive dependency doesn't
  immediately block all merges; findings should still be reviewed
  manually.
- The `type: LoadBalancer` Service requires the AWS Load Balancer
  Controller to be installed on the cluster (a one-time Helm-based
  bootstrap step this repo documents in `README.md` but does not
  automate via Terraform yet) — until then, the Service has no external
  address and that's expected, not a hidden failure.
- Rollback on a failed production deployment is **manual** (see
  `RUNBOOK.md` "Rollback"), by design — automatic rollback was
  deliberately not implemented because it has not been exercised
  end-to-end against a real cluster, and an untested automatic
  rollback path is itself a risk.
- This project has not been assessed by a third-party security audit or
  penetration test. It demonstrates security-conscious patterns for an
  entry-level SRE/DevOps context, not a certified production security
  posture.
- No WAF, DDoS protection, or rate-limiting layer sits in front of the
  NLB in this version — an ALB via the AWS Load Balancer Controller
  would be the natural next step if that's needed (see
  `docs/architecture.md` for the trade-off discussion).
