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

sns_client = boto3.client(
    "sns",
    region_name=AWS_REGION,
)


def build_notification_message(event, title):
    """
    Build a readable SNS notification message.
    """
    return (
        "TaskFlow notification\n\n"
        f"Event: {event}\n"
        f"Task: {title}\n"
    )


@app.route("/health", methods=["GET"])
def health_check():
    """
    Return a simple health check response.
    """
    return jsonify({
        "service": "worker",
        "status": "ok",
    }), 200


@app.route("/notify", methods=["POST"])
def notify():
    """
    Receive a notification event and publish it to AWS SNS.
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

    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="TaskFlow notification",
        Message=message,
    )

    return jsonify({
        "message": "Notification published to SNS",
        "event": event,
        "title": title,
    }), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=6000, debug=False)
    