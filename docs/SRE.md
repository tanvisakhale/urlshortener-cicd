# SRE Concepts: SLI, SLO, and Error Budgets

This document explains the core SRE concepts applied to the URL Shortener
service, and the demonstration targets used in this project.

## Service Level Indicator (SLI)

An SLI is a quantitative measure of some aspect of the service's
behaviour, computed from real metrics. This project tracks three:

### Availability SLI
The percentage of requests (or synthetic `/health` checks) that succeed.

```
Availability = (successful health checks / total health checks) * 100
```

Measured via the `app_availability` gauge and the `up` metric Prometheus
records for the `/metrics` scrape target.

### Latency SLI
The percentage of requests completed under a defined threshold.

```
Latency SLI = (requests completed < 500ms / total requests) * 100
```

Measured via the `http_request_duration_seconds` histogram, using
`histogram_quantile()` in PromQL to compute p50/p95/p99.

### Error-Rate SLI
The percentage of requests that do **not** return a 5xx error.

```
Error-rate SLI = (successful responses / total responses) * 100
```

Measured via `http_requests_total` (all responses) vs `http_errors_total`
(5xx responses).

## Service Level Objective (SLO)

An SLO is the target value for an SLI over a period of time. These are
**demonstration targets for this portfolio project**, not claims about a
real production service with real traffic history:

| SLI            | SLO Target                          |
|----------------|--------------------------------------|
| Availability   | 99.5% over a rolling 30 days          |
| Latency        | 95% of requests complete in < 500ms   |
| Error rate     | 5xx errors < 1% of total requests     |

## Error Budget

The error budget is the allowed amount of "unreliability" before an SLO
is breached.

```
Error budget = 100% - SLO target
```

Example: with a 99.5% availability SLO, the error budget is 0.5%. Over a
30-day month (43,200 minutes), that's about **216 minutes** of allowed
downtime. Once the error budget is exhausted, the convention in SRE
practice is to freeze new feature rollouts and prioritize reliability
work until the budget recovers.

## Availability, Latency, Reliability — definitions used in this project

- **Availability**: whether the service responds successfully to
  requests at all (captured by `/health` and the `up` metric).
- **Latency**: how long a successful request takes to complete
  (captured by the request duration histogram).
- **Reliability**: the combination of availability, correctness (low
  error rate), and consistency of the above over time — the thing SLOs
  are meant to protect.

## How These Tie Together in This Project

1. Prometheus scrapes `/metrics` on each pod.
2. Grafana visualizes the SLIs (see `monitoring/grafana/dashboard.json`).
3. Alert rules in `monitoring/alerts/alerts.yml` fire when an SLI
   threatens to breach its SLO (e.g. error rate > 5%, p95 latency >
   500ms).
4. `RUNBOOK.md` documents the response procedure once an alert fires.
