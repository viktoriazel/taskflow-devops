"""Shared fixtures for the Worker service test suite.

worker.py requires AWS_REGION and SNS_TOPIC_ARN at import time, so the suite
supplies fake values. The SNS client is then replaced by a guard, so no test can
publish to a real Amazon SNS topic.
"""

import importlib.util
import os
import sys
from pathlib import Path

import pytest

SERVICE_DIR = Path(__file__).resolve().parents[1]
MODULE_NAME = "taskflow_worker"

# Set unconditionally, never via setdefault: real AWS credentials or a real topic
# ARN from the shell or worker/.env must not leak into the test run.
FAKE_ENVIRONMENT = {
    "AWS_REGION": "eu-north-1",
    "AWS_DEFAULT_REGION": "eu-north-1",
    "AWS_ACCESS_KEY_ID": "testing",
    "AWS_SECRET_ACCESS_KEY": "testing",
    "AWS_SESSION_TOKEN": "testing",
    "AWS_EC2_METADATA_DISABLED": "true",
    "SNS_TOPIC_ARN": "arn:aws:sns:eu-north-1:000000000000:taskflow-tests-not-a-real-topic",
}

os.environ.update(FAKE_ENVIRONMENT)


class NoSns:
    """Stand-in for the boto3 SNS client: every operation fails the test.

    ``pytest.fail`` rather than ``raise AssertionError``: /notify wraps its
    publish call in ``except Exception``, which would swallow the guard and
    answer a plausible 500. What pytest.fail raises derives from BaseException.
    """

    def __getattr__(self, operation):
        def refuse(*args, **kwargs):
            pytest.fail(
                f"sns_client.{operation}() was called — a Worker test tried to "
                "reach Amazon SNS. Worker tests must not publish anything.",
                pytrace=False,
            )

        return refuse


@pytest.fixture(scope="session")
def worker_module():
    """Load worker/worker.py once, under its own module name."""
    spec = importlib.util.spec_from_file_location(MODULE_NAME, SERVICE_DIR / "worker.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[MODULE_NAME] = module
    spec.loader.exec_module(module)

    module.app.config["TESTING"] = True
    return module


@pytest.fixture(autouse=True)
def no_sns(worker_module, monkeypatch):
    """Fail any test that reaches Amazon SNS."""
    monkeypatch.setattr(worker_module, "sns_client", NoSns())


@pytest.fixture
def client(worker_module):
    """Flask test client for the real Worker application object."""
    return worker_module.app.test_client()
