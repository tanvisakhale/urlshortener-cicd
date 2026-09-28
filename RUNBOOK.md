# RUNBOOK

Incident response procedures for the URL Shortener service. Each incident
follows: Symptoms → Initial checks → Commands → Possible causes →
Resolution → Verification → Prevention.

Useful commands referenced throughout:

```bash
kubectl get pods -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
kubectl get deployment url-shortener -n <namespace>
kubectl rollout status deployment/url-shortener -n <namespace>
kubectl rollout history deployment/url-shortener -n <namespace>
kubectl rollout undo deployment/url-shortener -n <namespace>
kubectl get hpa -n <namespace>
kubectl top pods -n <namespace>
```

---

## Incident 1: Pod is `CrashLoopBackOff`

**Symptoms:** `kubectl get pods` shows a pod repeatedly restarting with
status `CrashLoopBackOff`.

**Initial checks:**
- Confirm how many pods are affected: one, or all replicas.
- Check how recently this started (correlate with a recent deploy).

**Commands:**
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

**Possible causes:**
- Application crashes on startup (bad config, missing env var, DB
  unreachable at boot).
- Bad image pushed (e.g. a broken commit made it past CI, or the wrong
  tag was deployed).
- Liveness probe failing before the app finishes starting up
  (`initialDelaySeconds` too low).

**Resolution:**
- If caused by a bad deploy: `kubectl rollout undo deployment/url-shortener -n <namespace>`.
- If caused by missing/incorrect config: fix the ConfigMap/Secret and
  re-apply (`kubectl apply -k k8s/overlays/<env>`).
- If the probe is too aggressive: adjust `initialDelaySeconds` in
  `k8s/base/deployment.yaml`.

**Verification:** `kubectl get pods -n <namespace>` shows `Running` and
`READY 1/1` with no restart increase; `/health` returns 200.

**Prevention:** CI runs the test suite and a Trivy scan before any image
is pushed; the CD pipeline runs a staging smoke test before production.

---

## Incident 2: Readiness Probe Failing

**Symptoms:** Pod status is `Running` but `READY 0/1`; the pod never
receives traffic from the Service.

**Initial checks:**
- Is the app actually listening on port 8000?
- Is `/health` reachable from inside the pod?

**Commands:**
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl exec -it <pod-name> -n <namespace> -- curl -sf http://localhost:8000/health
kubectl logs <pod-name> -n <namespace>
```

**Possible causes:**
- App is slow to start (DB connection retry loop) and the readiness
  probe times out before it's ready.
- App is up but a downstream dependency (RDS) is unreachable — see
  Incident 8.
- Misconfigured probe path/port in the Deployment spec.

**Resolution:**
- Increase `initialDelaySeconds`/`periodSeconds` if the app just needs
  more time.
- If RDS is unreachable, see Incident 8.
- Fix the probe path/port if misconfigured and re-apply.

**Verification:** `kubectl get pods` shows `READY 1/1`; Service
endpoints include the pod (`kubectl get endpoints url-shortener -n <namespace>`).

**Prevention:** Keep `/health` lightweight (no heavy DB queries) so it
reflects "process is alive"; rely on separate alerting for DB
connectivity rather than coupling it to the readiness probe.

---

## Incident 3: Liveness Probe Failing

**Symptoms:** Pods restart repeatedly (`RESTARTS` count climbing in
`kubectl get pods`), but unlike Incident 1 the app *was* healthy at some
point after starting — it's failing the probe later, mid-life, not on
startup.

**Initial checks:**
- Distinguish this from Incident 1: check `kubectl describe pod` for
  "Liveness probe failed" events specifically, and check how long the
  pod ran before restarting (seconds → startup issue / Incident 1;
  minutes-to-hours → this incident).
- Is the process hanging (deadlocked, stuck on a slow DB query) rather
  than crashed?

**Commands:**
```bash
kubectl describe pod <pod-name> -n <namespace>   # look for "Liveness probe failed"
kubectl logs <pod-name> -n <namespace> --previous
kubectl top pod <pod-name> -n <namespace>
```

**Possible causes:**
- The app process is alive but unresponsive (e.g. blocked on a slow/hung
  DB connection), so `/health` times out even though the process hasn't
  crashed.
- `periodSeconds`/`timeoutSeconds` too tight for occasional GC pauses or
  brief load spikes, causing false-positive restarts.
- A genuine deadlock or resource exhaustion (see Incident 5).

**Resolution:**
- If it's a false positive under normal load spikes, relax
  `timeoutSeconds`/`failureThreshold` in `k8s/base/deployment.yaml`.
- If the app is genuinely hanging on the database, resolve per
  Incident 8 first — restarting the pod without fixing the DB issue
  will just repeat the cycle.
- If it's a deadlock in application code, capture logs from the
  restarted pod (`--previous`) before it's lost, and treat as a bug fix
  through the normal CI/CD pipeline.

**Verification:** `kubectl get pods` shows a stable `RESTARTS` count
that stops climbing; `kubectl describe pod` shows no further liveness
failure events.

**Prevention:** Liveness and readiness intentionally share the
lightweight `/health` endpoint (see `docs/architecture.md`/README on the
difference between the two) so a hang is caught quickly without the
probe itself becoming a source of load.

---

## Incident 4: High CPU Usage

**Symptoms:** `HighCPUUsage` alert fires (see
`monitoring/alerts/alerts.yml` for the exact PromQL and threshold); it
compares actual CPU usage against the container's *requested* CPU, the
same basis the HPA scales on — latency may also be increasing.

**Initial checks:**
- Is this a genuine traffic spike, or a runaway request (e.g. infinite
  loop, inefficient query)?
- Is the HPA already scaling out?

**Commands:**
```bash
kubectl top pods -n <namespace>
kubectl get hpa -n <namespace>
kubectl describe hpa url-shortener-hpa -n <namespace>
```

**Possible causes:**
- Legitimate increased traffic (HPA should handle this).
- A single expensive/looping request.
- HPA `maxReplicas` ceiling reached under sustained load.

**Resolution:**
- If HPA is scaling correctly, monitor and let it work.
- If `maxReplicas` is being hit repeatedly, raise the ceiling in
  `k8s/base/hpa.yaml` after confirming the extra load is legitimate.
- If caused by a bad request pattern, identify it from logs and add
  input validation / rate limiting.

**Verification:** CPU utilization (relative to requests) drops back
under 70%; `kubectl get hpa` shows replica count stabilizing.

**Prevention:** Resource requests/limits are set so both the HPA and
the Prometheus alert have accurate, comparable data to act on.

---

## Incident 5: High Memory Usage

**Symptoms:** Pod memory usage climbing toward the configured limit;
possible `OOMKilled` restarts.

**Initial checks:**
```bash
kubectl top pods -n <namespace>
kubectl describe pod <pod-name> -n <namespace>   # check for OOMKilled in "Last State"
```

**Possible causes:**
- Memory leak in the application (e.g. unbounded caching).
- Memory limit set too low for legitimate load.
- A specific endpoint holding large payloads in memory.

**Resolution:**
- If OOMKilled and load is legitimate, raise `resources.limits.memory`
  in `k8s/base/deployment.yaml`.
- If it's a leak, roll back to the last known-good image
  (`kubectl rollout undo`) while the leak is investigated and fixed.

**Verification:** Memory usage stabilizes well below the limit across
multiple pod restarts.

**Prevention:** Memory limits are set explicitly so a leak fails fast
(pod restart) rather than affecting the whole node; monitor the Grafana
"Memory Utilization by Pod" panel for slow upward trends.

---

## Incident 6: High HTTP 5xx Rate

**Symptoms:** `HighErrorRate` alert fires (>5% of requests returning
5xx, sustained 5 minutes — see `monitoring/alerts/alerts.yml`).

**Initial checks:**
- Is the error rate isolated to one endpoint, or system-wide?
- Did this start right after a deploy?

**Commands:**
```bash
kubectl logs -l app=url-shortener -n <namespace> --tail=200
kubectl rollout history deployment/url-shortener -n <namespace>
```
Check the Grafana "HTTP Error Rate" panel to see which endpoint/method
is spiking.

**Possible causes:**
- Bad deploy introducing a bug.
- Database connectivity issues (Incident 8) surfacing as 500s.
- Unhandled exception on a specific input pattern.

**Resolution:**
- If tied to a recent deploy: `kubectl rollout undo deployment/url-shortener -n <namespace>`.
- If tied to the database: resolve per Incident 8.
- Otherwise, patch the bug, let CI validate, and redeploy through the
  normal pipeline.

**Verification:** Error rate in Grafana / `http_errors_total` drops
back under 1%.

**Prevention:** Every request is logged with a `request_id` and
`error_message` so failures are traceable; CI blocks merges if tests
fail.

---

## Incident 7: High Latency

**Symptoms:** `HighLatency` alert fires (p95 request duration above
500ms, sustained 5 minutes).

**Initial checks:**
- Is latency elevated across all endpoints, or just one (e.g.
  `/shorten`, which writes to the DB, vs `/health`, which doesn't)?
- Does it correlate with the `HighCPUUsage` alert, or with a database
  issue?

**Commands:**
```bash
kubectl top pods -n <namespace>
kubectl logs -l app=url-shortener -n <namespace> --tail=200
```
Check the Grafana "Response Latency (p50/p95/p99)" panel, split by
endpoint if possible, to localize the slowdown.

**Possible causes:**
- CPU saturation (see Incident 4) causing requests to queue.
- Slow database queries or connection pool exhaustion (see Incident 8).
- A genuinely slower code path introduced by a recent deploy.

**Resolution:**
- If tied to CPU/HPA: resolve per Incident 4.
- If tied to the database: resolve per Incident 8.
- If tied to a recent deploy, roll back
  (`kubectl rollout undo deployment/url-shortener -n <namespace>`) and
  investigate the slow code path separately.

**Verification:** p95 latency in Grafana drops back under 500ms and
stays there for at least one full alert evaluation window (5+ minutes).

**Prevention:** The latency SLO (see `docs/SRE.md`) gives an agreed
target so "slow" has a concrete definition instead of being subjective;
the histogram buckets in `app/metrics.py` are fine-grained below 500ms
to make p95/p99 calculations meaningful at this scale.

---

## Incident 8: Database Connection Failure

**Symptoms:** App logs show DB connection errors; `/shorten` and
redirect endpoints return 500s while `/health` may still return 200
(since `/health` is intentionally lightweight and doesn't hit the DB).

**Initial checks:**
- Is RDS itself healthy (AWS Console / `aws rds describe-db-instances`)?
- Are the DB credentials in the Secret correct and unexpired?
- Is the security group still allowing traffic from the EKS node SG?

**Commands:**
```bash
kubectl logs -l app=url-shortener -n <namespace> --tail=100 | grep -i "database\|connection"
kubectl get secret url-shortener-secret -n <namespace> -o yaml
aws rds describe-db-instances --db-instance-identifier url-shortener-<env> \
  --query 'DBInstances[0].DBInstanceStatus'
```

**Possible causes:**
- RDS instance under maintenance, failing over (Multi-AZ), or down.
- Security group rule removed/changed.
- The AWS-managed master password rotated (RDS `manage_master_user_password`
  can rotate it) without the Kubernetes Secret being refreshed to match.
- Connection pool exhaustion under load.

**Resolution:**
- Confirm RDS status in AWS; if it's mid-failover, wait for it to
  complete (Multi-AZ failover is typically under a minute).
- If the password was rotated, re-run the CD pipeline's "fetch DB
  credentials" step (or manually re-fetch from Secrets Manager and
  update the Secret), then restart pods:
  `kubectl rollout restart deployment/url-shortener -n <namespace>`.
- If the security group was changed, restore the rule allowing the EKS
  node security group on port 5432 (see `terraform/rds.tf`).

**Verification:** `/shorten` succeeds again; error rate returns to
baseline.

**Prevention:** RDS is deployed in a private subnet reachable only
from the EKS node security group; production RDS runs Multi-AZ for
automatic failover; the master password is never stored in Terraform
state (see `SECURITY.md`), only in the AWS-managed Secrets Manager
secret and the in-cluster Kubernetes Secret.

---

## Incident 9: Deployment Rollout Failure

**Symptoms:** `kubectl rollout status` hangs or reports the rollout
failed to complete; the CD pipeline's "Wait for rollout" step times out.

**Initial checks:**
```bash
kubectl rollout status deployment/url-shortener -n <namespace>
kubectl describe deployment url-shortener -n <namespace>
kubectl get pods -n <namespace>
```

**Possible causes:**
- New pods stuck in `CrashLoopBackOff` or `ImagePullBackOff` (bad image
  tag, ECR auth issue).
- Insufficient cluster resources to schedule new pods.
- Readiness probe never passing on the new revision.

**Resolution:** See Incident 10 (Rollback) — undo the rollout, then
investigate the failed revision's pod logs/events (Incidents 1 and 2)
before attempting to redeploy.

**Verification:** `kubectl rollout status` reports "successfully
rolled out"; all pods `Running` and `READY`.

**Prevention:** The CD pipeline treats a failed rollout/smoke-test as a
pipeline failure and does not proceed to production; immutable
commit-SHA image tags make it unambiguous which revision to roll back
to.

---

## Incident 10: Rollback

**Symptoms:** A deployment is confirmed bad (via any of Incidents 1, 6,
7, or 9) and needs to be undone rather than fixed forward.

**Initial checks:**
- Confirm which revision was last known-good:
  `kubectl rollout history deployment/url-shortener -n <namespace>`.

**Commands:**
```bash
kubectl rollout history deployment/url-shortener -n <namespace>
kubectl rollout undo deployment/url-shortener -n <namespace>
kubectl rollout status deployment/url-shortener -n <namespace>
```

**Possible causes (why a rollback is needed):** a bad deploy is the
common thread — a regression in application code, a bad config change,
or an image that fails health checks.

**Resolution:** As above. Because every image is tagged with the
immutable git commit SHA (never `:latest`), `kubectl rollout undo`
always returns to a known, exact previous build — there's no ambiguity
about what "previous" means.

**Verification:** `kubectl rollout status` reports success; error
rate/latency return to baseline; `kubectl get pods` shows the previous
image tag running (`kubectl describe pod <pod> | grep Image:`).

**Prevention / pipeline design note:** the CD pipeline (see
`.github/workflows/cd.yml`) deploys, waits for rollout, and runs a
health/smoke test before marking a deploy successful — but it does
**not** automatically run `kubectl rollout undo` on failure. Automatic
rollback was deliberately left out because it hasn't been exercised
against a real cluster in this project, and an untested automatic
rollback path can itself become a source of incidents. Until it's been
tested end-to-end, rollback is a deliberate, documented manual step
using the commands above — a human decides and executes it, guided by
this runbook.
