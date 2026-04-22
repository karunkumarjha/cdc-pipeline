"""Entrypoint: fetch CMC listings, upsert into Postgres, exit."""
import logging
import sys

from cdc_pipeline.cmc_client import fetch_listings
from cdc_pipeline.config import load_settings
from cdc_pipeline.db import make_pool, upsert_coins

logger = logging.getLogger(__name__)


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )
    try:
        settings = load_settings()
        rows = fetch_listings(settings.cmc_api_key, limit=settings.cmc_limit)
        with make_pool(settings.pg_dsn) as pool:
            upsert_coins(pool, rows)
    except Exception:
        logger.exception("Ingestion failed")
        return 1
    return 0


def cli() -> None:
    """Console-script entrypoint registered in pyproject.toml."""
    sys.exit(main())


if __name__ == "__main__":
    cli()
