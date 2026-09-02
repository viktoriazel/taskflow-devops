"""Shared fixtures for the Backend service test suite.

PostgreSQL, S3 and the Worker HTTP calls are replaced, and unexpected access to
any of them fails the test loudly rather than passing against a fake. Everything
else runs as the real code in ``backend/app.py``.
"""

import importlib.util
import os
import sys
import types
from pathlib import Path

import pytest
import requests

SERVICE_DIR = Path(__file__).resolve().parents[1]
# Unique name, not "app": frontend/app.py would collide with it in a repo-wide run.
APP_MODULE_NAME = "taskflow_backend_app"

# pytest puts backend/tests on sys.path, not backend/, where backend_metrics sits.
if str(SERVICE_DIR) not in sys.path:
    sys.path.insert(0, str(SERVICE_DIR))

# Stubbed to raise until a test opts in, so an unexpected query cannot pass unnoticed.
DB_FUNCTIONS = (
    "add_file_to_todo",
    "create_todo_record",
    "create_user",
    "delete_completed_todo",
    "find_todo_by_id",
    "find_user_by_username",
    "get_all_todos",
    "mark_todo_as_done",
)

# Set unconditionally, never via setdefault: real AWS credentials from the shell
# or backend/.env must not leak into the test run. These values resolve to nothing.
FAKE_ENVIRONMENT = {
    "AWS_REGION": "eu-north-1",
    "AWS_DEFAULT_REGION": "eu-north-1",
    "AWS_ACCESS_KEY_ID": "testing",
    "AWS_SECRET_ACCESS_KEY": "testing",
    "AWS_SESSION_TOKEN": "testing",
    "AWS_EC2_METADATA_DISABLED": "true",
    "S3_BUCKET_NAME": "taskflow-tests-not-a-real-bucket",
    "WORKER_URL": "http://worker.invalid:6000",
}

os.environ.update(FAKE_ENVIRONMENT)

# Cleared so the suite observes the defaults, not a stray shell value.
CLEARED_ENVIRONMENT = ("APP_VERSION", "GIT_COMMIT", "RELEASE_REF", "TASKFLOW_FAIL_EVERY")

for variable in CLEARED_ENVIRONMENT:
    os.environ.pop(variable, None)


def _unstubbed(function_name):
    """Return a placeholder that fails the test if the route hits the database."""
    def refuse(*args, **kwargs):
        raise AssertionError(
            f"db.{function_name}() was called, but this test never stubbed it. "
            "Backend tests must not reach PostgreSQL — patch the function on "
            "the app module with monkeypatch if the route is meant to use it."
        )

    return refuse


class NoS3:
    """Stand-in for the boto3 S3 client: every operation fails the test.

    ``pytest.fail`` rather than ``raise AssertionError``: upload_file() wraps its
    S3 call in ``except Exception``, which would swallow the guard and answer a
    plausible 503. What pytest.fail raises derives from BaseException instead.
    """

    def __getattr__(self, operation):
        def refuse(*args, **kwargs):
            pytest.fail(
                f"s3_client.{operation}() was called — a Backend test tried to "
                "reach Amazon S3. Backend tests must not touch the bucket.",
                pytrace=False,
            )

        return refuse


class NoNetwork:
    """Stand-in for the requests module: every HTTP verb fails the test.

    Exception classes come from the real module because notify_worker() names
    ``requests.RequestException`` in its except clause, which Python evaluates
    before matching. pytest.fail raises nothing that clause can catch.
    """

    def __getattr__(self, name):
        attribute = getattr(requests, name, None)
        if isinstance(attribute, type) and issubclass(attribute, BaseException):
            return attribute

        def refuse(*args, **kwargs):
            pytest.fail(
                f"requests.{name}() was called — a Backend test tried to reach "
                "the Worker over HTTP. Backend tests must stay offline.",
                pytrace=False,
            )

        return refuse


@pytest.fixture(scope="session")
def backend_app():
    """Load backend/app.py once, with db.py replaced by an in-memory stub."""
    db_stub = types.ModuleType("db")
    # Called at import time; the real one runs CREATE TABLE against RDS.
    db_stub.init_database = lambda: None
    for function_name in DB_FUNCTIONS:
        setattr(db_stub, function_name, _unstubbed(function_name))

    sys.modules["db"] = db_stub

    spec = importlib.util.spec_from_file_location(APP_MODULE_NAME, SERVICE_DIR / "app.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[APP_MODULE_NAME] = module
    spec.loader.exec_module(module)

    module.app.config["TESTING"] = True
    return module


@pytest.fixture(autouse=True)
def offline(backend_app, monkeypatch):
    """Fail any test that reaches Amazon S3 or the Worker."""
    monkeypatch.setattr(backend_app, "s3_client", NoS3())
    monkeypatch.setattr(backend_app, "requests", NoNetwork())


@pytest.fixture
def client(backend_app):
    """Flask test client for the real Backend application object."""
    return backend_app.app.test_client()
