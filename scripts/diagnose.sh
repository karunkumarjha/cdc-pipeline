#!/usr/bin/env bash
# Diagnose why CDC events aren't showing up in S3 (or why any piece of the
# Phase 1 pipeline looks wrong). Read-only except for one self-cleaning IAM
# probe that puts and deletes `_iam_test.txt` in the bucket.
#
# Run from the repo root or anywhere — the script cd's to its own repo.
# Source .env or let the script do it.
#
#   bash scripts/diagnose.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

section() { printf "\n${BOLD}== %s ==${RESET}\n" "$1"; }
ok()      { printf "${GREEN}OK${RESET}  %s\n" "$1"; }
warn()    { printf "${YELLOW}WARN${RESET} %s\n" "$1"; }
fail()    { printf "${RED}FAIL${RESET} %s\n" "$1"; }

# ---- 1. env ------------------------------------------------------------------
section "1. Environment (.env)"
if [[ -f .env ]]; then
  set -a; . .env; set +a
  ok ".env sourced"
else
  fail ".env not found at $REPO_DIR/.env"
  exit 1
fi

for v in PG_HOST PG_DATABASE PG_USER S3_BUCKET AWS_REGION DEBEZIUM_PG_PASSWORD; do
  if [[ -z "${!v:-}" ]]; then
    fail "$v is empty"
  else
    # mask the password
    if [[ "$v" == *PASSWORD* ]]; then
      printf "     %s=****\n" "$v"
    else
      printf "     %s=%s\n" "$v" "${!v}"
    fi
  fi
done

# ---- 2. containers -----------------------------------------------------------
section "2. Docker containers"
if docker compose -f infra/docker-compose.yml ps >/dev/null 2>&1; then
  docker compose -f infra/docker-compose.yml ps
else
  fail "docker compose can't read infra/docker-compose.yml"
fi

# ---- 3. connect REST --------------------------------------------------------
section "3. Kafka Connect REST API"
if curl -sf http://localhost:8083/ >/dev/null; then
  ok "http://localhost:8083/ responding"
  curl -sS http://localhost:8083/connector-plugins | jq '.[].class' \
    | grep -E 'Debezium|S3' || warn "Debezium or S3 plugin not listed"
else
  fail "Connect REST not responding — is the connect container up?"
fi

# ---- 4. source connector status ---------------------------------------------
section "4. Debezium source connector"
src=$(curl -sS http://localhost:8083/connectors/cmc-postgres-source/status 2>/dev/null || true)
if [[ -z "$src" ]]; then
  warn "cmc-postgres-source not registered"
else
  echo "$src" | jq '{connector: .connector.state, task: .tasks[0].state, trace: (.tasks[0].trace // "—" | .[0:600])}'
fi

# ---- 5. sink connector status (the usual suspect) ---------------------------
section "5. S3 sink connector"
snk=$(curl -sS http://localhost:8083/connectors/cmc-s3-sink/status 2>/dev/null || true)
if [[ -z "$snk" ]]; then
  warn "cmc-s3-sink not registered"
else
  echo "$snk" | jq '{connector: .connector.state, task: .tasks[0].state, trace: (.tasks[0].trace // "—" | .[0:600])}'
fi

# ---- 6. sink DLQ -------------------------------------------------------------
section "6. S3 sink DLQ (should be empty)"
docker compose -f infra/docker-compose.yml exec -T kafka \
  kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic dlq.s3.cryptocurrencies --from-beginning --timeout-ms 4000 2>&1 \
  | tail -n 20 || true

# ---- 7. postgres row count --------------------------------------------------
section "7. Postgres rows in cryptocurrencies"
PGPASSWORD="${PG_PASSWORD:-}" psql \
  "host=$PG_HOST user=$PG_USER dbname=$PG_DATABASE port=${PG_PORT:-5432} sslmode=require" \
  -At -c "SELECT COUNT(*) FROM cryptocurrencies;" 2>&1 || true

# ---- 8. replication slot ----------------------------------------------------
section "8. Postgres replication slot"
PGPASSWORD="${PG_PASSWORD:-}" psql \
  "host=$PG_HOST user=$PG_USER dbname=$PG_DATABASE port=${PG_PORT:-5432} sslmode=require" \
  -c "SELECT slot_name, plugin, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal FROM pg_replication_slots;" 2>&1 || true

# ---- 9. topic end offset -----------------------------------------------------
section "9. Kafka CDC topic end offset"
docker compose -f infra/docker-compose.yml exec -T kafka \
  kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list kafka:9092 --topic cdc.public.cryptocurrencies 2>&1 | tail -n 10 || true

# ---- 10. sink consumer lag ---------------------------------------------------
section "10. S3 sink consumer group lag"
docker compose -f infra/docker-compose.yml exec -T kafka \
  kafka-consumer-groups --bootstrap-server kafka:9092 \
  --describe --group connect-cmc-s3-sink 2>&1 | tail -n 10 || true

# ---- 11. IAM probe -----------------------------------------------------------
section "11. EC2 → S3 IAM probe"
probe="_iam_test_$(date +%s).txt"
if aws s3 ls "s3://$S3_BUCKET/" >/dev/null 2>&1; then
  ok "s3:ListBucket on $S3_BUCKET"
else
  fail "s3:ListBucket on $S3_BUCKET — IAM policy is missing ListBucket on the bucket ARN"
fi
if echo "probe $(date -u +%FT%TZ)" | aws s3 cp - "s3://$S3_BUCKET/$probe" >/dev/null 2>&1; then
  ok "s3:PutObject on $S3_BUCKET"
  aws s3 rm "s3://$S3_BUCKET/$probe" >/dev/null 2>&1 || true
else
  fail "s3:PutObject on $S3_BUCKET — IAM policy is missing PutObject on bucket/*"
fi

# ---- 12. topic prefix listing -----------------------------------------------
section "12. Current S3 objects under topic prefix"
aws s3 ls "s3://$S3_BUCKET/topics/cdc.public.cryptocurrencies/" --recursive 2>&1 | tail -n 20 || true

# ---- 13. recent connect errors ----------------------------------------------
section "13. Recent Connect errors (last 200 lines, filtered)"
docker compose -f infra/docker-compose.yml logs --tail=200 connect 2>&1 \
  | grep -iE 's3|access ?denied|forbidden|error|exception|warn' \
  | tail -n 40 || true

section "Done"
printf "Paste the output back and I'll point at the fix.\n"
