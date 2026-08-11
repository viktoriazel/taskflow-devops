"""
Worker Flask service for the Todo AWS DevOps Project.

This service receives events from the Backend service
and publishes email notifications through AWS SNS.
"""

import os

import boto3
from dotenv import load_dotenv
from flask import Flask, jsonify, request

load_dotenv()

app = Flask(__name__)

AWS_REGION = os.getenv("AWS_REGION")
SNS_TOPIC_ARN = os.getenv("SNS_TOPIC_ARN")

if not AWS_REGION:
    raise ValueError(
        "AWS_REGION is required but not set. "
        "Add it to worker/.env before starting the Worker."
    )
if not SNS_TOPIC_ARN:
    raise ValueError(
        "SNS_TOPIC_ARN is required but not set. "
        "Add it to worker/.env before starting the Worker."
    )

sns_client = boto3.client(
    "sns",
    region_name=AWS_REGION,
)


def build_notification_message(event, title):
    """
    Build a plain-text SNS notification message from an event and title.

    Args:
        event (str): The event name, e.g. "todo_created", "todo_completed",
            or "file_uploaded".
        title (str): The title of the todo that triggered the event.

    Returns:
        str: A formatted multi-line string ready to use as the SNS message body.
    """
    return (
        "TaskFlow notification\n\n"
        f"Event: {event}\n"
        f"Task: {title}\n"
    )


@app.route("/health", methods=["GET"])
def health_check():
    """
    Return the health status of the worker service.

    Used by load balancers and monitoring tools to check that the
    service is running.

    Returns:
        JSON {"service": "worker", "status": "ok"}, HTTP 200.
    """
    return jsonify({
        "service": "worker",
        "status": "ok",
    }), 200


@app.route("/live", methods=["GET"])
def liveness_check():
    """Kubernetes liveness probe — confirms this worker can complete an HTTP round trip. No SNS calls."""
    return jsonify({
        "service": "worker",
        "check": "live",
        "status": "ok",
    }), 200


@app.route("/ready", methods=["GET"])
def readiness_check():
    """Kubernetes readiness probe — no SNS call; AWS_REGION/SNS_TOPIC_ARN already fail fast at startup."""
    return jsonify({
        "service": "worker",
        "check": "ready",
        "status": "ok",
    }), 200


@app.route("/notify", methods=["POST"])
def notify():
    """
    Receive an event from the Backend and publish a notification to AWS SNS.

    Called by the Backend after todo actions such as creating, completing,
    or attaching a file to a todo. Validates the JSON body, builds a
    human-readable message, and publishes it to the SNS topic set by
    SNS_TOPIC_ARN. SNS then delivers the message to its subscribers
    (e.g. by email or SMS).

    Expected JSON body:
        event (str, required): The event name.
        title (str, required): The todo title.

    Returns:
        JSON {"message", "event", "title"}, HTTP 200 on success.
        JSON {"error": ...}, HTTP 400 if event or title is missing.

    Side Effects:
        - Publishes a message to the AWS SNS topic (SNS_TOPIC_ARN).
    """
    data = request.get_json()

    if not data:
        return jsonify({
            "error": "JSON body is required",
        }), 400

    event = data.get("event")
    title = data.get("title")

    if not event:
        return jsonify({
            "error": "Event is required",
        }), 400

    if not title:
        return jsonify({
            "error": "Title is required",
        }), 400

    message = build_notification_message(event, title)

    try:
        result = sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="TaskFlow notification",
            Message=message,
        )
    except Exception as e:
        app.logger.error(
            "SNS publish failed for event '%s' on task '%s': %s",
            event,
            title,
            e,
        )
        return jsonify({
            "error": "Failed to publish notification",
        }), 500

    return jsonify({
        "message": "Notification published to SNS",
        "event": event,
        "title": title,
        "sns_message_id": result["MessageId"],
    }), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=6000, debug=False)
