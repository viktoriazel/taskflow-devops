"""Shared fixtures for the Frontend service test suite.

HTTP calls to the Backend are blocked, and an unexpected one fails the test
loudly. Everything else runs as the real code in ``frontend/app.py``.
"""

import importlib.util
import os
import sys
from pathlib import Path

import pytest

SERVICE_DIR = Path(__file__).resolve().parents[1]
# Unique name, not "app": backend/app.py would collide with it in a repo-wide run.
APP_MODULE_NAME = "taskflow_frontend_app"

# pytest puts frontend/tests on sys.path, not frontend/, where frontend_metrics sits.
if str(SERVICE_DIR) not in sys.path:
    sys.path.insert(0, str(SERVICE_DIR))

# Set unconditionally, never via setdefault: a real SECRET_KEY or BACKEND_URL
# from the shell or frontend/.env must not leak into the test run. The .invalid
# TLD never resolves, so a stray request cannot reach a real Backend either.
FAKE_ENVIRONMENT = {
    "SECRET_KEY": "taskflow-tests-not-a-real-secret",
    "BACKEND_URL": "http://backend.invalid:5000",
}

os.environ.update(FAKE_ENVIRONMENT)

# Cleared so the suite observes the defaults, not a stray shell value.
CLEARED_ENVIRONMENT = ("APP_VERSION", "GIT_COMMIT", "RELEASE_REF", "TASKFLOW_FAIL_EVERY")

for variable in CLEARED_ENVIRONMENT:
    os.environ.pop(variable, None)


class NoNetwork:
    """Stand-in for the requests module: every HTTP verb fails the test.

    ``pytest.fail`` rather than ``raise AssertionError``: no route wraps its
    Backend call in a broad ``except`` today, but one added later would swallow
    an AssertionError. What pytest.fail raises derives from BaseException.
    """

    def __getattr__(self, verb):
        def refuse(*args, **kwargs):
            pytest.fail(
                f"requests.{verb}() was called — a Frontend test tried to reach "
                "the Backend over HTTP. Frontend tests must stay offline.",
                pytrace=False,
            )

        return refuse


@pytest.fixture(scope="session")
def frontend_app():
    """Load frontend/app.py once, under its own module name."""
    spec = importlib.util.spec_from_file_location(APP_MODULE_NAME, SERVICE_DIR / "app.py")
    module = importlib.util.module_from_spec(spec)
    # Registered before exec so Flask resolves root_path — and templates/ — from
    # the real file location.
    sys.modules[APP_MODULE_NAME] = module
    spec.loader.exec_module(module)

    module.app.config["TESTING"] = True
    return module


@pytest.fixture(autouse=True)
def offline(frontend_app, monkeypatch):
    """Fail any test that reaches the Backend over HTTP."""
    monkeypatch.setattr(frontend_app, "requests", NoNetwork())


@pytest.fixture
def client(frontend_app):
    """Flask test client for the real Frontend application object."""
    return frontend_app.app.test_client()
