# Kafka + Kafka Connect (Debezium + S3 Sink)

Single-node Kafka in KRaft mode plus Kafka Connect, both running under
Docker Compose on the EC2 instance. Connect ships with the Debezium
Postgres source connector and, via a small `Dockerfile.connect` layer,
the Confluent S3 Sink plugin.

## 1. Bring the stack up

Prerequisite: `.env` populated on EC2 (see [`aws-setup.md`](./aws-setup.md)
§5). Compose reads it automatically when invoked from `infra/`.

```bash
cd ~/cdc_pipeline/infra
docker compose up -d --build
docker compose ps           # kafka + connect should be "Up"
docker compose logs -f connect
```

Wait until you see `Kafka Connect started` in the `connect` logs before
registering connectors. First build takes a few minutes because of the
`confluent-hub install`.

## 2. Register the Debezium Postgres source

```bash
curl -sS -X POST http://localhost:8083/connectors \
  -H 'Content-Type: application/json' \
  -d @connectors/postgres-source.json | jq .
```

Check status:

```bash
curl -sS http://localhost:8083/connectors/cmc-postgres-source/status | jq .
# state should be RUNNING, tasks[0].state RUNNING.
```

Under the hood Debezium will:
1. Connect as the `debezium` role.
2. Create the `debezium_slot` logical replication slot (plugin `pgoutput`).
3. Take an initial snapshot of `public.cryptocurrencies` (so any rows you
   already upserted appear as `op=r` read events).
4. Stream every subsequent INSERT/UPDATE/DELETE from the WAL.

Events land on topic `cdc.public.cryptocurrencies`.

## 3. Register the S3 Sink

```bash
curl -sS -X POST http://localhost:8083/connectors \
  -H 'Content-Type: application/json' \
  -d @connectors/s3-sink.json | jq .

curl -sS http://localhost:8083/connectors/cmc-s3-sink/status | jq .
```

### Batching strategy (what to tune and why)

S3 PUT requests cost money; the free tier allows 2,000 PUTs/month. The sink
flushes when **whichever of these fires first**:

- `flush.size = 50` — accumulate 50 records per topic-partition, or
- `rotate.interval.ms = 60000` (1 min) — close whatever partial file is open.

Phase 1 only writes ~10 records per manual run, so `flush.size` is effectively
dormant and the 1-minute rotation is what actually produces files. Net effect:
you pay at most one PUT per minute-window in which there was activity. At one
manual ingestion per hour that's ~720 PUTs/month, comfortably under the 2,000
free-tier cap. Raise `rotate.interval.ms` if you automate the script at a
higher cadence.

### Dead-letter queues

Both connectors are configured with `errors.tolerance = all` and per-connector
DLQ topics (`dlq.cdc.cryptocurrencies`, `dlq.s3.cryptocurrencies`). To inspect:

```bash
docker compose exec kafka \
  kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic dlq.cdc.cryptocurrencies --from-beginning --timeout-ms 5000
```

Phase 1 does not auto-recover DLQ messages — inspect by hand, fix the root
cause, and re-issue the source row.

## 4. Stop / restart

```bash
docker compose stop              # pauses; retains volumes + connector state
docker compose down              # stops + removes containers (volumes kept)
docker compose down -v           # also removes the kafka-data volume — nuclear
```

Dropping the Kafka volume wipes Connect's internal offset topic, so Debezium
will try to snapshot again and/or reuse the replication slot from a stale LSN.
If that happens, also drop the Postgres slot
(see [`rds-logical-replication.md`](./rds-logical-replication.md) §5).

## 5. Sizing notes

t3.micro has 1 GB RAM. With `Xmx256m` on Kafka and `Xmx512m` on Connect,
the JVMs alone use ~800 MB. The 1 GB swap file from `aws-setup.md` covers
spikes during snapshotting/compilation. If you see OOMkills in `dmesg` or
containers restart-looping, the sustainable fix is `t3.small` (2 GB RAM),
which steps outside the free tier but is ~$15/mo.
