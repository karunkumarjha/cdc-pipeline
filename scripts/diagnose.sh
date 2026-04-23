#!/usr/bin/env bash
# Diagnose why CDC events aren't showing up in S3 (or why any piece of the
# Phase 1 pipeline looks wrong). Read-only except for one self-cleaning IAM
# probe that puts and deletes `_iam_test_<ts>.txt` in the bucket.
#
# Each section is verbose by design: announces what it's checking, prints
# the actual output it finds, and ends with PASS / WARN / FAIL + a one-line
# interpretation. A summary at the end lists every section and its verdict.
#
# Usage:
#   bash scripts/diagnose.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; N=$'\033[0m'

# Running tally of section verdicts for the summary at the end.
declare -a SECTION_NAMES
declare -a SECTION_RESULTS
declare -a SECTION_NOTES

# Print section header and record the current section for the summary.
CUR_IDX=-1
section() {
  CUR_IDX=$(( CUR_IDX + 1 ))
  SECTION_NAMES[$CUR_IDX]="$1"
  SECTION_RESULTS[$CUR_IDX]="(no verdict)"
  SECTION_NOTES[$CUR_IDX]=""
  printf "\n${BOLD}${CYAN}══ %s ══${N}\n" "$1"
}

checking() { printf "${DIM}→ %s${N}\n" "$*"; }
show()     { printf "  %s\n" "$*"; }
pass()     { SECTION_RESULTS[$CUR_IDX]="PASS"; SECTION_NOTES[$CUR_IDX]="$*"; printf "${GREEN}${BOLD}✓ PASS${N} — %s\n" "$*"; }
warn()     { SECTION_RESULTS[$CUR_IDX]="WARN"; SECTION_NOTES[$CUR_IDX]="$*"; printf "${YELLOW}${BOLD}! WARN${N} — %s\n" "$*"; }
fail()     { SECTION_RESULTS[$CUR_IDX]="FAIL"; SECTION_NOTES[$CUR_IDX]="$*"; printf "${RED}${BOLD}✗ FAIL${N} — %s\n" "$*"; }

# ────────────────────────────────────────────────────────────────────
section "1. Environment (.env)"
# run_cdc_pipeline.sh keeps the source-of-truth env at $HOME/.cdc-env and copies
# it into the repo as .env on each run. If the in-repo copy is missing
# (fresh clone, git clean, etc.) fall back to $HOME/.cdc-env.
ENV_CANDIDATES=( "$REPO_DIR/.env" "$HOME/.cdc-env" )
ENV_FILE=""
for cand in "${ENV_CANDIDATES[@]}"; do
  if [[ -f "$cand" ]]; then
    ENV_FILE="$cand"
    break
  fi
done

checking "locating env file among: ${ENV_CANDIDATES[*]}"
if [[ -n "$ENV_FILE" ]]; then
  set -a; . "$ENV_FILE"; set +a
  show "env sourced from $ENV_FILE"
else
  fail "no env file found — looked at: ${ENV_CANDIDATES[*]}"
  exit 1
fi

missing=()
for v in PG_HOST PG_PORT PG_DATABASE PG_USER PG_PASSWORD S3_BUCKET AWS_REGION DEBEZIUM_PG_PASSWORD CMC_API_KEY; do
  val="${!v:-}"
  if [[ -z "$val" ]]; then
    missing+=("$v")
    show "  ${RED}$v${N}=<empty>"
  elif [[ "$v" == *PASSWORD* || "$v" == *API_KEY* ]]; then
    show "  $v=**** (${#val} chars)"
  else
    show "  $v=$val"
  fi
done
if [[ ${#missing[@]} -eq 0 ]]; then
  pass "all 9 required env vars present"
else
  fail "missing/empty: ${missing[*]}"
fi

# ────────────────────────────────────────────────────────────────────
section "2. Docker containers"
checking "docker compose -f infra/docker-compose.yml ps"
if docker compose -f infra/docker-compose.yml ps 2>&1; then
  kafka_state=$(docker compose -f infra/docker-compose.yml ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$1=="kafka"{print $2}')
  connect_state=$(docker compose -f infra/docker-compose.yml ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$1=="connect"{print $2}')
  show "parsed: kafka=$kafka_state  connect=$connect_state"
  if [[ "$kafka_state" == "running" && "$connect_state" == "running" ]]; then
    pass "both kafka and connect are running"
  else
    fail "kafka=$kafka_state connect=$connect_state — at least one not running"
  fi
else
  fail "docker compose can't read infra/docker-compose.yml"
fi

# ────────────────────────────────────────────────────────────────────
section "3. Kafka Connect REST API"
checking "GET http://localhost:8083/ (Connect health)"
if curl -sf http://localhost:8083/ -o /tmp/conn_root 2>/dev/null; then
  cat /tmp/conn_root | jq . 2>/dev/null || cat /tmp/conn_root
  echo
  checking "GET /connector-plugins (listing available plugins)"
  plugins=$(curl -sS http://localhost:8083/connector-plugins | jq -r '.[].class' 2>/dev/null)
  echo "$plugins" | sed 's/^/  /'
  has_debz=0; has_s3=0
  echo "$plugins" | grep -q 'PostgresConnector' && has_debz=1
  echo "$plugins" | grep -q 'S3SinkConnector'   && has_s3=1
  if [[ $has_debz -eq 1 && $has_s3 -eq 1 ]]; then
    pass "Connect REST live; Debezium and S3 plugins both present"
  else
    fail "Connect REST live but missing plugin(s) — debezium=$has_debz s3=$has_s3"
  fi
else
  fail "Connect REST not responding at :8083 — container down or JVM not ready"
fi

# ────────────────────────────────────────────────────────────────────
section "4. Debezium source connector (cmc-postgres-source)"
checking "GET /connectors/cmc-postgres-source/status"
src=$(curl -sS http://localhost:8083/connectors/cmc-postgres-source/status 2>/dev/null || true)
if [[ -z "$src" ]]; then
  fail "cmc-postgres-source not registered"
else
  echo "$src" | jq .
  src_conn=$(echo "$src" | jq -r '.connector.state // "UNKNOWN"')
  src_task=$(echo "$src" | jq -r '.tasks[0].state // "UNKNOWN"')
  show "parsed: connector=$src_conn  task=$src_task"
  if [[ "$src_conn" == "RUNNING" && "$src_task" == "RUNNING" ]]; then
    pass "source connector + task both RUNNING"
  else
    fail "source not healthy (connector=$src_conn task=$src_task) — see trace above"
  fi
fi

# ────────────────────────────────────────────────────────────────────
section "5. S3 sink connector (cmc-s3-sink)"
checking "GET /connectors/cmc-s3-sink/status"
snk=$(curl -sS http://localhost:8083/connectors/cmc-s3-sink/status 2>/dev/null || true)
if [[ -z "$snk" ]]; then
  fail "cmc-s3-sink not registered"
else
  echo "$snk" | jq .
  snk_conn=$(echo "$snk" | jq -r '.connector.state // "UNKNOWN"')
  snk_task=$(echo "$snk" | jq -r '.tasks[0].state // "UNKNOWN"')
  show "parsed: connector=$snk_conn  task=$snk_task"
  if [[ "$snk_conn" == "RUNNING" && "$snk_task" == "RUNNING" ]]; then
    pass "sink connector + task both RUNNING"
  else
    fail "sink not healthy (connector=$snk_conn task=$snk_task) — the trace above is the root cause"
  fi
fi

# ────────────────────────────────────────────────────────────────────
section "6. S3 sink DLQ topic (dlq.s3.cryptocurrencies)"
checking "reading DLQ from beginning (4s timeout)"
dlq_out=$(docker compose -f infra/docker-compose.yml exec -T kafka \
  kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic dlq.s3.cryptocurrencies --from-beginning --timeout-ms 4000 2>&1 || true)
echo "$dlq_out" | tail -n 20 | sed 's/^/  /'
dlq_count=$(echo "$dlq_out" | grep -c 'Processed a total of' || true)
dlq_msgs=$(echo "$dlq_out" | grep -oE 'Processed a total of [0-9]+' | tail -1 | awk '{print $5}')
dlq_msgs="${dlq_msgs:-0}"
show "parsed: $dlq_msgs dead-letter messages"
if [[ "$dlq_msgs" == "0" ]]; then
  pass "DLQ is empty — no rejected records"
else
  warn "$dlq_msgs records in DLQ — inspect them, each failed delivery is here"
fi

# ────────────────────────────────────────────────────────────────────
section "7. Postgres rows in public.cryptocurrencies"
checking "SELECT COUNT(*) FROM cryptocurrencies (as $PG_USER)"
count=$(PGPASSWORD="${PG_PASSWORD:-}" psql \
  "host=$PG_HOST user=$PG_USER dbname=$PG_DATABASE port=${PG_PORT:-5432} sslmode=require" \
  -At -c "SELECT COUNT(*) FROM cryptocurrencies;" 2>&1 || true)
show "result: $count"
if [[ "$count" =~ ^[0-9]+$ ]]; then
  if [[ "$count" -gt 0 ]]; then
    pass "$count rows present in cryptocurrencies"
  else
    warn "table is empty — ingestion (uv run python -m cdc_pipeline.main) hasn't succeeded yet"
  fi
else
  fail "could not query Postgres — $count"
fi

# ────────────────────────────────────────────────────────────────────
section "8. Postgres replication slot"
checking "SELECT ... FROM pg_replication_slots"
slot_out=$(PGPASSWORD="${PG_PASSWORD:-}" psql \
  "host=$PG_HOST user=$PG_USER dbname=$PG_DATABASE port=${PG_PORT:-5432} sslmode=require" \
  -c "SELECT slot_name, plugin, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal FROM pg_replication_slots;" 2>&1 || true)
echo "$slot_out" | sed 's/^/  /'
if echo "$slot_out" | grep -q 'debezium_slot.*pgoutput.*| t'; then
  pass "debezium_slot exists, plugin=pgoutput, active=t (Connect is attached)"
elif echo "$slot_out" | grep -q 'debezium_slot.*| f'; then
  fail "debezium_slot exists but active=f — Connect is not consuming, will pile up WAL"
elif echo "$slot_out" | grep -q '(0 rows)'; then
  fail "no replication slot — Debezium hasn't attached yet (task never reached RUNNING?)"
else
  warn "unexpected output — review manually"
fi

# ────────────────────────────────────────────────────────────────────
section "9. Kafka CDC topic end offset"
checking "kafka-run-class GetOffsetShell --topic cdc.public.cryptocurrencies"
off_out=$(docker compose -f infra/docker-compose.yml exec -T kafka \
  kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list kafka:9092 --topic cdc.public.cryptocurrencies 2>&1 | tail -n 10 || true)
echo "$off_out" | sed 's/^/  /'
end_off=$(echo "$off_out" | awk -F: '/cdc\.public\.cryptocurrencies:/{sum+=$3} END{print sum+0}')
show "parsed: topic has $end_off messages total (sum across partitions)"
if [[ "$end_off" -gt 0 ]]; then
  pass "topic has $end_off messages — Debezium IS publishing"
else
  fail "topic is empty — Debezium isn't publishing (check source trace in section 4)"
fi

# ────────────────────────────────────────────────────────────────────
section "10. S3 sink consumer group lag"
checking "kafka-consumer-groups --describe --group connect-cmc-s3-sink"
lag_out=$(docker compose -f infra/docker-compose.yml exec -T kafka \
  kafka-consumer-groups --bootstrap-server kafka:9092 \
  --describe --group connect-cmc-s3-sink 2>&1 | tail -n 10 || true)
echo "$lag_out" | sed 's/^/  /'
lag=$(echo "$lag_out" | awk '/cdc\.public\.cryptocurrencies/{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/) v=$i; print v}' | tail -1)
lag="${lag:-?}"
show "parsed: current lag = $lag"
if [[ "$lag" == "?" || "$lag" == "" ]]; then
  warn "no consumer-group data yet — sink hasn't consumed anything (task alive?)"
elif [[ "$lag" == "0" ]]; then
  pass "sink has consumed everything (lag=0); if S3 is still empty, flush threshold hasn't fired"
else
  warn "lag=$lag — sink is behind, either consuming slowly or flush-stuck"
fi

# ────────────────────────────────────────────────────────────────────
section "11. EC2 → S3 IAM probe"
checking "aws s3 ls s3://$S3_BUCKET/  (tests s3:ListBucket)"
if ls_out=$(aws s3 ls "s3://$S3_BUCKET/" 2>&1); then
  echo "$ls_out" | head -n 5 | sed 's/^/  /'
  show "(list succeeded)"
  list_ok=1
else
  echo "$ls_out" | sed 's/^/  /'
  list_ok=0
fi

checking "aws s3 cp - s3://$S3_BUCKET/_iam_test_<ts>.txt  (tests s3:PutObject)"
probe="_iam_test_$(date +%s).txt"
if put_out=$(echo "probe $(date -u +%FT%TZ)" | aws s3 cp - "s3://$S3_BUCKET/$probe" 2>&1); then
  echo "$put_out" | sed 's/^/  /'
  aws s3 rm "s3://$S3_BUCKET/$probe" >/dev/null 2>&1 || true
  show "(put+delete succeeded; cleanup OK)"
  put_ok=1
else
  echo "$put_out" | sed 's/^/  /'
  put_ok=0
fi

if [[ $list_ok -eq 1 && $put_ok -eq 1 ]]; then
  pass "EC2 instance profile has ListBucket + PutObject on $S3_BUCKET"
else
  fail "IAM broken — ListBucket=$list_ok PutObject=$put_ok — recheck role policy JSON"
fi

# ────────────────────────────────────────────────────────────────────
section "12. S3 objects under topic prefix"
checking "aws s3 ls s3://$S3_BUCKET/topics/cdc.public.cryptocurrencies/ --recursive"
s3_out=$(aws s3 ls "s3://$S3_BUCKET/topics/cdc.public.cryptocurrencies/" --recursive 2>&1 || true)
if [[ -z "$s3_out" ]]; then
  show "(no output — prefix is empty)"
  obj_count=0
else
  echo "$s3_out" | head -n 20 | sed 's/^/  /'
  obj_count=$(echo "$s3_out" | wc -l | tr -d ' ')
fi
show "parsed: $obj_count object(s) under prefix"
if [[ "$obj_count" -gt 0 ]]; then
  pass "$obj_count object(s) present in S3 — the pipeline IS writing"
else
  warn "S3 prefix is empty — either sink hasn't flushed yet, or sink is broken (see section 5)"
fi

# ────────────────────────────────────────────────────────────────────
section "13. Recent Connect errors (last 200 lines, filtered)"
checking "docker compose logs --tail=200 connect | grep -iE 's3|access denied|forbidden|error|exception|warn'"
err_out=$(docker compose -f infra/docker-compose.yml logs --tail=200 connect 2>&1 \
  | grep -iE 's3|access ?denied|forbidden|error|exception|warn' | tail -n 40 || true)
if [[ -z "$err_out" ]]; then
  show "(no matching lines)"
  pass "no errors/warnings in recent Connect logs"
else
  echo "$err_out" | sed 's/^/  /'
  err_serious=$(echo "$err_out" | grep -ciE 'access ?denied|forbidden|exception|\bERROR\b' || true)
  if [[ "$err_serious" -gt 0 ]]; then
    warn "$err_serious serious log line(s) — review above"
  else
    pass "only benign WARN lines in recent logs"
  fi
fi

# ────────────────────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}══ SUMMARY ══${N}\n"
for i in "${!SECTION_NAMES[@]}"; do
  res="${SECTION_RESULTS[$i]}"
  case "$res" in
    PASS) color="$GREEN" ;;
    WARN) color="$YELLOW" ;;
    FAIL) color="$RED" ;;
    *)    color="$DIM" ;;
  esac
  printf "  %s%-4s%s  %s\n" "$color" "$res" "$N" "${SECTION_NAMES[$i]}"
  [[ -n "${SECTION_NOTES[$i]}" ]] && printf "        ${DIM}%s${N}\n" "${SECTION_NOTES[$i]}"
done

fails=$(printf '%s\n' "${SECTION_RESULTS[@]}" | grep -c '^FAIL' || true)
if [[ "$fails" -eq 0 ]]; then
  printf "\n${GREEN}${BOLD}No FAIL sections.${N} If S3 is empty, the sink simply hasn't rotated yet — wait ~1 min.\n"
else
  printf "\n${RED}${BOLD}%d FAIL section(s) above — fix the earliest one first.${N}\n" "$fails"
fi
