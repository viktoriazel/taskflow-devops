"""Frontend service for TaskFlow."""

import functools
import os

import requests
from dotenv import load_dotenv
from flask import Flask, redirect, render_template, request, session

from frontend_metrics import init_metrics, record_backend_failure

load_dotenv()

app = Flask(__name__)
app.secret_key = os.getenv("SECRET_KEY")

app.config.update(
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
)

init_metrics(app)

BACKEND_URL = os.getenv("BACKEND_URL", "http://127.0.0.1:5000")


def login_required(f):
    """
    Decorator that redirects unauthenticated users to the login page.

    Checks for "user_id" in the Flask session before running the
    decorated route. If it is not set, the user is redirected to /login.

    Args:
        f: The route function to protect.

    Returns:
        The wrapped function with the session check applied.
    """
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if "user_id" not in session:
            return redirect("/login")
        return f(*args, **kwargs)
    return decorated


def auth_headers():
    """
    Return the X-User-Id header dict needed for Backend API calls.

    The Backend authenticates requests using this header instead of
    cookies. The value is read from the current Flask session.

    Returns:
        dict, e.g. {"X-User-Id": "42"}.
    """
    return {"X-User-Id": str(session["user_id"])}


@app.route("/login", methods=["GET", "POST"])
def login():
    """
    Show the login form or handle a login form submission.

    GET:  Renders the login.html template.
    POST: Forwards the username and password to the Backend /auth/login
          endpoint. On success, stores the user ID and username in the
          Flask session and redirects to the home page.

    Side Effects:
        - Sets session["user_id"] and session["username"] on successful login.
    """
    if request.method == "GET":
        return render_template("login.html")

    username = request.form.get("username", "").strip()
    password = request.form.get("password", "")

    response = requests.post(
        f"{BACKEND_URL}/auth/login",
        json={"username": username, "password": password},
        timeout=5,
    )

    if response.status_code == 200:
        user = response.json()
        session["user_id"] = user["id"]
        session["username"] = user["username"]
        return redirect("/")

    error = response.json().get("error", "Login failed")
    return render_template("login.html", error=error)


@app.route("/register", methods=["GET", "POST"])
def register():
    """
    Show the registration form or handle a registration form submission.

    GET:  Renders the register.html template.
    POST: Forwards the username and password to the Backend /auth/register
          endpoint. On success, stores the user ID and username in the
          Flask session and redirects to the home page.

    Side Effects:
        - Sets session["user_id"] and session["username"] on successful registration.
    """
    if request.method == "GET":
        return render_template("register.html")

    username = request.form.get("username", "").strip()
    password = request.form.get("password", "")

    response = requests.post(
        f"{BACKEND_URL}/auth/register",
        json={"username": username, "password": password},
        timeout=5,
    )

    if response.status_code == 201:
        user = response.json()
        session["user_id"] = user["id"]
        session["username"] = user["username"]
        return redirect("/")

    error = response.json().get("error", "Registration failed")
    return render_template("register.html", error=error)


@app.route("/logout", methods=["POST"])
def logout():
    """
    Clear the session and redirect to the login page.

    Removes all keys from the Flask session, including user_id and
    username, effectively logging the user out.

    Side Effects:
        - Clears the Flask session.
    """
    session.clear()
    return redirect("/login")


@app.route("/")
@login_required
def index():
    """
    Show the main page with the user's todo list.

    Fetches all todos from the Backend and passes them to the index.html
    template for rendering.

    Side Effects:
        - Sends a GET request to the Backend /todos endpoint.
    """
    response = requests.get(
        f"{BACKEND_URL}/todos",
        headers=auth_headers(),
        timeout=5,
    )
    todos = response.json()

    return render_template("index.html", todos=todos)


@app.route("/add", methods=["POST"])
@login_required
def add_todo():
    """
    Send a new todo item to the Backend.

    Reads the todo title from the HTML form. If the title is not empty,
    forwards it to the Backend POST /todos endpoint.

    Side Effects:
        - Sends a POST request to the Backend /todos endpoint if title is set.
        - Redirects to the home page regardless of the result.
    """
    title = request.form.get("title")

    if title:
        requests.post(
            f"{BACKEND_URL}/todos",
            json={"title": title},
            headers=auth_headers(),
            timeout=5,
        )

    return redirect("/")


@app.route("/done/<int:todo_id>", methods=["POST"])
@login_required
def mark_done(todo_id):
    """
    Ask the Backend to mark a todo as done.

    HTML forms can only send GET or POST, so this route accepts a POST
    and proxies it as a PATCH request to the Backend.

    Args:
        todo_id (int): The ID of the todo to mark as done (from URL path).

    Side Effects:
        - Sends a PATCH request to the Backend /todos/{todo_id} endpoint.
        - Redirects to the home page.
    """
    requests.patch(
        f"{BACKEND_URL}/todos/{todo_id}",
        headers=auth_headers(),
        timeout=5,
    )
    return redirect("/")


@app.route("/delete/<int:todo_id>", methods=["POST"])
@login_required
def delete_todo(todo_id):
    """
    Ask the Backend to delete a completed todo.

    Proxies the browser's form POST as a DELETE request to the Backend.

    Args:
        todo_id (int): The ID of the todo to delete (from URL path).

    Side Effects:
        - Sends a DELETE request to the Backend /todos/{todo_id} endpoint.
        - Redirects to the home page.
    """
    requests.delete(
        f"{BACKEND_URL}/todos/{todo_id}",
        headers=auth_headers(),
        timeout=5,
    )
    return redirect("/")


@app.route("/upload/<int:todo_id>", methods=["POST"])
@login_required
def upload_file(todo_id):
    """
    Forward an uploaded file to the Backend.

    Re-packages the multipart file from the browser form and sends it
    to the Backend POST /todos/{todo_id}/upload endpoint.

    Args:
        todo_id (int): The ID of the todo to attach the file to (from URL).

    Side Effects:
        - Sends a multipart POST request to the Backend if a file is present.
        - Redirects to the home page.
    """
    uploaded_file = request.files.get("file")

    if uploaded_file:
        files = {
            "file": (
                uploaded_file.filename,
                uploaded_file.stream,
                uploaded_file.content_type,
            )
        }

        requests.post(
            f"{BACKEND_URL}/todos/{todo_id}/upload",
            files=files,
            headers=auth_headers(),
            timeout=10,
        )

    return redirect("/")


@app.route("/files/<path:file_key>")
@login_required
def view_uploaded_file(file_key):
    """
    Fetch an uploaded file from the Backend and return it to the browser.

    Forwards the file key to the Backend GET /files/{file_key} endpoint.
    The requests library follows the Backend's redirect to S3 automatically,
    so response.content is the final file content from S3.

    Args:
        file_key (str): The S3 object key forwarded as a URL path segment.

    Returns:
        The raw file content with Content-Type and Content-Disposition headers.
    """
    response = requests.get(
        f"{BACKEND_URL}/files/{file_key}",
        headers=auth_headers(),
        timeout=10,
    )

    if response.status_code != 200:
        # 4xx answers are ownership and lookup outcomes, not a failing dependency.
        if response.status_code >= 500:
            record_backend_failure()
        try:
            error_message = response.json().get("error", "File could not be loaded.")
        except Exception:
            error_message = "File could not be loaded."
        return error_message, response.status_code, {"Content-Type": "text/plain"}

    return (
        response.content,
        response.status_code,
        {
            "Content-Type": response.headers.get(
                "Content-Type",
                "application/octet-stream",
            ),
            "Content-Disposition": "inline",
        },
    )


@app.route("/health")
def health_check():
    """
    Return the health status of the frontend service.

    Used by load balancers and monitoring tools to check that the
    service is running.

    Returns:
        dict {"status": "frontend is running"}, HTTP 200.
    """
    return {"status": "frontend is running"}


@app.route("/live")
def liveness_check():
    """Kubernetes liveness probe — confirms this worker can complete an HTTP round trip.

    Makes no backend or AWS calls.
    """
    return {"status": "alive"}, 200


@app.route("/ready")
def readiness_check():
    """Kubernetes/ALB readiness probe — confirms SECRET_KEY is loaded, without exposing it.

    SECRET_KEY is what signs the session cookie, so the service is not usable without it.
    """
    if not app.secret_key:
        return {"status": "not ready"}, 503
    return {"status": "ready"}, 200


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000, debug=False)
