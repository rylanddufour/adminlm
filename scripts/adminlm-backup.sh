#!/usr/bin/env bash
# adminlm-backup.sh
# Comprehensive AdminLM stack backup for disaster recovery.
#
# Captures, in one tarball:
#   1. Grafana dashboards — via the Grafana API (catches UI edits)
#   2. Grafana dashboards — provisioning source files from
#      ~/adminlm/config/grafana/provisioning/dashboards/ (catches provisioning
#      source-of-truth, including metadata like uid, datasource refs)
#   3. Hermes state — single zip via `hermes backup` (covers ~/.hermes minus
#      the agent codebase: profiles, sessions, kanban, cron jobs, .env, etc.)
#   4. Inventory MCP SQLite database (via sqlite3 .backup + docker cp)
#   5. KB MCP SQLite database (same pattern)
#   6. Grafana-stack yml configs (alloy, blackbox, loki, prometheus, promtail,
#      datasources, dashboards.yml provisioning config)
#   7. Infisical customer-IT secret store — Postgres logical dump PLUS the
#      ENCRYPTION_KEY material needed to decrypt it (a dump alone is useless)
#
# Excluded intentionally:
#   - Loki chunks + Prometheus TSDB — backed up by their own retention
#     mechanisms (BACKLOG #5 covers Loki; Prometheus snapshot API for metrics)
#   - hermes-agent code — installable from PyPI; not customer state
#   - Docker volumes for grafana-data / loki / prometheus — service-level
#
# Output: ~/backups/adminlm-backup-YYYYMMDD-HHMMSS.tar.gz
# Retention: last 14 daily backups (rotated)
#
# Cron: 0 1 * * *   (daily at 01:00, fired by the AdminLM Backup Hermes cron job)
# Run as: the AdminLM install user (e.g. ansible). hermes and docker must be on PATH.

set -euo pipefail

# Ensure the user-local bin (where `hermes` and `pip --user` installs land) is
# on PATH. System crons and the hermes-gateway systemd unit don't always
# source the user's profile, so the cron job's script needs to do it.
export PATH="$HOME/.local/bin:$PATH"

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
TOKEN_FILE="${GRAFANA_TOKEN_FILE:-$HOME/.hermes/secrets/grafana-mcp.env}"
ADMINLM_DIR="${ADMINLM_DIR:-$HOME/adminlm}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
KEEP="${KEEP:-14}"
TS="$(date -u +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
ARCHIVE="$BACKUP_DIR/adminlm-backup-${TS}.tar.gz"

mkdir -p "$BACKUP_DIR" \
         "$WORK/dashboards" \
         "$WORK/dashboards-provisioned" \
         "$WORK/config" \
         "$WORK/db" \
         "$WORK/hermes" \
         "$WORK/infisical"
trap 'rm -rf "$WORK"' EXIT

log() { echo "[$(date -Is)] $*"; }
fail() { log "ERROR: $*"; exit 1; }

# Read one key from an env-style file (no shell sourcing — the Infisical .env
# defines DB_CONNECTION_URI / REDIS_URL / SMTP_* and sourcing it under
# `set -u` is fragile). Strips optional surrounding quotes.
envval() {
    grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2- \
        | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" | tr -d '\r'
}

# ===== Load Grafana service account token (shared with the agent profiles) =====
[ -r "$TOKEN_FILE" ] || fail "token file not readable: $TOKEN_FILE (create_grafana_mcp_service_account creates it)"
# shellcheck disable=SC1090
. "$TOKEN_FILE"
GRAFANA_TOKEN="${GRAFANA_SERVICE_ACCOUNT_TOKEN:-}"
[ -n "$GRAFANA_TOKEN" ] && [[ "$GRAFANA_TOKEN" != *...* ]] \
    || fail "GRAFANA_SERVICE_ACCOUNT_TOKEN missing or placeholder in $TOKEN_FILE"

api() { curl -fsS -H "Authorization: Bearer $GRAFANA_TOKEN" -H 'Accept: application/json' "$@"; }

# ===== 1. Grafana dashboards — API export (captures customer UI edits) =====
log "Exporting dashboards from $GRAFANA_URL (API)"
SEARCH_JSON="$(api "${GRAFANA_URL}/api/search?type=dash-db&limit=5000")"
API_COUNT=$(printf '%s' "$SEARCH_JSON" | grep -o '"uid":"' | wc -l)
log "  found $API_COUNT dashboard(s) via API"
EXPORTED=0
for uid in $(printf '%s' "$SEARCH_JSON" | grep -o '"uid":"[^"]*"' | sed 's/"uid":"//;s/"//g'); do
    RAW="$(api "${GRAFANA_URL}/api/dashboards/uid/${uid}" 2>/dev/null)" || {
        log "  WARN: failed to fetch $uid via API, skipping"
        continue
    }
    SLUG=$(printf '%s' "$RAW" | python3 -c "
import sys, json
d = json.load(sys.stdin)['dashboard']
print(d.get('slug') or d.get('uid') or 'unknown')
" 2>/dev/null || echo "$uid")
    SLUG="$(printf '%s' "$SLUG" | tr -c '[:alnum:]._-' '-' | head -c 64)"
    OUT="$WORK/dashboards/${SLUG}__${uid}.json"
    printf '%s' "$RAW" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps(d.get('dashboard', d), indent=2, sort_keys=True))
" > "$OUT" 2>/dev/null \
        || { log "  WARN: failed to write $uid, skipping"; continue; }
    EXPORTED=$((EXPORTED + 1))
done
log "  exported $EXPORTED dashboard(s) via API"

# ===== 2. Grafana dashboards — provisioning source files =====
if [ -d "$ADMINLM_DIR/config/grafana/provisioning/dashboards" ]; then
    cp "$ADMINLM_DIR/config/grafana/provisioning/dashboards"/*.json \
       "$WORK/dashboards-provisioned/" 2>/dev/null || true
    PROV_COUNT=$(ls -1 "$WORK/dashboards-provisioned"/*.json 2>/dev/null | wc -l)
    log "Copied $PROV_COUNT provisioning dashboard(s) from filesystem"
else
    PROV_COUNT=0
    log "WARN: $ADMINLM_DIR/config/grafana/provisioning/dashboards not found"
fi

# ===== 3. Hermes state =====
if command -v hermes >/dev/null 2>&1; then
    log "Running hermes backup (covers ~/.hermes)"
    if hermes backup --output "$WORK/hermes/backup.zip" 2>>"$WORK/hermes.err"; then
        HERMES_SIZE=$(stat -c%s "$WORK/hermes/backup.zip" 2>/dev/null || echo 0)
        log "  hermes backup: $HERMES_SIZE bytes"
    else
        log "  WARN: hermes backup failed (see $WORK/hermes.err); continuing"
        HERMES_SIZE=0
    fi
else
    log "WARN: hermes not on PATH; skipping hermes backup"
    HERMES_SIZE=0
fi

# ===== 4. Inventory DB =====
# Use python3's sqlite3 module (always present in the Python-based container)
# rather than the sqlite3 CLI (not in these images).
INVENTORY_SIZE=0
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'inventory-mcp'; then
    log "Backing up inventory DB"
    if docker exec inventory-mcp python3 -c '
import sqlite3, shutil
src = sqlite3.connect("/data/inventory.db")
dst = sqlite3.connect("/data/inventory.db.bak")
with dst:
    src.backup(dst)
src.close(); dst.close()
' 2>>"$WORK/db.err"; then
        if docker cp inventory-mcp:/data/inventory.db.bak "$WORK/db/inventory.db" 2>>"$WORK/db.err"; then
            INVENTORY_SIZE=$(stat -c%s "$WORK/db/inventory.db" 2>/dev/null || echo 0)
            log "  inventory DB: $INVENTORY_SIZE bytes"
        else
            log "  WARN: docker cp of inventory failed"
        fi
        docker exec inventory-mcp rm -f /data/inventory.db.bak 2>/dev/null || true
    else
        log "  WARN: python sqlite3 backup of inventory failed"
    fi
else
    log "WARN: inventory-mcp container not running; skipping inventory DB"
fi

# ===== 5. KB DB =====
# Same pattern as inventory.
KB_SIZE=0
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'kb-mcp'; then
    log "Backing up KB DB"
    if docker exec kb-mcp python3 -c '
import sqlite3
src = sqlite3.connect("/data/kb.db")
dst = sqlite3.connect("/data/kb.db.bak")
with dst:
    src.backup(dst)
src.close(); dst.close()
' 2>>"$WORK/db.err"; then
        if docker cp kb-mcp:/data/kb.db.bak "$WORK/db/kb.db" 2>>"$WORK/db.err"; then
            KB_SIZE=$(stat -c%s "$WORK/db/kb.db" 2>/dev/null || echo 0)
            log "  KB DB: $KB_SIZE bytes"
        else
            log "  WARN: docker cp of KB failed"
        fi
        docker exec kb-mcp rm -f /data/kb.db.bak 2>/dev/null || true
    else
        log "  WARN: python sqlite3 backup of KB failed"
    fi
else
    log "WARN: kb-mcp container not running; skipping KB DB"
fi

# ===== 6. Config yml files =====
log "Copying yml config files"
for f in alloy.yml blackbox.yml loki.yml prometheus.yml promtail.yml; do
    if [ -f "$ADMINLM_DIR/config/$f" ]; then
        cp "$ADMINLM_DIR/config/$f" "$WORK/config/"
    else
        log "  WARN: missing $ADMINLM_DIR/config/$f"
    fi
done
for f in grafana/provisioning/datasources/datasources.yml \
         grafana/provisioning/dashboards/dashboards.yml; do
    if [ -f "$ADMINLM_DIR/config/$f" ]; then
        cp "$ADMINLM_DIR/config/$f" "$WORK/config/$(basename "$f")"
    else
        log "  WARN: missing $ADMINLM_DIR/config/$f"
    fi
done


# ===== 7. Infisical — customer IT secret store =====
# Infisical encrypts every secret value at rest using ENCRYPTION_KEY from
# infisical-stack/.env. A Postgres dump on its own is therefore unreadable —
# the backup MUST capture the encryption material alongside the dump, or the
# customer loses their secrets on restore.
#
# v1.0 ships this PLAIN. Operator decision 2026-10-06: the off-host backup
# target's own encryption-at-rest is the operator's responsibility
# (rclone-crypt / restic / NAS-level). v2.x adds an opt-in
# /adminlm/backup-encryption/KEY path.
INFISICAL_STACK_DIR="${INFISICAL_STACK_DIR:-$ADMINLM_DIR/infisical-stack}"
INFISICAL_ENV_FILE="${INFISICAL_ENV_FILE:-$INFISICAL_STACK_DIR/.env}"
# Error logs live OUTSIDE the archive. pg_dump failures can echo the
# connection URI (and therefore the DB password) into stderr — that must not
# travel inside a tarball the operator copies to an off-host target.
INFISICAL_ERRLOG="$BACKUP_DIR/adminlm-backup-errors/${TS}-infisical.err"
mkdir -p "$(dirname "$INFISICAL_ERRLOG")"
INFISICAL_DB_SIZE=0
INFISICAL_ENV_PRESENT=0
INFISICAL_SECRET_COUNT=0
INFISICAL_REDIS_SIZE=0

mkdir -p "$WORK/infisical"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'infisical-postgres'; then
    log "Dumping Infisical Postgres (customer IT secret store)"

    PG_USER="$(envval POSTGRES_USER "$INFISICAL_ENV_FILE")"
    PG_DB="$(envval POSTGRES_DB "$INFISICAL_ENV_FILE")"
    # Fall back to the container's own view of the environment.
    [ -n "$PG_USER" ] || PG_USER="$(docker exec infisical-postgres printenv POSTGRES_USER 2>/dev/null | tr -d '\r\n')"
    [ -n "$PG_DB" ]   || PG_DB="$(docker exec infisical-postgres printenv POSTGRES_DB 2>/dev/null | tr -d '\r\n')"

    if [ -z "$PG_USER" ] || [ -z "$PG_DB" ]; then
        log "  WARN: could not determine POSTGRES_USER/POSTGRES_DB — skipping Infisical dump"
    else
        # --clean --if-exists makes the dump re-runnable into an existing DB.
        if docker exec infisical-postgres \
             pg_dump -U "$PG_USER" -d "$PG_DB" --clean --if-exists --no-owner --no-privileges \
             2>>"$INFISICAL_ERRLOG" | gzip -9 > "$WORK/infisical/infisical-db.sql.gz"; then
            INFISICAL_DB_SIZE=$(stat -c%s "$WORK/infisical/infisical-db.sql.gz" 2>/dev/null || echo 0)
            log "  Infisical Postgres dump: $INFISICAL_DB_SIZE bytes"
            # Integrity + header check. A truncated archive that "succeeded"
            # is the worst failure mode — catch it here.
            if python3 -c '
import gzip, sys
try:
    with gzip.open(sys.argv[1], "rt", errors="replace") as fh:
        head = fh.read(4096)
except Exception:
    sys.exit(1)
sys.exit(0 if "PostgreSQL database dump" in head else 2)
' "$WORK/infisical/infisical-db.sql.gz"; then
                log "  dump verified (gzip intact, schema header present)"
            else
                log "  WARN: dump failed integrity/header check — the archive may be truncated"
            fi
        else
            log "  WARN: pg_dump failed (see $INFISICAL_ERRLOG); Infisical NOT captured"
            rm -f "$WORK/infisical/infisical-db.sql.gz"
        fi
    fi

    # Secret count for the manifest. v0.166.x stores secrets in
    # public.secrets_v2; older releases use public.secrets. Probe both.
    if [ -n "$PG_USER" ] && [ -n "$PG_DB" ]; then
        for T in public.secrets_v2 public.secrets; do
            C=$(docker exec infisical-postgres psql -U "$PG_USER" -d "$PG_DB" -tAc \
                  "select count(*) from $T;" 2>/dev/null | tr -d '[:space:]' || true)
            if [ -n "$C" ] && [ "$C" != "0" ]; then
                INFISICAL_SECRET_COUNT="$C"
                break
            fi
        done
    fi
    log "  Infisical secret count: $INFISICAL_SECRET_COUNT"

    # The count above came from the LIVE database. Confirm the dump actually
    # carries those rows — a dump that is missing the secrets table would
    # still produce a valid-looking archive. pg_dump emits COPY blocks, so
    # count the data lines inside the secrets COPY block.
    if [ "$INFISICAL_DB_SIZE" -gt 0 ]; then
        DUMP_COUNT=$(zcat "$WORK/infisical/infisical-db.sql.gz" 2>/dev/null | awk '
            /^COPY public\.secrets_v2 / { inblk=1; next }
            /^COPY / { inblk=0 }
            inblk && /^\\\.$/ { inblk=0; next }
            inblk { c++ }
            END { print c+0 }
        ' || echo 0)
        if [ "$DUMP_COUNT" = "$INFISICAL_SECRET_COUNT" ]; then
            log "  dump row count matches the live database ($DUMP_COUNT)"
        else
            log "  WARN: dump contains $DUMP_COUNT secret row(s) but the live database has $INFISICAL_SECRET_COUNT — the archive may not restore every secret"
        fi
    fi

    # Redis holds cache + BullMQ queues. Captured for completeness; the
    # restore script does NOT replay it by default (a stale cache pointing at
    # deleted identities is worse than the empty cache Infisical rebuilds).
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'infisical-redis'; then
        REDIS_PW="$(envval REDIS_PASSWORD "$INFISICAL_ENV_FILE")"
        if docker exec -e REDISCLI_AUTH="$REDIS_PW" infisical-redis redis-cli SAVE >/dev/null 2>&1 \
           && docker cp infisical-redis:/data/dump.rdb "$WORK/infisical/redis-dump.rdb" 2>>"$INFISICAL_ERRLOG"; then
            INFISICAL_REDIS_SIZE=$(stat -c%s "$WORK/infisical/redis-dump.rdb" 2>/dev/null || echo 0)
            log "  Infisical Redis RDB: $INFISICAL_REDIS_SIZE bytes (captured, not auto-restored)"
        else
            log "  WARN: Redis RDB capture failed — non-fatal (Postgres is the source of truth)"
        fi
    fi

    # Encryption material. WITHOUT this the Postgres dump is unreadable.
    if [ -r "$INFISICAL_ENV_FILE" ]; then
        cp "$INFISICAL_ENV_FILE" "$WORK/infisical/infisical-stack.env"
        chmod 600 "$WORK/infisical/infisical-stack.env"
        INFISICAL_ENV_PRESENT=1
        log "  captured Infisical encryption material (ENCRYPTION_KEY + DB/Redis creds)"
    elif [ "$INFISICAL_DB_SIZE" -gt 0 ]; then
        # The dump exists but cannot be decrypted. Failing loudly is the whole
        # point: a "successful" archive whose secrets are unreadable is worse
        # than a failed backup, because the operator believes they have a
        # safety net they do not have.
        fail "Infisical dump captured but $INFISICAL_ENV_FILE is missing — the archive could NOT be decrypted on restore. Fix the env file and re-run."
    else
        log "  WARN: $INFISICAL_ENV_FILE not readable and no dump taken — nothing to capture"
    fi
else
    log "WARN: infisical-postgres container not running; skipping Infisical"
fi

# ===== 8. Manifest =====
EXPORTED="$EXPORTED" \
PROV_COUNT="$PROV_COUNT" \
HERMES_SIZE="$HERMES_SIZE" \
INVENTORY_SIZE="$INVENTORY_SIZE" \
KB_SIZE="$KB_SIZE" \
INFISICAL_DB_SIZE="$INFISICAL_DB_SIZE" \
INFISICAL_REDIS_SIZE="$INFISICAL_REDIS_SIZE" \
INFISICAL_ENV_PRESENT="$INFISICAL_ENV_PRESENT" \
INFISICAL_SECRET_COUNT="$INFISICAL_SECRET_COUNT" \
ADMINLM_DIR="$ADMINLM_DIR" \
GRAFANA_URL="$GRAFANA_URL" \
python3 - <<'PY' > "$WORK/MANIFEST.json"
import datetime, json, os
print(json.dumps({
    "schema_version": 3,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "adminlm_dir": os.environ.get("ADMINLM_DIR", "unknown"),
    "grafana_url": os.environ.get("GRAFANA_URL", "unknown"),
    "dashboards_api_exported": int(os.environ.get("EXPORTED", "0")),
    "dashboards_provisioned_files": int(os.environ.get("PROV_COUNT", "0")),
    "hermes_zip_size_bytes": int(os.environ.get("HERMES_SIZE", "0")),
    "inventory_db_size_bytes": int(os.environ.get("INVENTORY_SIZE", "0")),
    "kb_db_size_bytes": int(os.environ.get("KB_SIZE", "0")),
    "infisical_db_size_bytes": int(os.environ.get("INFISICAL_DB_SIZE", "0")),
    "infisical_redis_size_bytes": int(os.environ.get("INFISICAL_REDIS_SIZE", "0")),
    "infisical_env_present": int(os.environ.get("INFISICAL_ENV_PRESENT", "0")),
    "infisical_secret_count": int(os.environ.get("INFISICAL_SECRET_COUNT", "0")),
}, indent=2))
PY

# ===== 9. Tar =====
tar -czf "$ARCHIVE" -C "$WORK" .
log "Wrote $ARCHIVE ($(du -h "$ARCHIVE" | awk '{print $1}'))"

# ===== 10. Rotate =====
ROTATED=$(ls -1t "$BACKUP_DIR"/adminlm-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | wc -l)
ls -1t "$BACKUP_DIR"/adminlm-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f --
log "Retention: kept last $KEEP backups (rotated $ROTATED old)"
