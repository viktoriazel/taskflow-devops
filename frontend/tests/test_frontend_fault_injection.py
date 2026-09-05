"""The deliberate failure switch used for controlled failure testing."""

import itertools

import pytest

import frontend_metrics

SWITCH = "TASKFLOW_FAIL_EVERY"

PROBE_PATHS = ["/metrics", "/health", "/live", "/ready"]

OFF_VALUES = ["0", "-1", "", "not-a-number", "3.5"]


@pytest.fixture(autouse=True)
def request_sequence(frontend_app, monkeypatch):
    """Restart the request counter, so no test inherits another test's position."""
    monkeypatch.setattr(frontend_app, "_request_sequence", itertools.count(1))


def test_switch_is_off_by_default(client):
    response = client.get("/login")

    assert response.status_code == 200


@pytest.mark.parametrize("value", OFF_VALUES)
def test_a_value_that_is_not_a_positive_interval_leaves_the_switch_off(
    client, monkeypatch, value
):
    monkeypatch.setenv(SWITCH, value)

    assert client.get("/login").status_code == 200


def test_every_request_fails_when_the_interval_is_one(client, monkeypatch):
    monkeypatch.setenv(SWITCH, "1")

    for _ in range(2):
        response = client.get("/login")

        assert response.status_code == 503
        assert response.get_json() == {"error": "Service temporarily unavailable"}


def test_failures_land_on_a_predictable_interval(client, monkeypatch):
    monkeypatch.setenv(SWITCH, "3")

    statuses = [client.get("/login").status_code for _ in range(6)]

    assert statuses == [200, 200, 503, 200, 200, 503]


def test_the_sequence_only_advances_while_the_switch_is_on(client, monkeypatch):
    # Requests served while the switch is off must not move the position, or the
    # first failure after it is turned on would land on an arbitrary request.
    for _ in range(2):
        assert client.get("/login").status_code == 200

    monkeypatch.setenv(SWITCH, "3")

    assert [client.get("/login").status_code for _ in range(3)] == [200, 200, 503]


@pytest.mark.parametrize("path", PROBE_PATHS)
def test_probes_and_metrics_keep_answering_while_the_switch_is_on(client, monkeypatch, path):
    monkeypatch.setenv(SWITCH, "1")

    assert client.get(path).status_code == 200


def test_a_deliberate_failure_is_counted_as_a_5xx(client, monkeypatch):
    labels = {"service": "frontend", "method": "GET", "route": "/login", "status": "503"}
    before = frontend_metrics.METRICS_REGISTRY.get_sample_value(
        "taskflow_http_requests_total", labels
    ) or 0.0

    monkeypatch.setenv(SWITCH, "1")
    client.get("/login")

    after = frontend_metrics.METRICS_REGISTRY.get_sample_value(
        "taskflow_http_requests_total", labels
    )

    assert after == before + 1


def request_routes():
    """Route label values currently present on the request counter."""
    return {
        sample.labels["route"]
        for metric in frontend_metrics.METRICS_REGISTRY.collect()
        for sample in metric.samples
        if sample.name == "taskflow_http_requests_total"
    }


def test_a_deliberate_failure_adds_no_route_label_value(client, monkeypatch):
    # The failure has to look like the route it replaced. A route label of its
    # own would grow the series the gate reads and leave the real route
    # reporting only its healthy requests.
    assert client.get("/login").status_code == 200
    before = request_routes()

    monkeypatch.setenv(SWITCH, "1")
    assert client.get("/login").status_code == 503

    assert request_routes() == before
    assert "/login" in before
