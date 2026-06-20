"""Frontend service for TaskFlow."""

import os

import requests
from dotenv import load_dotenv
from flask import Flask, redirect, render_template, request

load_dotenv()

app = Flask(__name__)

BACKEND_URL = os.getenv("BACKEND_URL", "http://127.0.0.1:5000")


@app.route("/")
def index():
    """Show main page with todos."""
    response = requests.get(f"{BACKEND_URL}/todos", timeout=5)
    todos = response.json()

    return render_template("index.html", todos=todos)


@app.route("/add", methods=["POST"])
def add_todo():
    """Send new todo to backend."""
    title = request.form.get("title")

    if title:
        requests.post(
            f"{BACKEND_URL}/todos",
            json={"title": title},
            timeout=5,
        )

    return redirect("/")


@app.route("/done/<int:todo_id>", methods=["POST"])
def mark_done(todo_id):
    """Ask backend to mark todo as done."""
    requests.patch(f"{BACKEND_URL}/todos/{todo_id}", timeout=5)
    return redirect("/")


@app.route("/delete/<int:todo_id>", methods=["POST"])
def delete_todo(todo_id):
    """Ask backend to delete completed todo."""
    requests.delete(f"{BACKEND_URL}/todos/{todo_id}", timeout=5)
    return redirect("/")


@app.route("/upload/<int:todo_id>", methods=["POST"])
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
            timeout=10,
        )

    return redirect("/")


@app.route("/files/<path:file_key>")
def view_uploaded_file(file_key):
    """Get uploaded file from backend and show it in browser."""
    response = requests.get(f"{BACKEND_URL}/files/{file_key}", timeout=10)

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
    