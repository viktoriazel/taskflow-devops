"""Worker liveness, readiness and health endpoint tests.

/live and /ready back the Kubernetes probes on the Worker Deployment.
"""


def test_liveness_probe_reports_ok(client):
    response = client.get("/live")

    assert response.status_code == 200
    assert response.get_json() == {
        "service": "worker",
        "check": "live",
        "status": "ok",
    }


def test_readiness_probe_reports_ok(client):
    response = client.get("/ready")

    assert response.status_code == 200
    assert response.get_json() == {
        "service": "worker",
        "check": "ready",
        "status": "ok",
    }


def test_health_endpoint_reports_ok(client):
    response = client.get("/health")

    assert response.status_code == 200
    assert response.get_json() == {
        "service": "worker",
        "status": "ok",
    }
