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


def test_session_cookie_is_sent_with_its_protective_attributes(client):
    """The attributes are read from the app config for every session cookie.

    Logging out is the one route that changes the session without calling the
    Backend, so it is what this asserts on.
    """
    with client.session_transaction() as browser_session:
        browser_session["user_id"] = 1

    response = client.post("/logout")
    set_cookie = response.headers["Set-Cookie"]

    assert "Secure" in set_cookie
    assert "HttpOnly" in set_cookie
    assert "SameSite=Lax" in set_cookie
