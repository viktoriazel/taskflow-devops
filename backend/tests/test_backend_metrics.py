"""Tests for Backend Prometheus instrumentation."""

import importlib.util
import io
import sys
from pathlib import Path

import pytest
import requests
from prometheus_client import CONTENT_TYPE_LATEST

import backend_metrics

SERVICE_DIR = Path(__file__).resolve().parents[1]
DB_MODULE_NAME = "taskflow_backend_db"

REQUESTS = "taskflow_http_requests_total"
DURATION_COUNT = "taskflow_http_request_duration_seconds_count"
DURATION_BUCKET = "taskflow_http_request_duration_seconds_bucket"
DEPENDENCY_FAILURES = "taskflow_dependency_failures_total"
APP_INFO = "taskflow_app_info"
TODOS_CREATED = "taskflow_todos_created_total"

EXCLUDED_PATHS = ["/metrics", "/health", "/live", "/ready"]

STORED_TODO = {
    "id": 1,
    "title": "Buy milk",
    "done": False,
    "file_keys": [],
    "user_id": 42,
}


def sample(name, **labels):
    """Return a registry sample, or 0.0 when that series does not exist yet."""
    value = backend_metrics.METRICS_REGISTRY.get_sample_value(name, labels)
    return 0.0 if value is None else value


@pytest.fixture(scope="session")
def backend_db():
    """The real db.py — the app fixture replaces it with a stub, so it is loaded here."""
    spec = importlib.util.spec_from_file_location(DB_MODULE_NAME, SERVICE_DIR / "db.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[DB_MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


def test_metrics_endpoint_serves_prometheus_text(client):
    response = client.get("/metrics")

    assert response.status_code == 200
    assert response.headers["Content-Type"] == CONTENT_TYPE_LATEST

    body = response.get_data(as_text=True)
    assert "# TYPE taskflow_http_requests_total counter" in body
    assert "# TYPE taskflow_http_request_duration_seconds histogram" in body
    assert "# TYPE taskflow_app_info gauge" in body
    assert "# TYPE taskflow_todos_created_total counter" in body


def test_request_counter_counts_the_request(client):
    labels = {"service": "backend", "method": "POST", "route": "/todos", "status": "401"}
    before = sample(REQUESTS, **labels)

    response = client.post("/todos", json={"title": "Buy milk"})

    assert response.status_code == 401
    assert sample(REQUESTS, **labels) == before + 1


def test_latency_histogram_observes_the_request(client):
    labels = {"service": "backend", "method": "POST", "route": "/todos"}
    before = sample(DURATION_COUNT, **labels)

    client.post("/todos", json={"title": "Buy milk"})

    assert sample(DURATION_COUNT, **labels) == before + 1
    assert sample(DURATION_BUCKET, le="+Inf", **labels) == before + 1


@pytest.mark.parametrize("path", EXCLUDED_PATHS)
def test_probe_and_scrape_traffic_stays_out_of_request_metrics(client, path):
    client.get(path)

    body = client.get("/metrics").get_data(as_text=True)

    assert f'route="{path}"' not in body


def test_unmatched_route_never_reaches_a_label_as_a_raw_path(client):
    labels = {"service": "backend", "method": "GET", "route": "unmatched", "status": "404"}
    before = sample(REQUESTS, **labels)
    path = "/no-such-route-3f9c1a"

    assert client.get(path).status_code == 404

    assert sample(REQUESTS, **labels) == before + 1
    assert path not in client.get("/metrics").get_data(as_text=True)


def test_worker_notification_failure_counts_a_dependency_failure(
    client, backend_app, monkeypatch
):
    class UnreachableWorker:
        """requests stand-in whose POST fails the way an unreachable Worker does."""

        RequestException = requests.RequestException

        def post(self, *args, **kwargs):
            raise requests.RequestException("Worker is unreachable")

    monkeypatch.setattr(backend_app, "create_todo_record", lambda title, user_id: STORED_TODO)
    monkeypatch.setattr(backend_app, "requests", UnreachableWorker())

    labels = {"service": "backend", "dependency": "worker"}
    before = sample(DEPENDENCY_FAILURES, **labels)

    response = client.post("/todos", headers={"X-User-Id": "42"}, json={"title": "Buy milk"})

    assert response.status_code == 201
    assert sample(DEPENDENCY_FAILURES, **labels) == before + 1


def test_s3_upload_failure_counts_a_dependency_failure(client, backend_app, monkeypatch):
    class FailingS3:
        """boto3 S3 stand-in whose upload always fails."""

        def upload_fileobj(self, *args, **kwargs):
            raise RuntimeError("bucket is unavailable")

    monkeypatch.setattr(backend_app, "find_todo_by_id", lambda todo_id: STORED_TODO)
    monkeypatch.setattr(backend_app, "s3_client", FailingS3())

    labels = {"service": "backend", "dependency": "s3"}
    before = sample(DEPENDENCY_FAILURES, **labels)

    response = client.post(
        "/todos/1/upload",
        headers={"X-User-Id": "42"},
        data={"file": (io.BytesIO(b"report body"), "report.txt")},
        content_type="multipart/form-data",
    )

    assert response.status_code == 503
    assert sample(DEPENDENCY_FAILURES, **labels) == before + 1


def test_todo_counter_grows_after_a_stored_todo(client, backend_app, monkeypatch):
    monkeypatch.setattr(backend_app, "create_todo_record", lambda title, user_id: STORED_TODO)
    monkeypatch.setattr(backend_app, "notify_worker", lambda event, title: None)

    before = sample(TODOS_CREATED, service="backend")

    response = client.post("/todos", headers={"X-User-Id": "42"}, json={"title": "Buy milk"})

    assert response.status_code == 201
    assert sample(TODOS_CREATED, service="backend") == before + 1


def test_todo_counter_stays_put_when_the_write_fails(client, backend_app, monkeypatch):
    """The counter sits after the database write, so a failed write must not count."""
    def failing_create(title, user_id):
        raise RuntimeError("database is unavailable")

    monkeypatch.setattr(backend_app, "create_todo_record", failing_create)

    before = sample(TODOS_CREATED, service="backend")

    with pytest.raises(RuntimeError):
        client.post("/todos", headers={"X-User-Id": "42"}, json={"title": "Buy milk"})

    assert sample(TODOS_CREATED, service="backend") == before


def test_database_connection_failure_counts_a_dependency_failure(backend_db, monkeypatch):
    def refuse_connection(**kwargs):
        raise backend_db.psycopg2.OperationalError("could not connect to server")

    monkeypatch.setattr(backend_db.psycopg2, "connect", refuse_connection)

    labels = {"service": "backend", "dependency": "postgres"}
    before = sample(DEPENDENCY_FAILURES, **labels)

    with pytest.raises(backend_db.psycopg2.OperationalError):
        backend_db.get_connection()

    assert sample(DEPENDENCY_FAILURES, **labels) == before + 1


def test_app_info_reports_the_service_and_release_defaults(backend_app):
    assert sample(
        APP_INFO,
        service="backend",
        version="unknown",
        git_sha="unknown",
        release="unknown",
    ) == 1.0


def test_release_labels_come_from_the_deployment_environment(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "git-abc1234-7")
    monkeypatch.setenv("GIT_COMMIT", "abc1234def5678901234567890abcdef12345678")
    monkeypatch.setenv("RELEASE_REF", "ci-application#7")

    assert backend_metrics.release_labels() == {
        "version": "git-abc1234-7",
        "git_sha": "abc1234def5678901234567890abcdef12345678",
        "release": "ci-application#7",
    }
