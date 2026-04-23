#!/usr/bin/env bash
# One-shot bootstrap for the CDC pipeline on a fresh (or wiped) EC2 instance.
# From zero → CMC rows in S3 as JSON, with no manual steps.
#
# Prerequisites on the EC2:
#   • Amazon Linux 2023, IAM instance profile cdc-pipeline-ec2 attached.
#   • RDS instance up, logical replication enabled, SG allows EC2 inbound.
#   • S3 bucket created.
#   • A populated env file at $HOME/.cdc-env (default) or passed as $1.
#     See the template printed below if the file is missing.
#
# Usage:
#   bash run_cdc_pipeline.sh                # uses $HOME/.cdc-env
#   bash run_cdc_pipeline.sh /path/to/env   # uses the path you pass
#
# Re-running is safe: every step is idempotent. The script will:
#   1. install base packages (git, psql, docker, buildx, compose, uv)
#   2. enable a 1 GB swap file
#   3. clone/update the repo into ~/cdc_pipeline
#   4. create the Postgres `debezium` role (if missing)
#   5. apply SQL migrations
#   6. build & start Kafka + Kafka Connect via docker compose
#   7. register both connectors via PUT /config (idempotent)
#   8. run the ingestion script once
#   9. wait up to 2 min for the S3 sink to flush, then list the objects

set -Eeuo pipefail

REPO_URL="https://github.com/karunkumarjha/cdc-pipeline.git"
REPO_DIR="${HOME}/cdc_pipeline"
ENV_SRC="${1:-${HOME}/.cdc-env}"

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
log()  { printf "\n${B}[%s] %s${N}\n" "$(date +%H:%M:%S)" "$*"; }
ok()   { printf "${G}ok${N}    %s\n" "$*"; }
warn() { printf "${Y}warn${N}  %s\n" "$*"; }
die()  { printf "${R}fail${N}  %s\n" "$*" >&2; exit 1; }

# ---------- env file gate ----------
if [[ ! -f "$ENV_SRC" ]]; then
  cat >&2 <<ENVTMPL

Env file not found: $ENV_SRC

Create it first (keep it OUTSIDE the repo so it survives 'rm -rf cdc_pipeline'):

  cat > $ENV_SRC <<'EOF'
  # Coin Market Cap
  CMC_API_KEY=your_cmc_key

  # RDS Postgres
  PG_HOST=cdc-pipeline.xxxxxxxx.us-east-1.rds.amazonaws.com
  PG_PORT=5432
  PG_DATABASE=cdc
  PG_USER=postgres
  PG_PASSWORD=your_master_password
  DEBEZIUM_PG_PASSWORD=choose_a_strong_password

  # S3
  S3_BUCKET=cdc-pipeline-events-<suffix>
  AWS_REGION=us-east-1
  EOF
  chmod 600 $ENV_SRC

Then re-run this script.
ENVTMPL
  exit 1
fi

# ---------- 1. base packages ----------
log "1/9 Installing base packages (git, psql, docker)"
NEED_RELOGIN=false
if ! command -v docker >/dev/null 2>&1; then
  sudo dnf install -y git postgresql16 docker jq
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"
  NEED_RELOGIN=true
else
  sudo dnf install -y -q git postgresql16 jq >/dev/null
fi
ok "base packages present"

# ---------- 2. docker compose + buildx plugins ----------
log "2/9 Installing docker compose v2 + buildx plugins"
sudo mkdir -p /usr/local/lib/docker/cli-plugins
if [[ ! -x /usr/local/lib/docker/cli-plugins/docker-compose ]]; then
  sudo curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi
if [[ ! -x /usr/local/lib/docker/cli-plugins/docker-buildx ]]; then
  BX=v0.19.0
  sudo curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-buildx \
    "https://github.com/docker/buildx/releases/download/${BX}/buildx-${BX}.linux-amd64"
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
fi
ok "compose + buildx present"

# ---------- 3. uv ----------
log "3/9 Installing uv"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
ok "uv $(uv --version 2>/dev/null || echo installed)"

# ---------- 4. swap ----------
log "4/9 Ensuring 1 GB swap"
if ! swapon --show 2>/dev/null | grep -q /swapfile; then
  sudo fallocate -l 1G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
ok "swap active"

# ---------- re-login gate ----------
# usermod -aG docker only takes effect in new login shells. If this is the
# very first run, bail here so the user re-SSHs with the docker group active
# (or opens a fresh Session Manager session).
if [[ "$NEED_RELOGIN" == "true" ]]; then
  warn "Docker was just installed and added you to the docker group."
  warn "Exit this shell, open a new one (ssh / SSM), and re-run this script."
  exit 0
fi
if ! docker ps >/dev/null 2>&1; then
  die "docker daemon not reachable as '$USER' — open a new shell and re-run"
fi

# ---------- 5. fresh-start cleanup + repo ----------
log "5/9 Tearing down any previous stack and cloning repo at $REPO_DIR"
# If a previous compose stack is still running, stop it and wipe the
# kafka-data volume so Kafka starts with a clean cluster ID + log dir.
if [[ -f "$REPO_DIR/infra/docker-compose.yml" ]]; then
  (cd "$REPO_DIR/infra" && docker compose down -v --remove-orphans >/dev/null 2>&1 || true)
fi
# Drop any orphan kafka-data volume from earlier attempts.
docker volume rm -f $(docker volume ls -q | grep -E '(^|_)kafka-data$' || true) >/dev/null 2>&1 || true

if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" fetch --quiet origin
  git -C "$REPO_DIR" reset --hard --quiet origin/main
else
  rm -rf "$REPO_DIR"
  git clone --quiet "$REPO_URL" "$REPO_DIR"
fi
cp "$ENV_SRC" "$REPO_DIR/.env"
chmod 600 "$REPO_DIR/.env"
ok "repo ready"

cd "$REPO_DIR"
set -a; . "$REPO_DIR/.env"; set +a

# Drop any orphan Debezium replication slot from a prior run — otherwise
# the new Debezium task refuses to create a slot with the same name or
# resumes from a stale LSN.
log "   dropping stale Debezium replication slot if present"
PGPASSWORD="$PG_PASSWORD" psql \
  "host=$PG_HOST user=postgres dbname=$PG_DATABASE port=${PG_PORT:-5432} sslmode=require" \
  -v ON_ERROR_STOP=1 -At <<'SQL' >/dev/null
SELECT pg_drop_replication_slot('debezium_slot')
  WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='debezium_slot');
SQL
ok "slot clean"

# ---------- 6. debezium role + migrations ----------
log "6/9 Creating debezium Postgres role (idempotent)"
PG_CONN="host=$PG_HOST user=postgres dbname=$PG_DATABASE port=${PG_PORT:-5432} sslmode=require"

# psql's :'var' substitution only works on stdin/file input, not -c, so
# pipe the CREATE/ALTER through a heredoc. Single-quoted <<'SQL' prevents
# the shell from expanding :'pwd' before psql sees it.
role_exists=$(PGPASSWORD="$PG_PASSWORD" psql "$PG_CONN" \
  -v ON_ERROR_STOP=1 -At -c "SELECT 1 FROM pg_roles WHERE rolname='debezium';")
if [[ "$role_exists" == "1" ]]; then
  PGPASSWORD="$PG_PASSWORD" psql "$PG_CONN" -v ON_ERROR_STOP=1 \
    -v pwd="$DEBEZIUM_PG_PASSWORD" <<'SQL' >/dev/null
ALTER ROLE debezium WITH LOGIN PASSWORD :'pwd';
SQL
else
  PGPASSWORD="$PG_PASSWORD" psql "$PG_CONN" -v ON_ERROR_STOP=1 \
    -v pwd="$DEBEZIUM_PG_PASSWORD" <<'SQL' >/dev/null
CREATE ROLE debezium WITH LOGIN PASSWORD :'pwd';
SQL
fi
PGPASSWORD="$PG_PASSWORD" psql "$PG_CONN" -v ON_ERROR_STOP=1 \
  -c "GRANT rds_replication TO debezium;" >/dev/null
ok "debezium role present with rds_replication"

log "   applying SQL migrations"
uv sync --quiet
uv run python scripts/apply_migrations.py
ok "migrations applied"

# ---------- 7. kafka + connect ----------
log "7/9 Building and starting kafka + connect"
cd "$REPO_DIR/infra"
docker compose up -d --build
cd "$REPO_DIR"

log "   waiting for Connect REST at :8083 (up to 3 min)"
for i in {1..60}; do
  if curl -sf http://localhost:8083/ >/dev/null 2>&1; then
    ok "Connect REST is live"
    break
  fi
  sleep 3
  if [[ $i -eq 60 ]]; then
    die "Connect never came up — inspect: cd $REPO_DIR/infra && docker compose logs connect"
  fi
done

log "   checking plugins are loaded"
plugins=$(curl -sS http://localhost:8083/connector-plugins | jq -r '.[].class')
echo "$plugins" | grep -q 'PostgresConnector' || die "Debezium plugin missing from Connect"
echo "$plugins" | grep -q 'S3SinkConnector'   || die "S3 sink plugin missing from Connect"
ok "both plugins loaded"

# ---------- 8. register connectors (idempotent PUT) ----------
log "8/9 Registering connectors (idempotent PUT /config)"
for cfg in infra/connectors/postgres-source.json infra/connectors/s3-sink.json; do
  name=$(jq -r '.name' "$cfg")
  http=$(jq -c '.config' "$cfg" | curl -sS -o /tmp/connect_resp -w '%{http_code}' \
    -X PUT -H 'Content-Type: application/json' -d @- \
    "http://localhost:8083/connectors/$name/config")
  if [[ "$http" != "200" && "$http" != "201" ]]; then
    cat /tmp/connect_resp
    die "PUT $name returned HTTP $http"
  fi
  ok "$name config applied"
done

log "   waiting for both connectors to reach RUNNING (up to 2 min)"
for name in cmc-postgres-source cmc-s3-sink; do
  for i in {1..40}; do
    body=$(curl -sS "localhost:8083/connectors/$name/status" || true)
    state=$(echo "$body" | jq -r '.tasks[0].state // "PENDING"')
    if [[ "$state" == "RUNNING" ]]; then
      ok "$name task RUNNING"
      break
    fi
    if [[ "$state" == "FAILED" ]]; then
      echo "$body" | jq .
      die "$name task FAILED — see trace above"
    fi
    sleep 3
    if [[ $i -eq 40 ]]; then
      echo "$body" | jq .
      die "$name never reached RUNNING"
    fi
  done
done

# ---------- 9. ingest + verify ----------
log "9/9 Running ingestion"
uv run python -m cdc_pipeline.main

rows=$(PGPASSWORD="$PG_PASSWORD" psql \
  "host=$PG_HOST user=$PG_USER dbname=$PG_DATABASE port=${PG_PORT:-5432} sslmode=require" \
  -At -c "SELECT COUNT(*) FROM cryptocurrencies;")
ok "cryptocurrencies rows in Postgres: $rows"

log "   waiting up to 2 min for the S3 sink to flush (rotate.interval.ms=1min)"
deadline=$(( $(date +%s) + 120 ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  listing=$(aws s3 ls "s3://$S3_BUCKET/topics/cdc.public.cryptocurrencies/" --recursive 2>/dev/null || true)
  if echo "$listing" | grep -q '\.json$'; then
    ok "S3 objects present:"
    echo "$listing"
    first=$(echo "$listing" | awk '{print $4}' | head -n 1)
    if [[ -n "$first" ]]; then
      echo
      echo "First record from $first:"
      aws s3 cp "s3://$S3_BUCKET/$first" - | head -n 1 | jq .
    fi
    log "Phase 1 pipeline is fully operational."
    exit 0
  fi
  printf "."
  sleep 10
done

warn "No S3 objects after 6 min — flush hasn't fired yet."
warn "Run the diagnostic script to investigate:"
warn "  bash $REPO_DIR/scripts/diagnose.sh"
exit 2
