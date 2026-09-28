"""
Prometheus metrics for the URL Shortener service.

Metric types used and why:
  - Counter:   monotonically increasing values (request counts, errors,
               URLs created). Good for computing rates with rate()/irate().
  - Histogram: request latency. Buckets let us compute percentiles
               (e.g. p95, p99) and averages in PromQL.
  - Gauge:     values that go up and down (in-flight requests, availability
               flag).
"""
from prometheus_client import Counter, Gauge, Histogram

# --- Request metrics -------------------------------------------------------
HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total number of HTTP requests received",
    ["method", "endpoint", "status_code"],
)

# --- Performance metrics -----------------------------------------------------
HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)

# --- Reliability metrics -----------------------------------------------------
HTTP_ERRORS_TOTAL = Counter(
    "http_errors_total",
    "Total number of HTTP 5xx errors",
    ["method", "endpoint"],
)

APP_AVAILABILITY = Gauge(
    "app_availability",
    "1 if the application is currently healthy, 0 otherwise",
)
APP_AVAILABILITY.set(1)

# --- Business metric ---------------------------------------------------------
URLS_SHORTENED_TOTAL = Counter(
    "urls_shortened_total",
    "Total number of URLs successfully shortened",
)
