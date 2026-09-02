"""The deliberate failure switch used for controlled failure exercises."""

import itertools

import pytest

import backend_metrics

SWITCH = "TASKFLOW_FAIL_EVERY"

PROBE_PATHS = ["/metrics", "/health", "/live", "/ready"]


def test_switch_is_off_by_default(client, monkeypatch):
    monkeypatch.delenv(SWITCH, raising=False)

    response = client.post("/todos", json={"title": "Buy milk"})

    assert response.status_code == 401


def test_every_request_fails_when_the_interval_is_one(client, monkeypatch):
    monkeypatch.setenv(SWITCH, "1")

    for _ in range(2):
        response = client.post("/todos", json={"title": "Buy milk"})

        assert response.status_code == 503
        assert response.get_json() == {"error": "Service temporarily unavailable"}


def test_failures_land_on_a_predictable_interval(client, backend_app, monkeypatch):
    monkeypatch.setattr(backend_app, "_request_sequence", itertools.count(1))
    monkeypatch.setenv(SWITCH, "3")

    statuses = [client.post("/todos", json={"title": "Buy milk"}).status_code for _ in range(6)]

    assert statuses == [401, 401, 503, 401, 401, 503]


@pytest.mark.parametrize("path", PROBE_PATHS)
def test_probes_and_metrics_keep_answering_while_the_switch_is_on(client, monkeypatch, path):
    monkeypatch.setenv(SWITCH, "1")

    assert client.get(path).status_code == 200


def test_a_deliberate_failure_is_counted_as_a_5xx(client, monkeypatch):
    labels = {"service": "backend", "method": "POST", "route": "/todos", "status": "503"}
    before = backend_metrics.METRICS_REGISTRY.get_sample_value(
        "taskflow_http_requests_total", labels
    ) or 0.0

    monkeypatch.setenv(SWITCH, "1")
    client.post("/todos", json={"title": "Buy milk"})

    after = backend_metrics.METRICS_REGISTRY.get_sample_value(
        "taskflow_http_requests_total", labels
    )

    assert after == before + 1


def test_an_unparsable_value_leaves_the_switch_off(client, monkeypatch):
    monkeypatch.setenv(SWITCH, "not-a-number")

    response = client.post("/todos", json={"title": "Buy milk"})

    assert response.status_code == 401
