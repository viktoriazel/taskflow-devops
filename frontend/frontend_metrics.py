"""Prometheus instrumentation for the Frontend service."""

import os
import time

from flask import g, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

SERVICE = "frontend"

DEPENDENCY_BACKEND = "backend"

UNKNOWN = "unknown"

# Stands in for a request that matched no rule.
UNMATCHED_ROUTE = "unmatched"

# Probe and scrape traffic, kept out of the request metrics.
EXCLUDED_ROUTES = frozenset({"/metrics", "/health", "/live", "/ready"})

LATENCY_BUCKETS = (0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, float("inf"))

_REQUEST_START = "taskflow_request_start"

# Application metrics only. Process and node metrics come from the monitoring
# stack, and every service shares these metric names, distinguished by `service`.
METRICS_REGISTRY = CollectorRegistry()

REQUESTS = Counter(
    "taskflow_http_requests_total",
    "HTTP requests handled, by route and response status.",
    ["service", "method", "route", "status"],
    registry=METRICS_REGISTRY,
)

REQUEST_DURATION = Histogram(
    "taskflow_http_request_duration_seconds",
    "HTTP request duration in seconds.",
    ["service", "method", "route"],
    buckets=LATENCY_BUCKETS,
    registry=METRICS_REGISTRY,
)

DEPENDENCY_FAILURES = Counter(
    "taskflow_dependency_failures_total",
    "Failed calls to an external dependency.",
    ["service", "dependency"],
    registry=METRICS_REGISTRY,
)

APP_INFO = Gauge(
    "taskflow_app_info",
    "Release identity of the running instance; the value is always 1.",
    ["service", "version", "git_sha", "release"],
    registry=METRICS_REGISTRY,
)


def release_labels():
    """Return the release identity, falling back to "unknown" outside a release."""
    return {
        "version": os.getenv("APP_VERSION", UNKNOWN),
        "git_sha": os.getenv("GIT_COMMIT", UNKNOWN),
        "release": os.getenv("RELEASE_REF", UNKNOWN),
    }


def record_backend_failure():
    """Count one Backend call that came back as a server error."""
    DEPENDENCY_FAILURES.labels(service=SERVICE, dependency=DEPENDENCY_BACKEND).inc()


def _route_label():
    """Return the matched Flask rule, or the unmatched placeholder."""
    rule = request.url_rule
    return rule.rule if rule is not None else UNMATCHED_ROUTE


def _start_timer():
    setattr(g, _REQUEST_START, time.perf_counter())


def _record_request(response):
    route = _route_label()
    start = g.pop(_REQUEST_START, None)

    if route in EXCLUDED_ROUTES:
        return response

    REQUESTS.labels(
        service=SERVICE,
        method=request.method,
        route=route,
        status=str(response.status_code),
    ).inc()

    if start is not None:
        REQUEST_DURATION.labels(
            service=SERVICE,
            method=request.method,
            route=route,
        ).observe(time.perf_counter() - start)

    return response


def _serve_metrics():
    """Expose this service's metrics in the Prometheus text format."""
    return generate_latest(METRICS_REGISTRY), 200, {"Content-Type": CONTENT_TYPE_LATEST}


def init_metrics(app):
    """Attach request instrumentation and the /metrics endpoint to app."""
    APP_INFO.labels(service=SERVICE, **release_labels()).set(1)

    app.before_request(_start_timer)
    app.after_request(_record_request)
    app.add_url_rule("/metrics", "metrics", _serve_metrics, methods=["GET"])

    return app
