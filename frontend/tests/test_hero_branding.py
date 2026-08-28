"""Tests for the TaskFlow hero branding and main page rendering."""

import pytest

FAKE_TODOS = [
    {
        "id": 1,
        "title": "Prepare project presentation",
        "done": False,
        "file_keys": [],
    },
]


class StubBackend:
    """Minimal Backend stub used to render the main page in tests."""

    class Response:
        def __init__(self, payload):
            self.payload = payload

        def json(self):
            return self.payload

    def __init__(self, todos):
        self.todos = todos

    def get(self, *args, **kwargs):
        return self.Response(self.todos)


@pytest.fixture
def page(client, frontend_app, monkeypatch):
    """Render the main page for a logged-in user."""
    monkeypatch.setattr(frontend_app, "requests", StubBackend(FAKE_TODOS))

    with client.session_transaction() as browser_session:
        browser_session["user_id"] = 1
        browser_session["username"] = "viktoria"

    response = client.get("/")

    assert response.status_code == 200
    return response.get_data(as_text=True)


def test_hero_shows_the_plus_wordmark(page):
    assert '<span class="brand-plus">PLUS</span>' in page


def test_hero_shows_the_brand_tagline(page):
    assert "Make every task a PLUS." in page


def test_the_wordmark_stays_on_the_title_line(page):
    """Keep PLUS and the sparkle inside the main heading."""
    heading = page.split("<h1>", 1)[1].split("</h1>", 1)[0]

    assert "TaskFlow" in heading
    assert "brand-plus" in heading
    assert "brand-sparkle" in heading


def test_the_rest_of_the_page_still_renders(page):
    """Check that the page content still renders below the hero."""
    assert "Prepare project presentation" in page
    assert "Mark Complete" in page
