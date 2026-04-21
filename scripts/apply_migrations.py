"""Apply SQL files in sql/ in lexical order, recording each in schema_migrations.

Deliberately primitive (no transactions across files, no rollback, no down
migrations). Phase 1 scope; graduate to Alembic/Flyway later.

Usage:
    uv run python scripts/apply_migrations.py
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

import psycopg

from cdc_pipeline.config import load_settings

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"

CREATE_TRACKING_TABLE = """
CREATE TABLE IF NOT EXISTS schema_migrations (
    filename   TEXT        PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
"""

logger = logging.getLogger(__name__)


def applied_files(conn: psycopg.Connection) -> set[str]:
    with conn.cursor() as cur:
        cur.execute("SELECT filename FROM schema_migrations;")
        return {row[0] for row in cur.fetchall()}


def apply_file(conn: psycopg.Connection, path: Path) -> None:
    sql = path.read_text()
    with conn.cursor() as cur:
        cur.execute(sql)
        cur.execute(
            "INSERT INTO schema_migrations (filename) VALUES (%s);",
            (path.name,),
        )
    conn.commit()
    logger.info("Applied %s", path.name)


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )
    settings = load_settings()
    files = sorted(SQL_DIR.glob("*.sql"))
    if not files:
        logger.warning("No .sql files found in %s", SQL_DIR)
        return 0

    with psycopg.connect(settings.pg_dsn, autocommit=False) as conn:
        with conn.cursor() as cur:
            cur.execute(CREATE_TRACKING_TABLE)
        conn.commit()

        already = applied_files(conn)
        pending = [f for f in files if f.name not in already]
        if not pending:
            logger.info("No pending migrations (%d already applied)", len(already))
            return 0

        for path in pending:
            apply_file(conn, path)
    logger.info("Applied %d migration(s)", len(pending))
    return 0


if __name__ == "__main__":
    sys.exit(main())
