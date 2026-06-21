"""Frontend service for TaskFlow."""

import functools
import os

import requests
from dotenv import load_dotenv
from flask import Flask, redirect, render_template, request, session

load_dotenv()

app = Flask(__name__)
app.secret_key = os.getenv("SECRET_KEY")

BACKEND_URL = os.getenv("BACKEND_URL", "http://127.0.0.1:5000")


def login_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if "user_id" not in session:
            return redirect("/login")
        return f(*args, **kwargs)
    return decorated


def auth_headers():
    """Return X-User-Id header dict for backend API calls."""
    return {"X-User-Id": str(session["user_id"])}


@app.route("/login", methods=["GET", "POST"])
def login():
    """Show login form or handle login submission."""
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
    """Show registration form or handle registration submission."""
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
    """Clear session and redirect to login page."""
    session.clear()
    return redirect("/login")


@app.route("/")
@login_required
def index():
    """Show main page with todos."""
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
    """Send new todo to backend."""
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
    """Ask backend to mark todo as done."""
    requests.patch(
        f"{BACKEND_URL}/todos/{todo_id}",
        headers=auth_headers(),
        timeout=5,
    )
    return redirect("/")


@app.route("/delete/<int:todo_id>", methods=["POST"])
@login_required
def delete_todo(todo_id):
    """Ask backend to delete completed todo."""
    requests.delete(
        f"{BACKEND_URL}/todos/{todo_id}",
        headers=auth_headers(),
        timeout=5,
    )
    return redirect("/")


@app.route("/upload/<int:todo_id>", methods=["POST"])
@login_required
def upload_file(todo_id):
    """Send uploaded file to backend."""
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
    """Get uploaded file from backend and show it in browser."""
    response = requests.get(
        f"{BACKEND_URL}/files/{file_key}",
        headers=auth_headers(),
        timeout=10,
    )

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
    """Check frontend health."""
    return {"status": "frontend is running"}


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000, debug=False)
