CREATE TABLE IF NOT EXISTS cryptocurrencies (
    coin_id            INTEGER      PRIMARY KEY,
    symbol             VARCHAR(16)  NOT NULL,
    name               VARCHAR(128) NOT NULL,
    price_usd          NUMERIC(24, 8),
    market_cap_usd     NUMERIC(24, 2),
    volume_24h_usd     NUMERIC(24, 2),
    percent_change_24h NUMERIC(10, 4),
    last_updated       TIMESTAMPTZ  NOT NULL,
    fetched_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cryptocurrencies_symbol
    ON cryptocurrencies (symbol);

CREATE INDEX IF NOT EXISTS idx_cryptocurrencies_fetched_at
    ON cryptocurrencies (fetched_at DESC);

-- REPLICA IDENTITY FULL makes UPDATE/DELETE WAL events include the full
-- previous row, not just the primary key. Useful for Phase 1 so CDC events
-- in S3 are fully self-describing when eyeballing them.
ALTER TABLE cryptocurrencies REPLICA IDENTITY FULL;
