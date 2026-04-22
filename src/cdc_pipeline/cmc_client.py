"""Coin Market Cap listings client with bounded retries."""
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
    fetched_at = datetime.now(tz=timezone.utc)
    coins = payload.get("data", [])
    logger.info("Fetched %d coins from CMC", len(coins))
    return [_normalize(coin, fetched_at) for coin in coins]


def _normalize(coin: dict[str, Any], fetched_at: datetime) -> dict[str, Any]:
    usd = coin["quote"]["USD"]
    return {
        "coin_id": coin["id"],
        "symbol": coin["symbol"],
        "name": coin["name"],
        "price_usd": usd.get("price"),
        "market_cap_usd": usd.get("market_cap"),
        "volume_24h_usd": usd.get("volume_24h"),
        "percent_change_24h": usd.get("percent_change_24h"),
        "last_updated": usd.get("last_updated") or coin.get("last_updated"),
        "fetched_at": fetched_at.isoformat(),
    }
