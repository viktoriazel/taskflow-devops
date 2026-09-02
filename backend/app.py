"""
Backend Flask API for the Todo AWS DevOps Project.

This Backend service:
- manages todo items
- stores data in PostgreSQL / AWS RDS
- uploads files to AWS S3
- generates presigned URLs for file access
- sends events to the Worker service
"""

import os

import boto3
import requests
from dotenv import load_dotenv
from flask import Flask, jsonify, redirect, request
from werkzeug.security import check_password_hash, generate_password_hash
from werkzeug.utils import secure_filename

from backend_metrics import (
    init_metrics,
    record_s3_failure,
    record_todo_created,
    record_worker_failure,
)
from db import (
    add_file_to_todo,
    create_todo_record,
    create_user,
    delete_completed_todo,
    find_todo_by_id,
    find_user_by_username,
    get_all_todos,
    init_database,
    mark_todo_as_done,
)

load_dotenv()

app = Flask(__name__)
# Limit uploads to 30 MB to avoid very large files.
app.config["MAX_CONTENT_LENGTH"] = 30 * 1024 * 1024

init_metrics(app)

init_database()

WORKER_URL = os.getenv("WORKER_URL", "http://127.0.0.1:6000")
AWS_REGION = os.getenv("AWS_REGION")
S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME")
ALLOWED_EXTENSIONS = {"jpg", "jpeg", "png", "gif", "pdf", "txt"}

s3_client = boto3.client(
    "s3",
    region_name=AWS_REGION,
)


def notify_worker(event, title):
    """
    Send an event notification to the Worker service.

    Posts a JSON body with the event name and todo title to the Worker's
    /notify endpoint. If the Worker is unavailable, the error is logged as
    a warning so the main request still succeeds.

    Args:
        event (str): The event name, e.g. "todo_created", "todo_completed",
            or "file_uploaded".
        title (str): The title of the todo that triggered the event.

    Side Effects:
        - Sends a POST request to the Worker service at WORKER_URL/notify.
    """
    try:
        requests.post(
            f"{WORKER_URL}/notify",
            json={
                "event": event,
                "title": title,
            },
            timeout=5,
        )
    except requests.RequestException as e:
        record_worker_failure()
        app.logger.warning(
            "Worker notification failed for event '%s' on task '%s': %s",
            event,
            title,
            e,
        )


def allowed_file(filename):
    """Return True if filename has an allowed extension."""
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


def get_request_user_id():
    """
    Read the X-User-Id request header and return it as an int.

    The Frontend sets this header on every authenticated request using
    the user ID stored in the browser session.

    Returns:
        int: The user ID from the header.
        None: If the header is missing or not a valid integer.
    """
    raw = request.headers.get("X-User-Id")
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


@app.errorhandler(413)
def file_too_large(e):
    """Return a clear JSON error when an uploaded file exceeds MAX_CONTENT_LENGTH."""
    return jsonify({
        "error": "File is too large. Maximum allowed size is 30 MB.",
    }), 413


@app.route("/health", methods=["GET"])
def health_check():
    """
    Return the health status of the backend service.

    Used by load balancers and monitoring tools to check that the
    service is running and responding to requests.

    Returns:
        JSON {"service": "backend", "status": "ok"}, HTTP 200.
    """
    return jsonify({
        "service": "backend",
        "status": "ok",
    }), 200


@app.route("/live", methods=["GET"])
def liveness_check():
    """Kubernetes liveness probe — confirms this worker can complete an HTTP round trip.

    Makes no DB or AWS calls.
    """
    return jsonify({
        "service": "backend",
        "check": "live",
        "status": "ok",
    }), 200


@app.route("/ready", methods=["GET"])
def readiness_check():
    """Kubernetes readiness probe — makes no new DB call.

    init_database() already fails fast at startup.
    """
    return jsonify({
        "service": "backend",
        "check": "ready",
        "status": "ok",
    }), 200


@app.route("/auth/register", methods=["POST"])
def register():
    """
    Register a new user account.

    Reads a JSON body with "username" and "password" fields. Validates
    that the username is not already taken and the password is at least
    8 characters, then stores a Werkzeug password hash in the
    PostgreSQL users table.

    Returns:
        JSON {"id", "username"}, HTTP 201 on success.
        JSON {"error": ...}, HTTP 400 if validation fails.
        JSON {"error": "Username already taken"}, HTTP 409 if duplicate.

    Side Effects:
        - Writes a new row to the PostgreSQL users table.
    """
    data = request.get_json()

    if not data:
        return jsonify({
            "error": "JSON body is required",
        }), 400

    username = (data.get("username") or "").strip()
    password = data.get("password") or ""

    if not username:
        return jsonify({
            "error": "Username is required",
        }), 400

    if len(password) < 8:
        return jsonify({
            "error": "Password must be at least 8 characters",
        }), 400

    if find_user_by_username(username) is not None:
        return jsonify({
            "error": "Username already taken",
        }), 409

    password_hash = generate_password_hash(password)
    user = create_user(username, password_hash)

    app.logger.info("User registered: user_id=%s", user["id"])

    return jsonify({
        "id": user["id"],
        "username": user["username"],
    }), 201


@app.route("/auth/login", methods=["POST"])
def login():
    """
    Authenticate a user and return their account info.

    Reads a JSON body with "username" and "password" fields. Looks up the
    user in PostgreSQL and verifies the Werkzeug password hash. No session is
    created here — the Frontend stores the returned user ID in its own
    session and sends it back as an X-User-Id header on future requests.

    Returns:
        JSON {"id", "username"}, HTTP 200 on success.
        JSON {"error": "Invalid username or password"}, HTTP 401 on failure.
    """
    data = request.get_json()

    if not data:
        return jsonify({
            "error": "JSON body is required",
        }), 400

    username = (data.get("username") or "").strip()
    password = data.get("password") or ""

    if not username or not password:
        return jsonify({
            "error": "Username and password are required",
        }), 400

    user = find_user_by_username(username)

    if user is None or not check_password_hash(user["password_hash"], password):
        return jsonify({
            "error": "Invalid username or password",
        }), 401

    app.logger.info("User logged in: user_id=%s", user["id"])

    return jsonify({
        "id": user["id"],
        "username": user["username"],
    }), 200


@app.route("/todos", methods=["POST"])
def create_todo():
    """
    Create a new todo item for the current user.

    Reads the user ID from the X-User-Id header and the todo title from
    the JSON body. Saves the new todo to PostgreSQL and notifies the Worker
    service so an SNS notification can be sent.

    Returns:
        JSON todo dict, HTTP 201 on success.
        JSON {"error": ...}, HTTP 401 if not authenticated or 400 if title is missing.

    Side Effects:
        - Inserts a new row into the PostgreSQL todos table.
        - Sends a POST request to the Worker service (fire-and-forget).
    """
    user_id = get_request_user_id()

    if user_id is None:
        return jsonify({
            "error": "Authentication required",
        }), 401

    data = request.get_json()

    if not data or "title" not in data:
        return jsonify({
            "error": "Title is required",
        }), 400

    title = data["title"].strip()

    if not title:
        return jsonify({
            "error": "Title cannot be empty",
        }), 400

    todo = create_todo_record(title, user_id)
    record_todo_created()

    app.logger.info("Todo created: todo_id=%s, user_id=%s", todo["id"], user_id)

    notify_worker("todo_created", title)

    return jsonify(todo), 201


@app.route("/todos", methods=["GET"])
def get_todos():
    """
    Return all todo items belonging to the requesting user.

    Reads the user ID from the X-User-Id header and fetches only that
    user's todos from PostgreSQL, ordered by insertion order.

    Returns:
        JSON array of todo dicts, HTTP 200.
        JSON {"error": ...}, HTTP 401 if not authenticated.
    """
    user_id = get_request_user_id()

    if user_id is None:
        return jsonify({
            "error": "Authentication required",
        }), 401

    todos = get_all_todos(user_id)
    return jsonify(todos), 200


@app.route("/todos/<int:todo_id>", methods=["PATCH"])
def mark_todo_done(todo_id):
    """
    Mark a todo item as completed.

    Checks that the todo exists and belongs to the current user before
    setting done=TRUE in PostgreSQL. Also notifies the Worker service.

    Args:
        todo_id (int): The ID of the todo to mark as done (from URL path).

    Returns:
        JSON updated todo dict, HTTP 200 on success.
        JSON {"error": ...}, HTTP 401/403/404 on auth or lookup failure.

    Side Effects:
        - Updates the PostgreSQL todos row (done = TRUE).
        - Sends a POST request to the Worker service (fire-and-forget).
    """
    user_id = get_request_user_id()

    if user_id is None:
        return jsonify({
            "error": "Authentication required",
        }), 401

    todo = find_todo_by_id(todo_id)

    if todo is None:
        return jsonify({
            "error": "Todo not found",
        }), 404

    if todo["user_id"] != user_id:
        return jsonify({
            "error": "Access denied",
        }), 403

    updated = mark_todo_as_done(todo_id)

    if updated is None:
        return jsonify({
            "error": "Todo not found",
        }), 404

    app.logger.info("Todo marked as done: todo_id=%s, user_id=%s", todo_id, user_id)

    notify_worker("todo_completed", updated["title"])

    return jsonify(updated), 200


@app.route("/todos/<int:todo_id>", methods=["DELETE"])
def delete_todo(todo_id):
    """
    Delete a completed todo item.

    Checks ownership before deleting. Only todos that are already marked
    as done can be deleted — attempting to delete an incomplete todo
    returns a 400 error.

    Args:
        todo_id (int): The ID of the todo to delete (from URL path).

    Returns:
        JSON {"message", "todo"}, HTTP 200 on success.
        JSON {"error": ...}, HTTP 400 if not completed, 401/403/404 otherwise.

    Side Effects:
        - Deletes the row from the PostgreSQL todos table.
    """
    user_id = get_request_user_id()

    if user_id is None:
        return jsonify({
            "error": "Authentication required",
        }), 401

    todo = find_todo_by_id(todo_id)

    if todo is None:
        return jsonify({
            "error": "Todo not found",
        }), 404

    if todo["user_id"] != user_id:
        return jsonify({
            "error": "Access denied",
        }), 403

    deleted_todo, error = delete_completed_todo(todo_id)

    if error == "not_found":
        return jsonify({
            "error": "Todo not found",
        }), 404

    if error == "not_completed":
        return jsonify({
            "error": "Only completed todos can be deleted",
        }), 400

    return jsonify({
        "message": "Todo deleted successfully",
        "todo": deleted_todo,
    }), 200


@app.route("/todos/<int:todo_id>/upload", methods=["POST"])
def upload_file(todo_id):
    """
    Upload a file to AWS S3 for a specific todo item.

    Sanitises the filename, uploads the file to S3 under the key
    "uploads/todo-{todo_id}/{filename}", stores that key in the PostgreSQL
    todos.file_keys column, and notifies the Worker service.

    Args:
        todo_id (int): The ID of the todo to attach the file to (from URL).

    Returns:
        JSON {"message", "todo"}, HTTP 200 on success.
        JSON {"error": ...}, HTTP 400/401/403/404 on failure.

    Side Effects:
        - Uploads the file to the S3 bucket (S3_BUCKET_NAME).
        - Updates the PostgreSQL todos.file_keys column.
        - Sends a POST request to the Worker service (fire-and-forget).
    """
    user_id = get_request_user_id()

    if user_id is None:
        return jsonify({
            "error": "Authentication required",
        }), 401

    todo = find_todo_by_id(todo_id)

    if todo is None:
        return jsonify({
            "error": "Todo not found",
        }), 404

    if todo["user_id"] != user_id:
        return jsonify({
            "error": "Access denied",
        }), 403

    if "file" not in request.files:
        return jsonify({
            "error": "File is required",
        }), 400

    uploaded_file = request.files["file"]

    if uploaded_file.filename == "":
        return jsonify({
            "error": "File name cannot be empty",
        }), 400

    filename = secure_filename(uploaded_file.filename)

    if not allowed_file(filename):
        return jsonify({
            "error": "File type is not allowed",
        }), 400

    file_key = f"uploads/todo-{todo_id}/{filename}"

    try:
        s3_client.upload_fileobj(
            uploaded_file,
            S3_BUCKET_NAME,
            file_key,
            ExtraArgs={
                "ContentType": uploaded_file.content_type,
            },
        )
    except Exception as e:
        record_s3_failure()
        app.logger.error(
            "S3 upload failed for todo %s, file '%s': %s",
            todo_id,
            filename,
            e,
        )
        return jsonify({
            "error": "Failed to upload file to S3",
        }), 503

    updated_todo = add_file_to_todo(todo_id, file_key)

    app.logger.info(
        "File uploaded: todo_id=%s, user_id=%s, filename=%s",
        todo_id,
        user_id,
        filename,
    )

    notify_worker("file_uploaded", updated_todo["title"])

    return jsonify({
        "message": "File uploaded successfully",
        "todo": updated_todo,
    }), 200


@app.route("/files/<path:file_key>", methods=["GET"])
def view_uploaded_file(file_key):
    """
    Generate a presigned S3 URL and redirect the browser to the file.

    Parses the todo ID from the S3 key path, verifies that the todo
    belongs to the current user, confirms the key is attached to that todo,
    then generates a short-lived (1-hour) presigned URL that gives the
    browser direct access to the S3 object.

    Args:
        file_key (str): The S3 object key from the URL path,
            e.g. "uploads/todo-5/report.pdf".

    Returns:
        HTTP 302 redirect to the presigned S3 URL on success.
        JSON {"error": ...}, HTTP 400/401/403/404 on failure.
    """
    user_id = get_request_user_id()

    if user_id is None:
        return jsonify({
            "error": "Authentication required",
        }), 401

    if not file_key.startswith("uploads/"):
        return jsonify({
            "error": "Invalid file path",
        }), 400

    # Parse todo_id from key format: "uploads/todo-{todo_id}/{filename}"
    try:
        todo_segment = file_key.split("/")[1]
        if not todo_segment.startswith("todo-"):
            raise ValueError
        todo_id = int(todo_segment[5:])
    except (IndexError, ValueError):
        return jsonify({
            "error": "Invalid file path",
        }), 400

    todo = find_todo_by_id(todo_id)

    if todo is None:
        return jsonify({
            "error": "Todo not found",
        }), 404

    if todo["user_id"] != user_id:
        return jsonify({
            "error": "Access denied",
        }), 403

    if file_key not in todo["file_keys"]:
        return jsonify({
            "error": "File not found",
        }), 404

    presigned_url = s3_client.generate_presigned_url(
        "get_object",
        Params={
            "Bucket": S3_BUCKET_NAME,
            "Key": file_key,
            "ResponseContentDisposition": "inline",
        },
        ExpiresIn=3600,
    )

    return redirect(presigned_url)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
