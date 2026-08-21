"""Registration validation on POST /auth/register.

Only the database lookup and insert are stubbed. The rules being asserted —
the minimum password length, the duplicate-username response, and the decision
to hash before storing — are evaluated by the real route in backend/app.py.
"""

from werkzeug.security import check_password_hash

# Exactly eight characters: the shortest password the route is meant to accept,
# so the happy-path test doubles as the boundary case for the length check.
VALID_PASSWORD = "pass1234"


def test_password_shorter_than_eight_characters_is_rejected(client):
    response = client.post(
        "/auth/register",
        json={"username": "testuser", "password": "short"},
    )

    assert response.status_code == 400
    assert response.get_json() == {"error": "Password must be at least 8 characters"}


def test_duplicate_username_returns_409(client, backend_app, monkeypatch):
    monkeypatch.setattr(
        backend_app,
        "find_user_by_username",
        lambda username: {"id": 1, "username": username, "password_hash": "unused"},
    )

    response = client.post(
        "/auth/register",
        json={"username": "testuser", "password": VALID_PASSWORD},
    )

    assert response.status_code == 409
    assert response.get_json() == {"error": "Username already taken"}


def test_new_username_is_created_with_a_hashed_password(client, backend_app, monkeypatch):
    stored = {}

    def fake_create_user(username, password_hash):
        stored["username"] = username
        stored["password_hash"] = password_hash
        return {"id": 7, "username": username}

    monkeypatch.setattr(backend_app, "find_user_by_username", lambda username: None)
    monkeypatch.setattr(backend_app, "create_user", fake_create_user)

    response = client.post(
        "/auth/register",
        json={"username": "testuser", "password": VALID_PASSWORD},
    )

    assert response.status_code == 201
    assert response.get_json() == {"id": 7, "username": "testuser"}

    # The route must hand the database a Werkzeug hash, never the plaintext.
    assert stored["password_hash"] != VALID_PASSWORD
    assert check_password_hash(stored["password_hash"], VALID_PASSWORD)
