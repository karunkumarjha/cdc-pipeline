import logging
from contextlib import contextmanager
from typing import Any, Iterator

from psycopg_pool import ConnectionPool

logger = logging.getLogger(__name__)

UPSERT_SQL = """
INSERT INTO cryptocurrencies (
    coin_id, symbol, name, price_usd, market_cap_usd,
    volume_24h_usd, percent_change_24h, last_updated, fetched_at
)
VALUES (
    %(coin_id)s, %(symbol)s, %(name)s, %(price_usd)s, %(market_cap_usd)s,
    %(volume_24h_usd)s, %(percent_change_24h)s, %(last_updated)s, %(fetched_at)s
)
ON CONFLICT (coin_id) DO UPDATE SET
    symbol             = EXCLUDED.symbol,
    name               = EXCLUDED.name,
    price_usd          = EXCLUDED.price_usd,
    market_cap_usd     = EXCLUDED.market_cap_usd,
    volume_24h_usd     = EXCLUDED.volume_24h_usd,
    percent_change_24h = EXCLUDED.percent_change_24h,
    last_updated       = EXCLUDED.last_updated,
    fetched_at         = EXCLUDED.fetched_at;
"""


@contextmanager
def make_pool(dsn: str) -> Iterator[ConnectionPool]:
    pool = ConnectionPool(conninfo=dsn, min_size=1, max_size=2, open=True)
    try:
        yield pool
    finally:
        pool.close()


def upsert_coins(pool: ConnectionPool, rows: list[dict[str, Any]]) -> int:
    if not rows:
        return 0
    with pool.connection() as conn, conn.cursor() as cur:
        cur.executemany(UPSERT_SQL, rows)
        conn.commit()
    logger.info("Upserted %d rows into cryptocurrencies", len(rows))
    return len(rows)
