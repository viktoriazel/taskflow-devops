"""
PostgreSQL database layer for the Backend service.

This file connects the Backend service to PostgreSQL / AWS RDS.
It is responsible for creating, reading, updating,
and deleting todo data.
"""

import json
import os

import psycopg2
from dotenv import load_dotenv
from psycopg2.extras import RealDictCursor

load_dotenv()


def get_connection():
    """
    Create and return a PostgreSQL database connection.
    """
    return psycopg2.connect(
        host=os.getenv("DB_HOST"),
        database=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
        port=os.getenv("DB_PORT", "5432"),
    )


def init_database():
    """
    Create the users and todos tables if they do not exist,
    and add user_id to todos if the column is missing.
    """
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id SERIAL PRIMARY KEY,
                    username TEXT NOT NULL UNIQUE,
                    password_hash TEXT NOT NULL,
                    created_at TIMESTAMP NOT NULL DEFAULT NOW()
                )
                """
            )
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS todos (
                    id SERIAL PRIMARY KEY,
                    title TEXT NOT NULL,
                    done BOOLEAN NOT NULL DEFAULT FALSE,
                    file_keys TEXT NOT NULL DEFAULT '[]',
                    user_id INTEGER REFERENCES users(id)
                )
                """
            )
            # Safe to run on every startup — no-op if column already exists.
            cursor.execute(
                """
                ALTER TABLE todos
                    ADD COLUMN IF NOT EXISTS user_id INTEGER REFERENCES users(id)
                """
            )
        connection.commit()


def row_to_todo(row):
    """
    Convert a database row to a todo dictionary.
    """
    return {
        "id": row["id"],
        "title": row["title"],
        "done": bool(row["done"]),
        "file_keys": json.loads(row["file_keys"]),
        "user_id": row["user_id"],
    }


def create_user(username, password_hash):
    """
    Create a new user record and return it as a dictionary.
    """
    with get_connection() as connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                INSERT INTO users (username, password_hash)
                VALUES (%s, %s)
                RETURNING id, username, created_at
                """,
                (username, password_hash),
            )

            row = cursor.fetchone()

        connection.commit()

    return dict(row)


def find_user_by_username(username):
    """
    Find a user by username. Returns a dict or None.
    """
    with get_connection() as connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                "SELECT id, username, password_hash FROM users WHERE username = %s",
                (username,),
            )
            row = cursor.fetchone()

    if row is None:
        return None

    return dict(row)


def create_todo_record(title, user_id):
    """
    Create a new todo record in PostgreSQL.
    """
    with get_connection() as connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                INSERT INTO todos (title, done, file_keys, user_id)
                VALUES (%s, %s, %s, %s)
                RETURNING *
                """,
                (title, False, "[]", user_id),
            )

            row = cursor.fetchone()

        connection.commit()

    return row_to_todo(row)


def get_all_todos(user_id):
    """
    Return all todo records belonging to the given user.
    """
    with get_connection() as connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                "SELECT * FROM todos WHERE user_id = %s ORDER BY id",
                (user_id,),
            )
            rows = cursor.fetchall()

    return [row_to_todo(row) for row in rows]


def find_todo_by_id(todo_id):
    """
    Find a todo by its ID.
    """
    with get_connection() as connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                "SELECT * FROM todos WHERE id = %s",
                (todo_id,),
            )
            row = cursor.fetchone()

    if row is None:
        return None

    return row_to_todo(row)


def mark_todo_as_done(todo_id):
    """
    Mark a todo as completed.
    """
    with get_connection() as connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                UPDATE todos
                SET done = TRUE
                WHERE id = %s
                RETURNING *
                """,
                (todo_id,),
            )

            row = cursor.fetchone()

        connection.commit()

    if row is None:
        return None

    return row_to_todo(row)


def delete_completed_todo(todo_id):
    """
    Delete a todo only if it is completed.
    """
    todo = find_todo_by_id(todo_id)

    if todo is None:
        return None, "not_found"

    if not todo["done"]:
        return None, "not_completed"

    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "DELETE FROM todos WHERE id = %s",
                (todo_id,),
            )

        connection.commit()

    return todo, None


def add_file_to_todo(todo_id, file_key):
    """
    Add an uploaded file key to a todo.
    """
    todo = find_todo_by_id(todo_id)

    if todo is None:
        return None

    file_keys = todo["file_keys"]
    file_keys.append(file_key)

    with get_connection() as connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                UPDATE todos
                SET file_keys = %s
                WHERE id = %s
                RETURNING *
                """,
                (json.dumps(file_keys), todo_id),
            )

            row = cursor.fetchone()

        connection.commit()

    return row_to_todo(row)
