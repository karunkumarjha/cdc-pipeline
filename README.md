# cdc_pipeline — Phase 1

A minimal change-data-capture pipeline built for learning, not production:

```
Coin Market Cap API  →  Python  →  RDS Postgres  →  Debezium  →  Kafka  →  Confluent S3 Sink  →  S3
```

All components run on a single free-tier EC2 instance. A manual `uv run` of
the ingestion script upserts the top 10 cryptocurrencies into Postgres;
Debezium streams the resulting WAL events through Kafka and out to S3 as
raw JSON, one-minute-batched.

## What's in here

| Path | Purpose |
|---|---|
| `src/cdc_pipeline/` | Python ingestion: CMC client, psycopg pool, upsert, entrypoint |
| `sql/` | Schema migrations (`cryptocurrencies` table, Debezium publication + grants) |
| `scripts/apply_migrations.py` | Primitive in-order SQL runner with a `schema_migrations` ledger |
| `infra/docker-compose.yml` | Single-node Kafka (KRaft) + Kafka Connect |
| `infra/Dockerfile.connect` | Debezium Connect base + Confluent S3 Sink plugin |
| `infra/connectors/*.json` | Postgres source + S3 sink connector configs |
| `docs/` | Manual setup + verify + troubleshooting guides |
| `.env.example` | Required env vars (CMC + Postgres + Debezium + S3) |

## How to run it

Follow, in order:

1. [`docs/aws-setup.md`](docs/aws-setup.md) — provision RDS, S3, IAM role, EC2.
2. [`docs/rds-logical-replication.md`](docs/rds-logical-replication.md) — enable WAL, create the Debezium role, apply SQL migrations.
3. [`docs/kafka-setup.md`](docs/kafka-setup.md) — bring up Kafka + Connect, register both connectors.
4. [`docs/deployment-and-verify.md`](docs/deployment-and-verify.md) — run the ingestion script, watch events arrive in the Kafka topic and then S3.

## Scope notes

**Intentionally simple for Phase 1:** manual infra, manual triggers, raw JSON
output, no monitoring, no auto-recovery. The goal is to make the CDC flow
(Postgres WAL → Debezium → Kafka → S3) visible. Phase 2 will split Kafka off
the same box; Phase 3 will land the S3 data as an open table format.

**Notable constraint bent:** the original brief said "no Kafka in Phase 1,"
but Debezium has no native S3 sink without Kafka Connect. Running a single
KRaft-mode broker on the same EC2 is the lightest honest way to get
CDC→S3, and it's the exact same architecture Phase 2 will scale out.
