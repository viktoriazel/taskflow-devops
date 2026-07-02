"""
PostgreSQL database layer for the Backend service.

This file connects the Backend service to PostgreSQL / AWS RDS.
It is responsible for creating, reading, updating,
and deleting todo data.
"""

import json
import logging
import os

import psycopg2
from dotenv import load_dotenv
from psycopg2.extras import RealDictCursor

load_dotenv()


def get_connection():
    """
    Create and return a new PostgreSQL database connection.

    Reads connection details from environment variables: DB_HOST, DB_NAME,
    DB_USER, DB_PASSWORD, and DB_PORT (defaults to 5432 if not set).

    Returns:
        psycopg2 connection object. Use as a context manager or close it
        manually when done.
    """
    try:
        return psycopg2.connect(
            host=os.getenv("DB_HOST"),
            database=os.getenv("DB_NAME"),
            user=os.getenv("DB_USER"),
            password=os.getenv("DB_PASSWORD"),
            port=os.getenv("DB_PORT", "5432"),
            connect_timeout=5,
        )
    except psycopg2.OperationalError as e:
        logging.error("Database connection failed: %s", e)
        raise


def init_database():
    """
    Create the users and todos tables if they do not exist.

    Also adds the user_id column to todos if it is missing from an older
    schema. Safe to call on every startup because all statements use
    IF NOT EXISTS / ADD COLUMN IF NOT EXISTS.

    Side Effects:
        - Runs DDL statements against PostgreSQL and commits them.
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
    Convert a PostgreSQL row into a plain todo dictionary.

    The file_keys column is stored as a JSON string in the database.
    This function parses it back into a Python list.

    Args:
        row: A psycopg2 RealDictRow from a todos table query.

    Returns:
        dict with keys: id (int), title (str), done (bool),
        file_keys (list of str), user_id (int).
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
    Insert a new user into the PostgreSQL users table and return it.

    Args:
        username (str): The chosen username. Must be unique.
        password_hash (str): A pre-hashed password. Use Werkzeug's
            generate_password_hash before calling this function.

    Returns:
        dict with keys: id (int), username (str), created_at (datetime).

    Side Effects:
        - Inserts a row into the PostgreSQL users table.
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
    Look up a user by their username in PostgreSQL.

    The lookup is case-sensitive because the username column uses
    PostgreSQL TEXT equality.

    Args:
        username (str): The username to search for.

    Returns:
        dict with keys: id, username, password_hash — or None if not found.
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
    Insert a new todo row into PostgreSQL and return it as a dict.

    The new todo starts with done=False and an empty file_keys list.

    Args:
        title (str): The text of the todo item.
        user_id (int): The ID of the user who owns this todo.

    Returns:
        dict representing the new todo (via row_to_todo).

    Side Effects:
        - Inserts a row into the PostgreSQL todos table.
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
    Fetch all todo rows belonging to a given user, ordered by ID.

    Args:
        user_id (int): The user whose todos should be returned.

    Returns:
        list of todo dicts (empty list if the user has no todos).
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
    Fetch a single todo row by its primary key.

    Args:
        todo_id (int): The ID of the todo to look up.

    Returns:
        dict representing the todo, or None if no row matches.
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
    Set done=TRUE on a todo row and return the updated record.

    Safe to call even if the todo is already marked as done.

    Args:
        todo_id (int): The ID of the todo to update.

    Returns:
        dict representing the updated todo, or None if the ID was not found.

    Side Effects:
        - Updates the PostgreSQL todos row (done = TRUE).
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
    Delete a todo from PostgreSQL, but only if it is already completed.

    Returns a 2-tuple so the caller can tell apart different failure modes
    without raising exceptions.

    Args:
        todo_id (int): The ID of the todo to delete.

    Returns:
        (todo_dict, None) on success.
        (None, "not_found") if the todo does not exist.
        (None, "not_completed") if the todo is not yet marked as done.

    Side Effects:
        - Deletes the row from the PostgreSQL todos table on success.
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
    Append an S3 file key to a todo's file_keys list in PostgreSQL.

    Fetches the current file_keys list, appends the new key, then writes
    the updated list back to the database as a JSON string.

    Args:
        todo_id (int): The ID of the todo to update.
        file_key (str): The S3 object key to attach,
            e.g. "uploads/todo-5/report.pdf".

    Returns:
        dict representing the updated todo, or None if the todo was not found.

    Side Effects:
        - Updates the PostgreSQL todos.file_keys column.
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
