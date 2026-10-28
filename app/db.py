"""Database access. All business rules live in PostgreSQL; this module only runs queries."""
import os
from contextlib import contextmanager

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://pg@localhost:5432/kps")

pool = ConnectionPool(
    DATABASE_URL,
    min_size=1,
    max_size=10,
    kwargs={"row_factory": dict_row, "options": "-c search_path=core,public"},
    open=False,
)


def open_pool():
    if pool.closed:
        pool.open(wait=True)


@contextmanager
def tx():
    """One transaction: commits on success, rolls back on any error."""
    open_pool()
    with pool.connection() as conn:
        with conn.transaction():
            yield conn


def all_rows(sql, params=None):
    with tx() as conn:
        return conn.execute(sql, params or {}).fetchall()


def one_row(sql, params=None):
    with tx() as conn:
        return conn.execute(sql, params or {}).fetchone()


def db_error_message(exc):
    """Turn a database exception into a sentence a user can act on."""
    diag = getattr(exc, "diag", None)
    msg = getattr(diag, "message_primary", None) if diag else None
    return msg or str(exc).splitlines()[0]
