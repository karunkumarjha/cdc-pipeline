# Deployment & end-to-end verification

Everything runs on one EC2 instance. The order matters only on first
bring-up: after that each piece is independent.

## Prerequisites

- `aws-setup.md` completed (RDS, S3, IAM, EC2 up; `.env` populated).
- `rds-logical-replication.md` completed (parameter group, `debezium` role,
  migrations applied).
- `kafka-setup.md` completed (Compose up, both connectors `RUNNING`).

## Run the ingestion

```bash
cd ~/cdc_pipeline
uv run python -m cdc_pipeline.main
```

Expected output:

```
INFO cdc_pipeline.cmc_client: Fetched 20 coins from CMC
INFO cdc_pipeline.db: Upserted 20 rows into cryptocurrencies
```

## Verify end-to-end

### Postgres

```bash
psql "host=$PG_HOST user=$PG_USER dbname=$PG_DATABASE" \
  -c "SELECT coin_id, symbol, price_usd, fetched_at FROM cryptocurrencies ORDER BY market_cap_usd DESC LIMIT 5;"
```

### Kafka topic (CDC events)

```bash
cd ~/cdc_pipeline/infra
docker compose exec kafka \
  kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic cdc.public.cryptocurrencies --from-beginning --max-messages 3
```

On the very first run you should see `"op":"r"` (snapshot read) events;
on subsequent runs `"op":"u"` (update) and occasionally `"op":"c"` (insert —
when CMC returns a coin we haven't seen before).

### S3

Wait up to `rotate.interval.ms` (5 min):

```bash
aws s3 ls "s3://$S3_BUCKET/topics/cdc.public.cryptocurrencies/" --recursive
```

Files appear under `topics/cdc.public.cryptocurrencies/year=YYYY/month=MM/day=DD/hour=HH/`.
Download one and eyeball it:

```bash
aws s3 cp "s3://$S3_BUCKET/topics/cdc.public.cryptocurrencies/year=2026/month=04/day=20/hour=12/cdc.public.cryptocurrencies+0+0000000000.json" -
```

Each line is a Debezium envelope: `{"before": ..., "after": {...}, "op": "u", "ts_ms": ...}`.

### Second run (the point of CDC)

```bash
uv run python -m cdc_pipeline.main
```

Prices will have shifted by a few cents; Debezium should emit ~20 `op=u` events.
Confirm by re-running the `kafka-console-consumer` command with `--max-messages 25`
or by watching new S3 objects appear after the next rotation.

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| Connector `FAILED` | `curl localhost:8083/connectors/<name>/status \| jq .tasks[0].trace` |
| No events in Kafka | `SELECT slot_name, active FROM pg_replication_slots;` — if `active=f`, Connect isn't attached |
| WAL growing, no progress | `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` — Connect is attached but not committing; check sink status |
| S3 empty | Check `dlq.s3.cryptocurrencies` topic; most common cause is IAM: instance profile missing `s3:PutObject` on the right ARN |
| Container restart loop / OOM | `dmesg \| grep -i oom`; lower JVM heaps or resize to t3.small |
| `role "debezium" does not exist` | You skipped §2 of `rds-logical-replication.md` |
| "permission denied for table cryptocurrencies" on Debezium start | Re-apply `002_setup_cdc.sql` (idempotent); confirm `GRANT SELECT ... TO debezium` succeeded |

## Free-tier cost watch

Check at least weekly via **Billing → Free tier** in the AWS Console:

- **RDS**: 750 hours/month covers one db.t3.micro. Don't run a second one.
- **EC2**: 750 hours/month covers one t3.micro.
- **S3**: 5 GB storage, 2,000 PUTs/month, 20,000 GETs/month. With `flush.size=50`
  and 5-minute rotation, a single run produces 1 PUT; a full month of hourly
  runs stays comfortably under 750 PUTs.
- **CMC**: 10,000 credits/month; `listings/latest` is 1 credit/call.
- **Data transfer**: zero as long as RDS + EC2 + S3 live in the same region.

## Teardown (stay inside free tier when not actively using)

```bash
# On EC2
cd ~/cdc_pipeline/infra && docker compose down
```

If you're taking a break for >1 day, also **Stop** the EC2 instance from the
Console (you stop paying for compute hours but keep the EBS volume, which is
free-tier-eligible up to 30 GB).

Before doing anything destructive on RDS, drop the replication slot:

```sql
SELECT pg_drop_replication_slot('debezium_slot');
```
