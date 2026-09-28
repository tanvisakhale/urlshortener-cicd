def test_health_endpoint(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "healthy"}


def test_metrics_endpoint_exposes_prometheus_format(client):
    # Generate some traffic so counters are non-empty.
    client.get("/health")
    response = client.get("/metrics")
    assert response.status_code == 200
    text = response.text
    assert "http_requests_total" in text
    assert "urls_shortened_total" in text
