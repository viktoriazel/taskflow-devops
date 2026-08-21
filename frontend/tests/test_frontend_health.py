"""Frontend liveness, health and readiness endpoint tests.

/ready backs both the Kubernetes readiness probe and the ALB health check, and
must report 503 while SECRET_KEY is missing.
"""


def test_liveness_probe_reports_alive(client):
    response = client.get("/live")

    assert response.status_code == 200
    assert response.get_json() == {"status": "alive"}


def test_health_endpoint_reports_running(client):
    response = client.get("/health")

    assert response.status_code == 200
    assert response.get_json() == {"status": "frontend is running"}


def test_readiness_probe_reports_ready_when_the_secret_key_is_loaded(client):
    response = client.get("/ready")

    assert response.status_code == 200
    assert response.get_json() == {"status": "ready"}


def test_readiness_probe_reports_503_without_a_secret_key(client, frontend_app, monkeypatch):
    # app.secret_key is config-backed, so the config entry is what the route reads.
    monkeypatch.setitem(frontend_app.app.config, "SECRET_KEY", None)

    response = client.get("/ready")

    assert response.status_code == 503
    assert response.get_json() == {"status": "not ready"}
