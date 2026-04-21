-- Publication and grants for the `debezium` role.
-- PRE-REQUISITES (do these manually once, documented in
-- docs/rds-logical-replication.md):
--   1. Custom parameter group with rds.logical_replication = 1, reboot.
--   2. As RDS master user:
--        CREATE ROLE debezium WITH LOGIN REPLICATION PASSWORD '<secret>';
--      (password kept out of git; also set as DEBEZIUM_PG_PASSWORD in EC2 env).
--
-- This file is idempotent and is applied by scripts/apply_migrations.py.

GRANT USAGE  ON SCHEMA public    TO debezium;
GRANT SELECT ON cryptocurrencies TO debezium;

DROP PUBLICATION IF EXISTS dbz_pub;
CREATE PUBLICATION dbz_pub FOR TABLE cryptocurrencies;

-- The replication slot `debezium_slot` is created automatically the first
-- time the Debezium Postgres source connector starts. Teardown snippet:
--   SELECT pg_drop_replication_slot('debezium_slot');
