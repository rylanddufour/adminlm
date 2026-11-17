#!/usr/bin/env bash
# adminlm-restore-infisical.sh
# Restore the Infisical customer-IT secret store from an AdminLM backup
# tarball onto an AdminLM install (typically a fresh one).
#
# What it restores:
#   - infisical-stack/.env      — ENCRYPTION_KEY + Postgres/Redis creds.
#                                  WITHOUT this the Postgres dump is unreadable.
#   - the Postgres logical dump — every customer IT secret, exactly.
#
# What it does NOT restore:
#   - the Redis RDB. Infisical rebuilds its cache; replaying a stale cache
#     that references deleted identities causes auth errors, so it stays out.
#
# Usage:
#   adminlm-restore-infisical.sh <backup-tarball> [--yes]
#
# DESTRUCTIVE: overwrites the live Infisical database. --yes is required.
#
# Restore order matters:
#   1. postgres + redis only  (the app is NOT running yet)
#   2. replay the dump        (so the app never migrates an empty DB)
#   3. start the app          (it finds a fully-populated schema)

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

ADMINLM_DIR="${ADMINLM_DIR:-$HOME/adminlm}"
INFISICAL_STACK_DIR="${INFISICAL_STACK_DIR:-$ADMINLM_DIR/infisical-stack}"
COMPOSE_FILE="$INFISICAL_STACK_DIR/docker-compose.yml"
INFISICAL_URL="${INFISICAL_URL:-http://127.0.0.1:8090}"

TARBALL=""
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help)
            sed -n '2,25p' "$0"
            exit 0 ;;
        *) TARBALL="$arg" ;;
    esac
done

log()  { echo "[$(date -Is)] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$TARBALL" ] || { sed -n '2,25p' "$0"; exit 1; }
[ -f "$TARBALL" ] || fail "tarball not found: $TARBALL"
[ -f "$COMPOSE_FILE" ] || fail "compose file not found: $COMPOSE_FILE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Extracting $TARBALL"
tar -xzf "$TARBALL" -C "$WORK"

DB_DUMP="$WORK/infisical/infisical-db.sql.gz"
ENV_SRC="$WORK/infisical/infisical-stack.env"
MANIFEST="$WORK/MANIFEST.json"

[ -f "$DB_DUMP" ] || fail "archive has no infisical/infisical-db.sql.gz — was this backup taken before the Infisical capture was added?"
[ -f "$ENV_SRC" ]  || fail "archive has no infisical/infisical-stack.env — WITHOUT IT THE DUMP CANNOT BE DECRYPTED"

EXPECTED_COUNT=""
if [ -f "$MANIFEST" ]; then
    EXPECTED_COUNT="$(python3 -c '
import json,sys
try:
    print(json.load(open(sys.argv[1])).get("infisical_secret_count",""))
except Exception:
    print("")
' "$MANIFEST")"
fi

echo ""
echo "=== Restore plan ==="
echo "  tarball          : $TARBALL"
echo "  stack dir        : $INFISICAL_STACK_DIR"
echo "  expected secrets : ${EXPECTED_COUNT:-unknown}"
echo "  DESTRUCTIVE      : the live Infisical database is replaced"
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
    echo "Re-run with --yes to perform the restore."
    exit 2
fi

# Read the DB identity out of the BACKUP's env file — it must match the dump.
PG_USER="$(grep -m1 '^POSTGRES_USER=' "$ENV_SRC" | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' | tr -d '\r')"
PG_DB="$(grep -m1 '^POSTGRES_DB=' "$ENV_SRC" | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' | tr -d '\r')"
[ -n "$PG_USER" ] || fail "POSTGRES_USER not found in the archive's infisical-stack.env"
[ -n "$PG_DB" ]   || fail "POSTGRES_DB not found in the archive's infisical-stack.env"

# ===== 1. Install the env file (BEFORE postgres starts) =====
# A fresh Postgres volume initialises its superuser from POSTGRES_USER /
# POSTGRES_PASSWORD / POSTGRES_DB. Putting the backup's env in place first
# means the fresh volume comes up with the SAME credentials the dump was
# taken under.
if [ -f "$INFISICAL_STACK_DIR/.env" ]; then
    cp "$INFISICAL_STACK_DIR/.env" "$INFISICAL_STACK_DIR/.env.pre-restore.bak"
    log "Existing $INFISICAL_STACK_DIR/.env backed up to .env.pre-restore.bak"
fi
cp "$ENV_SRC" "$INFISICAL_STACK_DIR/.env"
chmod 600 "$INFISICAL_STACK_DIR/.env"
log "Installed Infisical env (ENCRYPTION_KEY + DB/Redis creds)"

# ===== 2. Start postgres + redis only =====
log "Starting infisical-postgres + infisical-redis (app held back)"
docker compose -f "$COMPOSE_FILE" up -d infisical-postgres infisical-redis >/dev/null

log "Waiting for postgres to accept connections"
READY=0
for i in $(seq 1 60); do
    if docker exec infisical-postgres pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 2
done
[ "$READY" -eq 1 ] || fail "postgres did not become ready within 120s"
log "  postgres ready"

# ===== 3. Replay the dump =====
log "Replaying Postgres dump"
if ! gunzip -c "$DB_DUMP" | docker exec -i infisical-postgres \
        psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -q >"$WORK/restore.log" 2>&1; then
    log "psql output (tail):"
    tail -20 "$WORK/restore.log" >&2 || true
    fail "dump replay failed — see the tail above"
fi
log "  dump replayed"

# ===== 4. Start the app =====
log "Starting infisical app"
docker compose -f "$COMPOSE_FILE" up -d infisical >/dev/null

log "Waiting for the Infisical API"
API_OK=0
for i in $(seq 1 60); do
    if curl -fsS -m 3 "$INFISICAL_URL/api/status" >/dev/null 2>&1; then
        API_OK=1
        break
    fi
    sleep 2
done
[ "$API_OK" -eq 1 ] || fail "Infisical API did not become healthy within 120s"
log "  API healthy"

# ===== 5. Verify =====
ACTUAL_COUNT=""
for T in public.secrets_v2 public.secrets; do
    C=$(docker exec infisical-postgres psql -U "$PG_USER" -d "$PG_DB" -tAc \
          "select count(*) from $T;" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$C" ] && [ "$C" != "0" ]; then
        ACTUAL_COUNT="$C"
        break
    fi
done
ACTUAL_COUNT="${ACTUAL_COUNT:-0}"

echo ""
echo "=== Restore verification ==="
echo "  secret count in DB   : $ACTUAL_COUNT"
echo "  secret count expected: ${EXPECTED_COUNT:-unknown}"
if [ -n "$EXPECTED_COUNT" ]; then
    if [ "$ACTUAL_COUNT" = "$EXPECTED_COUNT" ]; then
        echo "  RESULT               : PASS (counts match)"
    else
        fail "  RESULT               : FAIL (count mismatch)"
    fi
else
    echo "  RESULT               : restored (no expected count in manifest to compare against)"
fi
echo ""
echo "Restore complete. Verify a secret end-to-end through the Streamlit"
echo "Secrets page before declaring the disaster recovered."
