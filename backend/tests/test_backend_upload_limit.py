"""The JSON error handler for oversized uploads (HTTP 413).

The production limit is 30 MB; the test lowers MAX_CONTENT_LENGTH so it does not
have to push a real 30 MB body through the test client.
"""

import io

SMALL_LIMIT_BYTES = 1024


def test_upload_over_the_size_limit_returns_the_json_413_handler(
    client, backend_app, monkeypatch
):
    monkeypatch.setitem(backend_app.app.config, "MAX_CONTENT_LENGTH", SMALL_LIMIT_BYTES)
    monkeypatch.setattr(
        backend_app,
        "find_todo_by_id",
        lambda todo_id: {
            "id": todo_id,
            "title": "Upload target",
            "done": False,
            "file_keys": [],
            "user_id": 42,
        },
    )

    oversized = io.BytesIO(b"x" * (SMALL_LIMIT_BYTES * 4))

    response = client.post(
        "/todos/1/upload",
        headers={"X-User-Id": "42"},
        data={"file": (oversized, "too-big.txt")},
        content_type="multipart/form-data",
    )

    assert response.status_code == 413
    # The message quotes the production 30 MB limit, not the lowered test value.
    assert response.get_json() == {
        "error": "File is too large. Maximum allowed size is 30 MB.",
    }
