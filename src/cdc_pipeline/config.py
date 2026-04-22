"""Typed settings loaded from environment (with .env support)."""
import os
from dataclasses import dataclass

from dotenv import load_dotenv


@dataclass(frozen=True)
class Settings:
    cmc_api_key: str
    pg_host: str
    pg_port: int
    pg_database: str
    pg_user: str
    pg_password: str
    cmc_limit: int = 10

    @property
    def pg_dsn(self) -> str:
        return (
            f"host={self.pg_host} port={self.pg_port} dbname={self.pg_database} "
            f"user={self.pg_user} password={self.pg_password}"
        )


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


def load_settings() -> Settings:
    load_dotenv()
    return Settings(
        cmc_api_key=_require("CMC_API_KEY"),
        pg_host=_require("PG_HOST"),
        pg_port=int(os.environ.get("PG_PORT", "5432")),
        pg_database=_require("PG_DATABASE"),
        pg_user=_require("PG_USER"),
        pg_password=_require("PG_PASSWORD"),
        cmc_limit=int(os.environ.get("CMC_LIMIT", "10")),
    )
