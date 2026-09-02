"""Tests for Worker Prometheus instrumentation."""

import pytest
from prometheus_client import CONTENT_TYPE_LATEST

import worker_metrics

REQUESTS = "taskflow_http_requests_total"
DURATION_COUNT = "taskflow_http_request_duration_seconds_count"
DURATION_BUCKET = "taskflow_http_request_duration_seconds_bucket"
DEPENDENCY_FAILURES = "taskflow_dependency_failures_total"
APP_INFO = "taskflow_app_info"

EXCLUDED_PATHS = ["/metrics", "/health", "/live", "/ready"]


def sample(name, **labels):
    """Return a registry sample, or 0.0 when that series does not exist yet."""
    value = worker_metrics.METRICS_REGISTRY.get_sample_value(name, labels)
    return 0.0 if value is None else value


def test_metrics_endpoint_serves_prometheus_text(client):
    response = client.get("/metrics")

    assert response.status_code == 200
    assert response.headers["Content-Type"] == CONTENT_TYPE_LATEST

    body = response.get_data(as_text=True)
    assert "# TYPE taskflow_http_requests_total counter" in body
    assert "# TYPE taskflow_http_request_duration_seconds histogram" in body
    assert "# TYPE taskflow_app_info gauge" in body


def test_request_counter_counts_the_request(client):
    labels = {"service": "worker", "method": "POST", "route": "/notify", "status": "400"}
    before = sample(REQUESTS, **labels)

    response = client.post("/notify", json={})

    assert response.status_code == 400
    assert sample(REQUESTS, **labels) == before + 1


def test_latency_histogram_observes_the_request(client):
    labels = {"service": "worker", "method": "POST", "route": "/notify"}
    before = sample(DURATION_COUNT, **labels)

    client.post("/notify", json={})

    assert sample(DURATION_COUNT, **labels) == before + 1
    assert sample(DURATION_BUCKET, le="+Inf", **labels) == before + 1


@pytest.mark.parametrize("path", EXCLUDED_PATHS)
def test_probe_and_scrape_traffic_stays_out_of_request_metrics(client, path):
    client.get(path)

    body = client.get("/metrics").get_data(as_text=True)

    assert f'route="{path}"' not in body


def test_unmatched_route_never_reaches_a_label_as_a_raw_path(client):
    labels = {"service": "worker", "method": "GET", "route": "unmatched", "status": "404"}
    before = sample(REQUESTS, **labels)
    path = "/no-such-route-3f9c1a"

    assert client.get(path).status_code == 404

    assert sample(REQUESTS, **labels) == before + 1
    assert path not in client.get("/metrics").get_data(as_text=True)


def test_sns_failure_counts_a_dependency_failure(client, worker_module, monkeypatch):
    labels = {"service": "worker", "dependency": "sns"}
    before = sample(DEPENDENCY_FAILURES, **labels)

    class FailingSns:
        def publish(self, **kwargs):
            raise RuntimeError("SNS is unavailable")

    monkeypatch.setattr(worker_module, "sns_client", FailingSns())

    response = client.post("/notify", json={"event": "todo_created", "title": "Buy milk"})

    assert response.status_code == 500
    assert sample(DEPENDENCY_FAILURES, **labels) == before + 1


def test_app_info_reports_the_service_and_release_defaults(worker_module):
    assert sample(
        APP_INFO,
        service="worker",
        version="unknown",
        git_sha="unknown",
        release="unknown",
    ) == 1.0


def test_release_labels_come_from_the_deployment_environment(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "git-abc1234-7")
    monkeypatch.setenv("GIT_COMMIT", "abc1234def5678901234567890abcdef12345678")
    monkeypatch.setenv("RELEASE_REF", "ci-application#7")

    assert worker_metrics.release_labels() == {
        "version": "git-abc1234-7",
        "git_sha": "abc1234def5678901234567890abcdef12345678",
        "release": "ci-application#7",
    }
