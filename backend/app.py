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

init_database()

WORKER_URL = os.getenv("WORKER_URL", "http://127.0.0.1:6000")
AWS_REGION = os.getenv("AWS_REGION")
S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME")

s3_client = boto3.client(
    "s3",
    region_name=AWS_REGION,
)


def notify_worker(event, title):
    """
    Send an event notification to the Worker service.
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
    except requests.RequestException:
        pass


def get_request_user_id():
    """
    Read the X-User-Id request header and return it as an int.
    Returns None if the header is missing or not a valid integer.
    """
    raw = request.headers.get("X-User-Id")
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


@app.route("/health", methods=["GET"])
def health_check():
    """
    Return backend health status.
    """
    return jsonify({
        "service": "backend",
        "status": "ok",
    }), 200


@app.route("/auth/register", methods=["POST"])
def register():
    """
    Register a new user account.
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

    return jsonify({
        "id": user["id"],
        "username": user["username"],
    }), 201


@app.route("/auth/login", methods=["POST"])
def login():
    """
    Authenticate a user and return their account info.
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

    return jsonify({
        "id": user["id"],
        "username": user["username"],
    }), 200


@app.route("/todos", methods=["POST"])
def create_todo():
    """
    Create a new todo item.
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

    notify_worker("todo_created", title)

    return jsonify(todo), 201


@app.route("/todos", methods=["GET"])
def get_todos():
    """
    Return all todo items belonging to the requesting user.
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

    notify_worker("todo_completed", updated["title"])

    return jsonify(updated), 200


@app.route("/todos/<int:todo_id>", methods=["DELETE"])
def delete_todo(todo_id):
    """
    Delete a completed todo item.
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
    file_key = f"uploads/todo-{todo_id}/{filename}"

    s3_client.upload_fileobj(
        uploaded_file,
        S3_BUCKET_NAME,
        file_key,
        ExtraArgs={
            "ContentType": uploaded_file.content_type,
        },
    )

    updated_todo = add_file_to_todo(todo_id, file_key)

    notify_worker("file_uploaded", updated_todo["title"])

    return jsonify({
        "message": "File uploaded successfully",
        "todo": updated_todo,
    }), 200


@app.route("/files/<path:file_key>", methods=["GET"])
def view_uploaded_file(file_key):
    """
    Generate a presigned S3 URL and redirect the browser.
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
