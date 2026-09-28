def test_shorten_url_success(client):
    response = client.post("/shorten", json={"url": "https://example.com/some/page"})
    assert response.status_code == 201
    body = response.json()
    assert "short_code" in body
    assert body["original_url"].startswith("https://example.com")
    assert body["short_url"].endswith(body["short_code"])


def test_shorten_url_missing_field(client):
    response = client.post("/shorten", json={})
    assert response.status_code == 422


def test_shorten_url_invalid_url(client):
    response = client.post("/shorten", json={"url": "not-a-valid-url"})
    assert response.status_code == 422


def test_redirect_success(client):
    create = client.post("/shorten", json={"url": "https://example.org/target"})
    short_code = create.json()["short_code"]

    response = client.get(f"/{short_code}", follow_redirects=False)
    assert response.status_code == 307
    assert response.headers["location"] == "https://example.org/target"


def test_redirect_not_found(client):
    response = client.get("/does-not-exist")
    assert response.status_code == 404


def test_error_handling_returns_json_detail(client):
    response = client.get("/definitely-missing-code")
    assert response.status_code == 404
    assert response.json()["detail"] == "Short URL not found"
