# RDS logical replication + Debezium role setup

This document covers the one-time Postgres-side setup: enabling logical
replication, creating the `debezium` role, and applying the publication +
grants via the migration runner.

## 1. Enable logical replication on the RDS instance

Done as part of [`aws-setup.md`](./aws-setup.md) step 2. Recap:

1. Custom parameter group (family `postgres16`) with `rds.logical_replication = 1`.
2. Attach to the instance, **reboot**.
3. Verify:
   ```sql
   SHOW rds.logical_replication;  -- on
   SHOW wal_level;                -- logical
   ```

## 2. Create the `debezium` role (one-time, manual)

Kept out of the automated migrations so the password never lands in git.
On RDS the master user `postgres` does **not** have the `REPLICATION`
attribute and so cannot directly create roles with `WITH REPLICATION`.
Instead, grant the built-in `rds_replication` role — that's the RDS
equivalent and is what enables logical decoding for this user.

```bash
# On EC2, with .env already sourced
psql "host=$PG_HOST user=postgres dbname=$PG_DATABASE" -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE debezium WITH LOGIN PASSWORD '$DEBEZIUM_PG_PASSWORD';
GRANT rds_replication TO debezium;
SQL
```

Verify the membership:

```bash
psql "host=$PG_HOST user=postgres dbname=$PG_DATABASE" -c "\du debezium"
# Expect: "Member of: {rds_replication}"
```

`DEBEZIUM_PG_PASSWORD` is already in `.env` (Kafka Connect reads it at
container start); the shell expands it into the SQL above so the
password itself never lands on disk.

## 3. Apply migrations (publication + grants + app table)

The Python runner applies all files in `sql/` in lex order, tracking them in a
`schema_migrations` table. It connects as `PG_USER` from `.env`; for Phase 1
that can be the master user, or a dedicated `cdc_app` user with write access
to `public.cryptocurrencies`.

```bash
cd ~/cdc_pipeline
uv run python scripts/apply_migrations.py
```

Expected log lines:

```
Applied 001_create_cryptocurrencies.sql
Applied 002_setup_cdc.sql
Applied 2 migration(s)
```

## 4. Verify pub + slot plumbing

```sql
-- Should return one row for dbz_pub.
SELECT pubname FROM pg_publication;

-- Slot won't exist yet — Debezium creates it on first connector start.
SELECT slot_name, plugin, active, restart_lsn
  FROM pg_replication_slots;
```

After Kafka Connect starts the source connector:

```sql
SELECT slot_name, plugin, active, restart_lsn
  FROM pg_replication_slots;
-- expect: debezium_slot | pgoutput | t | <some LSN>
```

## 5. Replication-slot hygiene (important)

An **orphaned replication slot holds WAL indefinitely** and can fill the RDS
disk. If you tear down Kafka Connect or recreate the connector with a new
`slot.name`, drop the old slot:

```sql
SELECT pg_drop_replication_slot('debezium_slot');
```

Also monitor:
```sql
SELECT slot_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
  FROM pg_replication_slots;
```
If `retained_wal` keeps growing without bound, Connect isn't consuming — check
container logs.
