"""Pydantic models for the CoinMarketCap listings response.

These validate the JSON shape at the trust boundary with CMC. If CMC
renames a field or sends an unexpected type, we fail fast here with a
clear ValidationError instead of letting bad data slip into Postgres.
"""
from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field


class CMCQuoteUSD(BaseModel):
    """The USD sub-object of a CMC coin's `quote` field."""

    model_config = ConfigDict(extra="ignore")

    price: Decimal | None = None
    market_cap: Decimal | None = None
    volume_24h: Decimal | None = None
    percent_change_24h: Decimal | None = None
    last_updated: datetime | None = None


class CMCQuote(BaseModel):
    """Wrapper for all quote currencies. We only consume USD."""

    model_config = ConfigDict(extra="ignore")

    USD: CMCQuoteUSD


class CMCCoin(BaseModel):
    """One coin entry from /v1/cryptocurrency/listings/latest."""

    model_config = ConfigDict(extra="ignore")

    id: int
    symbol: str
    name: str
    last_updated: datetime | None = None
    quote: CMCQuote


class CMCListingsResponse(BaseModel):
    """Top-level response envelope from CMC."""

    model_config = ConfigDict(extra="ignore")

    data: list[CMCCoin] = Field(default_factory=list)
