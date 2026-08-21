"""The message body built by build_notification_message().

It is a pure function — no SNS involved — so it is called directly rather than
through POST /notify.
"""

import pytest

BACKEND_EVENTS = ["todo_created", "todo_completed", "file_uploaded"]


@pytest.mark.parametrize("event", BACKEND_EVENTS)
def test_message_carries_the_event_and_title(worker_module, event):
    message = worker_module.build_notification_message(event, "Buy milk")

    assert message == f"TaskFlow notification\n\nEvent: {event}\nTask: Buy milk\n"


def test_title_is_copied_through_verbatim(worker_module):
    """A title with punctuation and spacing must not be reformatted or escaped."""
    title = "Review Q3 report: pages 4-7 (draft)"

    message = worker_module.build_notification_message("todo_created", title)

    assert f"Task: {title}\n" in message
