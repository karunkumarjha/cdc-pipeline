# CDC Pipeline — Phase 1

A minimal, hand-built change-data-capture pipeline that streams cryptocurrency
prices from the [CoinMarketCap](https://coinmarketcap.com/api/) API through
Postgres logical replication and lands them in S3 as JSON.

```
CoinMarketCap API  →  Python  →  RDS Postgres  →  Debezium  →  Kafka  →  S3
```

All components run on a single free-tier EC2 instance. Debezium captures
`INSERT`/`UPDATE` events from the Postgres WAL, Kafka buffers them, and the
Confluent S3 Sink writes them out as one-minute-batched JSON.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Quick start](#quick-start)
- [Manual setup (the learning path)](#manual-setup-the-learning-path)
- [Key design decisions](#key-design-decisions)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Teardown & cost notes](#teardown--cost-notes)
- [Project structure](#project-structure)
- [Roadmap](#roadmap)

---

## Why this exists

Phase 1 of a multi-phase project whose goal is to make modern CDC architectures
concrete. The deliberate constraints:

- **One EC2 box** for everything (Kafka, Kafka Connect, ingestion script).
- **Manual infra** through the AWS Console — no Terraform yet.
- **Manual trigger** — the Python script is run on demand, not scheduled.
- **Raw JSON out** — no schema registry, no Parquet, no Iceberg.

The point is not to ship a production pipeline; it is to make the flow
(Postgres WAL → Debezium → Kafka → S3) visible and reason-about-able. Later
phases tighten what's intentionally loose here — see [Roadmap](#roadmap).

---

## Quick start

For a fresh EC2 instance, one script bootstraps everything end-to-end:

```bash
# On EC2 (Amazon Linux 2023) with IAM instance profile attached:

# 1. Create an env file OUTSIDE the repo so it survives fresh clones.
cat > ~/.cdc-env <<'EOF'
CMC_API_KEY=your_cmc_key
PG_HOST=your-instance.xxxx.us-east-1.rds.amazonaws.com
PG_PORT=5432
PG_DATABASE=cdc
PG_USER=postgres
PG_PASSWORD=your_master_password
DEBEZIUM_PG_PASSWORD=choose_a_strong_password
S3_BUCKET=cdc-pipeline-events-<suffix>
AWS_REGION=us-east-1
EOF
chmod 600 ~/.cdc-env

# 2. Run the bootstrap.
curl -fsSL https://raw.githubusercontent.com/<you>/cdc-pipeline/main/scripts/run_phase1.sh -o ~/run_phase1.sh
bash ~/run_phase1.sh
```

[`scripts/run_phase1.sh`](./scripts/run_phase1.sh) is idempotent. It installs
packages, configures 1 GB of swap, clones the repo, creates the Debezium
Postgres role, applies migrations, brings Kafka + Connect up under Docker
Compose, registers both connectors, runs the ingestion once, and waits up
to 2 minutes for the first S3 objects to appear.

Prerequisites it assumes you've already done manually in the Console:
RDS + S3 + IAM role + EC2 + security groups exist. Those steps are in the
[next section](#manual-setup-the-learning-path).

---

## Manual setup (the learning path)

Steps 1–4 below (S3, RDS, IAM role, EC2) are the AWS Console prerequisites
— `run_phase1.sh` assumes they already exist. Steps 5–10 (on-EC2 setup,
role creation, migrations, Kafka/Connect, connectors, ingestion) are what
the script automates; the manual walk-through is included so each piece
is visible end-to-end.

All resources live in **one AWS region** (e.g. `us-east-1`) so traffic
between EC2, RDS, and S3 stays free.

### 1. S3 bucket

Console → S3 → Create bucket. Name must be globally unique; keep "Block all
public access" on; no versioning needed for Phase 1.

### 2. RDS Postgres (db.t3.micro, free tier)

Console → RDS → Create database → PostgreSQL 16.x → **Free tier** template.
Instance class `db.t3.micro`, 20 GB gp3, storage autoscaling **off**, public
access **yes** (Phase 1 only), initial database `cdc`.

**Enable logical replication:**

1. Create a parameter group (family `postgres16`), set
   `rds.logical_replication = 1`.
2. Attach it to the instance, **reboot** so it takes effect.
3. Verify:
   ```sql
   SHOW rds.logical_replication;  -- on
   SHOW wal_level;                -- logical
   ```

### 3. IAM role for EC2

Console → IAM → Create role → AWS service → EC2, with this inline policy
(note the `/*` suffix on the PutObject resource):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CdcS3Write",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::<your-bucket>/*"
    },
    {
      "Sid": "CdcS3List",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::<your-bucket>"
    }
  ]
}
```

### 4. EC2 (t3.micro, free tier)

Amazon Linux 2023, t3.micro, attach the IAM role from step 3. Security
group allows SSH (22) and Kafka Connect REST (8083) from your IP only.
Edit the RDS security group to allow inbound port 5432 from the EC2 SG.

### 5. Bootstrap the EC2

SSH in and run:

```bash
sudo dnf install -y git postgresql16 docker jq
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
# log out and back in so the group membership applies

# Docker Compose v2 + buildx plugins
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL -o /usr/local/lib/docker/cli-plugins/docker-compose \
  https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

sudo curl -SL -o /usr/local/lib/docker/cli-plugins/docker-buildx \
  https://github.com/docker/buildx/releases/download/v0.19.0/buildx-v0.19.0.linux-amd64
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx

# uv for Python
curl -LsSf https://astral.sh/uv/install.sh | sh

# 1 GB swap — t3.micro is tight with Kafka + Connect JVMs
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Clone the repo and create the env file:

```bash
git clone https://github.com/<you>/cdc-pipeline.git ~/cdc_pipeline
cd ~/cdc_pipeline
cp .env.example .env  # then edit with real values
uv sync
```

### 6. Debezium Postgres role

On RDS the master user doesn't have the native `REPLICATION` attribute, so
grant the built-in `rds_replication` role instead:

```bash
set -a; . .env; set +a

psql "host=$PG_HOST user=postgres dbname=$PG_DATABASE sslmode=require" \
  -v ON_ERROR_STOP=1 -v pwd="$DEBEZIUM_PG_PASSWORD" <<'SQL'
CREATE ROLE debezium WITH LOGIN PASSWORD :'pwd';
GRANT rds_replication TO debezium;
SQL
```

### 7. Apply SQL migrations

```bash
uv run python scripts/apply_migrations.py
```

Creates the `cryptocurrencies` table, the `dbz_pub` publication, and grants
SELECT on the table to the `debezium` role. Tracked in a `schema_migrations`
ledger so the script is safe to re-run.

### 8. Bring up Kafka + Connect

```bash
cd infra && docker compose up -d --build
docker compose logs -f connect   # wait for "Kafka Connect started"
```

First build pulls the S3 Sink plugin via `confluent-hub install`, which takes
a few minutes.

### 9. Register connectors

```bash
cd ~/cdc_pipeline

# Use PUT (idempotent) rather than POST (rejects on conflict)
for cfg in infra/connectors/postgres-source.json infra/connectors/s3-sink.json; do
  name=$(jq -r '.name' "$cfg")
  jq -c '.config' "$cfg" | curl -sS -X PUT \
    -H 'Content-Type: application/json' -d @- \
    "http://localhost:8083/connectors/$name/config" | jq .
done

# Both tasks should reach state=RUNNING within ~30s
curl -sS localhost:8083/connectors/cmc-postgres-source/status | jq .
curl -sS localhost:8083/connectors/cmc-s3-sink/status | jq .
```

### 10. Ingest

```bash
uv run python -m cdc_pipeline.main
# → "Fetched 10 coins from CMC"
# → "Upserted 10 rows into cryptocurrencies"
```

---

## Key design decisions

### Kafka in KRaft mode

Debezium can only publish to Kafka, so the pipeline runs a single-broker
Kafka in KRaft mode (no Zookeeper) on the same EC2 box as everything else.
JVM heaps are tight (`-Xmx256m` on Kafka, `-Xmx512m` on Connect) and a
1 GB swap file absorbs snapshotting spikes.

### `rds_replication` instead of native `REPLICATION`

RDS's master user isn't a superuser and can't create a role with the
`REPLICATION` attribute. AWS provides the `rds_replication` built-in role
that grants equivalent logical-decoding rights. Both `CREATE ROLE
... WITH LOGIN` and `GRANT rds_replication TO ...` are required.

### `decimal.handling.mode = string`

Debezium's default NUMERIC handling emits base64-encoded bytes in JSON
(`precise` mode uses `VariableScaleDecimal`), which is unreadable when
you just want to eyeball events. Setting `decimal.handling.mode=string`
on the source connector makes NUMERIC columns land as plain decimal strings.

### S3 sink rotation: 1 minute

`rotate.interval.ms=60000` forces the sink to close its open file every
minute even if `flush.size` (50) hasn't been hit. At ~10 records per manual
run, the time-based rotation is the one that actually fires. This keeps
S3 PUTs bounded (~1/min of activity) while still producing files fast
enough to verify by hand.

### `REPLICA IDENTITY FULL` on the source table

Makes UPDATE/DELETE events include the full previous row, not just the
primary key. Results in self-describing JSON envelopes in S3, at the cost
of slightly larger WAL volume. Fine for Phase 1.

### Idempotent connector registration (PUT `/config`)

POST `/connectors` returns 409 if the connector already exists, forcing
you to DELETE first. PUT `/connectors/<name>/config` creates-or-updates,
so the bootstrap script and any re-runs stay clean.

---

## Verification

### Postgres

```bash
psql "host=$PG_HOST user=$PG_USER dbname=$PG_DATABASE sslmode=require" \
  -c "SELECT symbol, price_usd, fetched_at FROM cryptocurrencies
      ORDER BY market_cap_usd DESC LIMIT 5;"
```

### Kafka topic

```bash
docker compose -f infra/docker-compose.yml exec kafka \
  kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic cdc.public.cryptocurrencies --from-beginning --max-messages 3
```

First run shows `"op":"r"` (snapshot read). Re-run `cdc_pipeline.main`
and you'll get `"op":"u"` (update) events as prices drift.

### S3

```bash
# Wait ~60s after ingestion for the sink to rotate.
aws s3 ls "s3://$S3_BUCKET/topics/cdc.public.cryptocurrencies/" --recursive
aws s3 cp "s3://$S3_BUCKET/<path-to-first-file>" - | head -1 | jq .
```

Files land under `topics/cdc.public.cryptocurrencies/year=YYYY/month=MM/day=DD/hour=HH/`.
Each line is a Debezium envelope: `{"before": ..., "after": {...}, "op": "u", "ts_ms": ...}`.

### One-shot health check (optional)

```bash
bash scripts/diagnose.sh
```

Runs 13 checks (containers, Connect REST, connector task states, DLQ,
Postgres row count, replication slot, Kafka topic offset, consumer lag,
S3 IAM probe, objects listing, recent logs) and prints a PASS/WARN/FAIL
summary. Not required to operate the pipeline — it's the fastest way to
localize a broken link when something does go wrong.

---

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| Connector `FAILED` | `curl localhost:8083/connectors/<name>/status \| jq .tasks[0].trace` |
| No events in Kafka | `SELECT slot_name, active FROM pg_replication_slots;` — if `active=f`, Connect isn't attached |
| WAL growing without bound | `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` on the slot; Connect is attached but not committing |
| S3 empty after 1 min | Check `dlq.s3.cryptocurrencies`. Most common cause: IAM role missing `s3:PutObject` on `arn:aws:s3:::<bucket>/*` (note the `/*`) |
| Container OOM / restart loop | `dmesg \| grep -i oom`; drop JVM heaps further or move to `t3.small` |
| `role "debezium" does not exist` | Run the role-creation SQL in [step 6](#6-debezium-postgres-role) |

### Replication-slot hygiene

**Orphaned replication slots hold WAL forever and can fill the RDS disk.**
If you tear Connect down or recreate the connector with a different
`slot.name`, drop the old slot:

```sql
SELECT pg_drop_replication_slot('debezium_slot');
```

Monitor retention:

```sql
SELECT slot_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
  FROM pg_replication_slots;
```

---

## Teardown & cost notes

### Free-tier budget

| Service | Allowance | Phase 1 usage |
|---|---|---|
| EC2 | 750 hours/month × t3.micro | One running instance |
| RDS | 750 hours/month × db.t3.micro, 20 GB | One instance |
| S3 | 5 GB, 2,000 PUTs/month | ~1 PUT per minute of activity |
| CMC | 10,000 credits/month | 1 credit per run |
| Data transfer | Free within the same region | RDS + EC2 + S3 all colocated |

Check weekly at **Billing → Free tier** in the Console.

### Pausing

```bash
# On EC2
cd ~/cdc_pipeline/infra && docker compose down
```

For longer breaks, **Stop** the EC2 from the Console (keeps EBS, which is
free-tier-eligible up to 30 GB). RDS storage accrues at ~$0.10/GB-month if
you exceed the 20 GB free tier, so keep it tidy.

### Full teardown

Before deleting RDS:

```sql
SELECT pg_drop_replication_slot('debezium_slot');
```

Then delete EC2, RDS (no final snapshot if you don't need one), S3 bucket
contents, IAM role, security groups, and parameter group.

---

## Project structure

```
cdc_pipeline/
├── src/cdc_pipeline/            Python ingestion package
│   ├── cmc_client.py              CMC API client with bounded retries
│   ├── config.py                  Env-driven settings (frozen dataclass)
│   ├── db.py                      psycopg3 pool + upsert
│   └── main.py                    CLI entrypoint
├── sql/
│   ├── 001_create_cryptocurrencies.sql    Table + indexes + REPLICA IDENTITY
│   └── 002_setup_cdc.sql                  Publication + grants for debezium role
├── scripts/
│   ├── apply_migrations.py        Primitive SQL runner with a ledger table
│   ├── run_phase1.sh              One-shot bootstrap on a fresh EC2
│   └── diagnose.sh                13-section pipeline health check
├── infra/
│   ├── docker-compose.yml         Kafka (KRaft, single broker) + Connect
│   ├── Dockerfile.connect         Debezium Connect + Confluent S3 Sink plugin
│   └── connectors/
│       ├── postgres-source.json   Debezium source connector config
│       └── s3-sink.json           Confluent S3 sink connector config
├── .env.example                 Required env vars, no secrets
└── pyproject.toml               uv-managed Python project
```

---

## Roadmap

- **Phase 1 (this repo)** — manual infra, CDC flow end-to-end, raw JSON in S3.
- **Phase 2** — Terraform for all infra (`terraform apply` stands it up,
  `terraform destroy` tears it down) **and** schema validation on the CDC
  stream (schema registry + Avro/JSON Schema contracts) so downstream
  consumers can't be broken by silent column changes.
- **Phase 3** — land S3 data as an open table format (Delta Lake or Iceberg)
  so the bucket becomes directly queryable from Spark / DuckDB / Athena.
