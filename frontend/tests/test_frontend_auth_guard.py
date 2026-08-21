"""Unauthenticated access to the Frontend's protected routes.

A session-less request to a protected route must redirect to /login.
PROTECTED_ROUTES is the full set of @login_required routes in frontend/app.py.
"""

import pytest

PROTECTED_ROUTES = [
    ("GET", "/"),
    ("POST", "/add"),
    ("POST", "/done/1"),
    ("POST", "/delete/1"),
    ("POST", "/upload/1"),
    ("GET", "/files/uploads/todo-1/report.pdf"),
]


@pytest.mark.parametrize(("method", "path"), PROTECTED_ROUTES)
def test_unauthenticated_request_is_redirected_to_login(client, method, path):
    response = client.open(path, method=method)

    assert response.status_code == 302
    assert response.headers["Location"] == "/login"


def test_login_page_is_reachable_without_a_session(client):
    """Guards against the redirect tests passing because *everything* redirects."""
    response = client.get("/login")

    assert response.status_code == 200
