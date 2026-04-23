"""Coin Market Cap listings client with bounded retries + schema validation."""
import logging
from datetime import datetime, timezone
from typing import Any

import requests
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from cdc_pipeline.models import CMCCoin, CMCListingsResponse

LISTINGS_URL = "https://pro-api.coinmarketcap.com/v1/cryptocurrency/listings/latest"
REQUEST_TIMEOUT_SECONDS = 30

logger = logging.getLogger(__name__)


class CMCError(RuntimeError):
    pass


@retry(
    reraise=True,
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=10),
    retry=retry_if_exception_type((requests.Timeout, requests.ConnectionError, CMCError)),
)
def _get(url: str, headers: dict[str, str], params: dict[str, Any]) -> dict[str, Any]:
    response = requests.get(url, headers=headers, params=params, timeout=REQUEST_TIMEOUT_SECONDS)
    if response.status_code >= 500:
        raise CMCError(f"CMC {response.status_code}: {response.text[:200]}")
    response.raise_for_status()
    return response.json()


def fetch_listings(api_key: str, limit: int = 10) -> list[dict[str, Any]]:
    payload = _get(
        LISTINGS_URL,
        headers={"X-CMC_PRO_API_KEY": api_key, "Accept": "application/json"},
        params={"start": 1, "limit": limit, "convert": "USD"},
    )
    listings = CMCListingsResponse.model_validate(payload)
    fetched_at = datetime.now(tz=timezone.utc)
    logger.info("Fetched and validated %d coins from CMC", len(listings.data))
    return [_normalize(coin, fetched_at) for coin in listings.data]


def _normalize(coin: CMCCoin, fetched_at: datetime) -> dict[str, Any]:
    usd = coin.quote.USD
    last_updated = usd.last_updated or coin.last_updated
    return {
        "coin_id": coin.id,
        "symbol": coin.symbol,
        "name": coin.name,
        "price_usd": usd.price,
        "market_cap_usd": usd.market_cap,
        "volume_24h_usd": usd.volume_24h,
        "percent_change_24h": usd.percent_change_24h,
        "last_updated": last_updated.isoformat() if last_updated else None,
        "fetched_at": fetched_at.isoformat(),
    }
