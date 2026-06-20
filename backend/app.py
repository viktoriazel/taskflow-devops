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
from werkzeug.utils import secure_filename

from db import (
    add_file_to_todo,
    create_todo_record,
    delete_completed_todo,
    find_todo_by_id,
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


@app.route("/health", methods=["GET"])
def health_check():
    """
    Return backend health status.
    """
    return jsonify({
        "service": "backend",
        "status": "ok",
    }), 200


@app.route("/todos", methods=["POST"])
def create_todo():
    """
    Create a new todo item.
    """
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

    todo = create_todo_record(title)

    notify_worker("todo_created", title)

    return jsonify(todo), 201


@app.route("/todos", methods=["GET"])
def get_todos():
    """
    Return all todo items.
    """
    todos = get_all_todos()
    return jsonify(todos), 200


@app.route("/todos/<int:todo_id>", methods=["PATCH"])
def mark_todo_done(todo_id):
    """
    Mark a todo item as completed.
    """
    todo = mark_todo_as_done(todo_id)

    if todo is None:
        return jsonify({
            "error": "Todo not found",
        }), 404

    notify_worker("todo_completed", todo["title"])

    return jsonify(todo), 200


@app.route("/todos/<int:todo_id>", methods=["DELETE"])
def delete_todo(todo_id):
    """
    Delete a completed todo item.
    """
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
    todo = find_todo_by_id(todo_id)

    if todo is None:
        return jsonify({
            "error": "Todo not found",
        }), 404

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
    if not file_key.startswith("uploads/"):
        return jsonify({
            "error": "Invalid file path",
        }), 400

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
