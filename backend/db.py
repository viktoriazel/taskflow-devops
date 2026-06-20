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
    Create the todos table if it does not exist.
    """
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS todos (
                    id SERIAL PRIMARY KEY,
                    title TEXT NOT NULL,
                    done BOOLEAN NOT NULL DEFAULT FALSE,
                    file_keys TEXT NOT NULL DEFAULT '[]'
                )
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
    }


def create_todo_record(title):
    """
    Create a new todo record in PostgreSQL.
    """
    with get_connection() as connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                INSERT INTO todos (title, done, file_keys)
                VALUES (%s, %s, %s)
                RETURNING *
                """,
                (title, False, "[]"),
            )

            row = cursor.fetchone()

        connection.commit()

    return row_to_todo(row)


def get_all_todos():
    """
    Return all todo records.
    """
    with get_connection() as connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute("SELECT * FROM todos ORDER BY id")
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
