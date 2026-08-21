"""A deliberately failing test, used to demonstrate the CI failure path.

This is not a test of Backend behaviour. It is skipped by default and only runs
when TASKFLOW_FORCE_TEST_FAILURE=1 is set.
"""

import os

import pytest

ENABLE_VARIABLE = "TASKFLOW_FORCE_TEST_FAILURE"


@pytest.mark.skipif(
    os.getenv(ENABLE_VARIABLE) != "1",
    reason=f"Deliberate-failure test is disarmed. Set {ENABLE_VARIABLE}=1 to arm it.",
)
def test_arming_the_switch_fails_the_build():
    pytest.fail(
        f"Deliberate failure: {ENABLE_VARIABLE}=1 is set. This test exists to show "
        "that a failing test turns the build red. Unset the variable to return the "
        "suite to green."
    )
