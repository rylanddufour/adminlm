# skills/adminlm-backup.md — AdminLM stack backup

## Purpose

Documents the daily AdminLM stack backup workflow so the IT_ADMIN agent can run, verify, and troubleshoot it. Captures everything needed to restore the AdminLM stack to a working state without depending on git or upstream services — **the customer can never push changes to the adminlm repo**, so the backup must be self-contained.

## When to use

- When the user asks "are the dashboards being backed up?" / "is the backup running?" / "show me the last backup"
- When a dashboard was modified and the user wants to verify it's in the latest archive
- When the cron job reports a failure and the agent needs to diagnose
- When the user wants to restore from a backup (read-only first — restoration still needs explicit human approval per the non-destructive policy)
- When the user asks "is hermes state / inventory / KB / grafana config backed up?"

## What the script captures

`~/.hermes/scripts/adminlm-backup.sh` (installed by `bootstrap.sh install_backup_scripts`, present on every AdminLM install). One tarball: `~/backups/adminlm-backup-YYYYMMDD-HHMMSS.tar.gz`. Contents:

| Section | Source | Purpose on restore |
|---|---|---|
| `dashboards/*.json` | Grafana API export (one per dashboard UID) | Recreates the dashboard as Grafana sees it; catches UI edits |
| `dashboards-provisioned/*.json` | Filesystem copy of `~/adminlm/config/grafana/provisioning/dashboards/*.json` | Catches provisioning source-of-truth (uid, datasource refs, provisioning metadata) — important when a customer edits a default dashboard |
| `hermes/backup.zip` | `hermes backup --output ...` (built-in CLI) | Single zip of `~/.hermes` — profiles, skills, sessions, kanban, cron jobs, .env, secrets |
| `db/inventory.db` | `docker exec inventory-mcp sqlite3 .backup` + `docker cp` | The inventory database (all discovered devices) |
| `db/kb.db` | same pattern against `kb-mcp` | The KB content database |
| `config/alloy.yml`, `blackbox.yml`, `loki.yml`, `prometheus.yml`, `promtail.yml` | Filesystem copy from `~/adminlm/config/` | The actual on-host config (may have local edits not in git) |
| `config/datasources.yml`, `config/dashboards.yml` | Same | Grafana provisioning metadata |
| `infisical/infisical-db.sql.gz` | `docker exec infisical-postgres pg_dump` → gzip | **Every customer IT secret**, exactly. This is the customer IT secret store |
| `infisical/infisical-stack.env` | Filesystem copy of `~/adminlm/infisical-stack/.env` | `ENCRYPTION_KEY` + Postgres/Redis creds. **Without it the dump is unreadable** — the dump stores ciphertext |
| `infisical/redis-dump.rdb` | `redis-cli SAVE` + `docker cp` | Infisical cache + job queues. Captured for completeness; **not** replayed on restore by default |
| `MANIFEST.json` | Generated at the end | Counts + sizes for verification |

**Excluded intentionally:**
- Loki chunks + Prometheus TSDB — backed up by their own retention / compactor mechanisms (Loki has its own retention; Prometheus has a snapshot API for metrics)
- `hermes-agent` code — installable from PyPI; not customer state
- Docker volumes for grafana-data / loki / prometheus — service-level, not file-level
- `/var/log/hermes-bootstrap-credentials.log` — same VM as the script; if you lose that you have bigger problems. Add explicitly if you want it backed up.

## Infisical: the customer IT secret store

Infisical holds the **customer's** IT secrets — Windows admin passwords, ssh
keys, device credentials. AdminLM's own service credentials live elsewhere
and are not affected.

Three pieces have to travel together, or the restore is worthless:

| Piece | What it is | Why it matters |
|---|---|---|
| `infisical-db.sql.gz` | Logical Postgres dump (`pg_dump`, Postgres 14 compatible) | The secret rows themselves |
| `infisical-stack.env` | `ENCRYPTION_KEY` + `POSTGRES_*` + `REDIS_PASSWORD` | Infisical encrypts every secret value at rest. The dump holds **ciphertext**. Without this key the restore would "succeed" and hand back garbage |
| `redis-dump.rdb` | Redis cache + job queues | Convenience only. Not replayed by default |

**The backup script fails loudly if the dump succeeds but the env file is
missing.** That is deliberate: an archive that reports success but cannot be
decrypted is worse than a failed backup, because the operator believes they
have a safety net they do not have.

### Encryption at rest

v1.0 ships the Infisical section **plain** — the tarball contains the
`ENCRYPTION_KEY` in clear text. Protection in v1.0 comes from the off-host
backup target's own encryption (rclone-crypt, restic, a NAS with encrypted
volumes), which is the operator's responsibility.

This is consistent with the rest of the archive: `hermes/backup.zip` already
contains the stack's API keys in plain text.

v2.x adds an opt-in second layer: when the operator adds
`/adminlm/backup-encryption/KEY` to the Secrets page, the next run detects it
and encrypts the Infisical dump section with the configured cipher. Absence of
the key means unencrypted — the v1.0 default.

**If the host itself is compromised, the backup is too.** Treat the tarball as
a secret: it is the complete customer credential set.

## Restoring Infisical

`~/.hermes/scripts/adminlm-restore-infisical.sh <backup-tarball>` restores the
customer IT secret store onto an install (typically a fresh one).

Destructive: it replaces the live Infisical database. Requires `--yes`.

The order is deliberate:

1. postgres + redis start, **app held back**
2. the dump is replayed — so the app never migrates an empty DB
3. the app starts and finds a fully-populated schema
4. the secret count is compared against the manifest

The script installs the backup's `infisical-stack.env` first, so a fresh
Postgres volume initialises with the same credentials the dump was taken
under. An existing `.env` is preserved as `.env.pre-restore.bak`.

Then verify end-to-end through the Streamlit Secrets page — a matching count
is necessary, not sufficient.

## Exit codes

- `0` — success (every section that was attempted completed; warnings logged but not fatal)
- `1` — fatal: token file missing, token is a placeholder, the API call failed catastrophically, or the Infisical dump was captured without its `ENCRYPTION_KEY` (an archive that cannot be decrypted is not a backup). Per-section failures (e.g., hermes backup failed, kb-mcp container not running) log a WARN line and continue — they do not fail the whole backup, since the customer can still recover from the parts that worked.

## Environment overrides (all optional)

- `GRAFANA_URL` — default `http://localhost:3000`
- `GRAFANA_TOKEN_FILE` — default `~/.hermes/secrets/grafana-mcp.env`
- `ADMINLM_DIR` — default `~/adminlm` (root of the AdminLM config tree)
- `BACKUP_DIR` — default `~/backups`
- `KEEP` — default `14` daily backups retained
- `INFISICAL_STACK_DIR` — default `~/adminlm/infisical-stack`
- `INFISICAL_ENV_FILE` — default `$INFISICAL_STACK_DIR/.env`

## How the agent runs it (the cron flow)

The Hermes cron job `AdminLM Backup` (registered by `bootstrap.sh install_dashboard_backup_hermes_cron`) fires daily at 01:00. Its prompt is a thin wrapper:

> Run `~/.hermes/scripts/adminlm-backup.sh` and report any errors.

The agent:
1. Invokes the script via the terminal tool.
2. Inspects the exit code and the last 10-20 lines of stdout/stderr.
3. If exit code 0, returns a 1-line success summary (archive path + size + per-section counts from the manifest).
4. If non-zero, returns the error message and the last failing step.

The agent does NOT rewrite the script or implement backup logic in-line. The script is the source of truth; the agent is a thin wrapper that provides logging + delivery.

## The gateway is what ticks the cron

Per `hermes_agent/cron/__init__.py`: *"Cron jobs are executed automatically by the gateway daemon"*. This means the `AdminLM Backup` entry in `~/.hermes/cron/jobs.json` is **inert until the `hermes-gateway` daemon is running** — registration alone is not enough.

`bootstrap.sh` installs the gateway as a **system-level systemd service** (`sudo hermes gateway install --system --run-as-user <user>`) so it:
- Lives in `/etc/systemd/system/hermes-gateway.service`
- Starts automatically at `multi-user.target` (server boot, independent of any user login)
- Is supervised by systemd (Restart=always; auto-recovers from crashes)

This is the right scope for a headless server. The per-user variant (`hermes gateway install`, no `--system`) only starts on user login and would not survive a reboot of a headless Proxmox VM/CT.

To verify on a live install: `sudo systemctl status hermes-gateway.service` — should show `Active: active (running)`.

## Reading a backup

```bash
# List recent archives
ls -lht ~/backups/adminlm-backup-*.tar.gz | head -5

# Extract one
mkdir /tmp/adminlm-restore && tar -xzf ~/backups/adminlm-backup-<TS>.tar.gz -C /tmp/adminlm-restore
ls /tmp/adminlm-restore/   # dashboards/, dashboards-provisioned/, config/, db/, hermes/, MANIFEST.json
cat /tmp/adminlm-restore/MANIFEST.json
```

The manifest is the quickest way to verify a backup:
```json
{
  "schema_version": 3,
  "generated_at": "2026-07-07T...",
  "adminlm_dir": "/home/ansible/adminlm",
  "grafana_url": "http://localhost:3000",
  "dashboards_api_exported": 12,
  "dashboards_provisioned_files": 12,
  "hermes_zip_size_bytes": 4321,
  "inventory_db_size_bytes": 28672,
  "kb_db_size_bytes": 16384,
  "infisical_db_size_bytes": 183947,
  "infisical_redis_size_bytes": 969733,
  "infisical_env_present": 1,
  "infisical_secret_count": 2
}
```

## Troubleshooting checklist

| Symptom | Likely cause |
|---|---|
| `ERROR: token file not readable: ~/.hermes/secrets/grafana-mcp.env` | Token file missing. Was `create_grafana_mcp_service_account()` ever run? Check `ls -la ~/.hermes/secrets/`. |
| `ERROR: GRAFANA_SERVICE_ACCOUNT_TOKEN missing or placeholder` | Token file exists but is empty or contains a placeholder. Re-run `create_grafana_mcp_service_account()`. |
| `WARN: failed to fetch <uid>, skipping` | One dashboard's JSON is malformed or the API call was rate-limited. The export continues with the other dashboards. Investigate the specific UID separately. |
| `WARN: hermes not on PATH; skipping hermes backup` | `hermes` CLI not installed or not in the cron user's PATH. Install hermes-agent and re-run. |
| `WARN: inventory-mcp container not running; skipping inventory DB` | The inventory stack is not deployed (or down). The rest of the backup still completes. If the inventory DB existed previously, the last good backup is your fallback. |
| `WARN: kb-mcp container not running; skipping KB DB` | Same pattern for the KB stack. |
| `WARN: missing /home/.../adminlm/config/<file>.yml` | The AdminLM repo is not at the expected path. Check `ADMINLM_DIR` env override. |
| No `adminlm-backup-*.tar.gz` files in `~/backups/` | Cron never ran. Check the Hermes cron state: `hermes cron list`, look for `AdminLM Backup`, check `last_status`. |
| Cron registered in jobs.json with `state: scheduled` and `enabled: true` but never fires | The **hermes-gateway daemon is not running** — it is the daemon that ticks scheduled jobs. Check `sudo systemctl status hermes-gateway.service`; on a fresh install it should be `active (running)`. If `inactive` or `failed`, start it with `sudo systemctl start hermes-gateway.service` and inspect `journalctl -u hermes-gateway.service -n 50` for the cause. |
| `last_status: error` on the cron | Read `last_error` from `~/.hermes/cron/jobs.json` or `hermes cron status <id>`. |
| Archive size much smaller than usual | A dashboard was deleted, a DB was wiped, or the hermes state shrank. Compare against the manifest from a prior archive. |
| `manifest.dashboards_api_exported` is 0 | Grafana is not running or the token is wrong. Other sections may still be in the tarball. |
| `manifest.inventory_db_size_bytes: 0` and inventory was previously populated | The `docker exec` or `docker cp` step failed. Check the script's stderr for the specific WARN line. The DB is still in the container's volume; you can `docker cp` it manually. |
| `ERROR: Infisical dump captured but .../infisical-stack/.env is missing` | The backup failed **deliberately** — a dump without `ENCRYPTION_KEY` is unreadable. Restore the env file on the host (it is gitignored, so it exists only on the machine that created the vault) and re-run. Check `ls -la ~/adminlm/infisical-stack/.env`. |
| `WARN: pg_dump failed ... Infisical NOT captured` | Postgres rejected the dump. Usually POSTGRES_USER/POSTGRES_DB could not be resolved (check the env file) or the container was mid-migration. The rest of the backup still completes. |
| `WARN: dump failed integrity/header check — the archive may be truncated` | The gzip or the pg_dump header did not verify. Treat that archive's Infisical section as unusable and re-run the backup. |
| `WARN: infisical-postgres container not running; skipping Infisical` | The Infisical stack is down. That archive contains **no customer secrets** — do not treat it as a safety net until Infisical is up and a fresh backup has run. |
| `manifest.infisical_secret_count: 0` but the vault has secrets | The count probe found neither `public.secrets_v2` (v0.166.x) nor `public.secrets` (older). Inspect the archive's Infisical section directly — the dump itself may still be fine. |

## What this backup does NOT cover

- **Same-VM only.** The script writes to `~/backups/` on the same host. If the VM dies completely, the backup dies with it. Shipping an off-host (rclone / restic / NAS) target is a known follow-up; it is tracked separately and is not in scope of this script.
- **Encryption at rest.** The hermes zip contains API keys in plain text, and the Infisical section contains the `ENCRYPTION_KEY` in clear text. The tarball is readable by anyone with file access on the host — and with it, every customer IT secret. If the host itself is compromised, the backup is too. v1.0 relies on the off-host target's own encryption (rclone-crypt / restic / encrypted NAS). Treat the tarball as a secret. v2.x adds an opt-in second layer via `/adminlm/backup-encryption/KEY`.
- **Loki logs / Prometheus metrics.** Per `excluded intentionally` above — those have their own retention mechanisms.
- **The hermes-agent code itself.** Reinstall from PyPI for the same version. Pin via the `hermes-agent==X.Y.Z` in the bootstrap requirements.

## Non-destructive policy

- Running the backup script is non-destructive (it only writes to `~/backups/` and rotates old archives).
- **Restoring** any piece of the backup IS destructive (it overwrites the live state — dashboards, hermes config, inventory DB, KB DB, grafana configs, and the Infisical customer secret store) and requires explicit human approval per the global non-destructive policy in `SOUL.md`. `adminlm-restore-infisical.sh` enforces this with a `--yes` flag.

## Related

- Script: `scripts/adminlm-backup.sh` (the workhorse)
- Restore script: `scripts/adminlm-restore-infisical.sh` — restores the customer IT secret store from an archive (destructive, `--yes` required)
- Old script: `scripts/backup-dashboards.sh` — **removed** when scope grew to include hermes / inventory / KB / configs. If you see this file referenced anywhere, it's stale; the installer's cron job was renamed to `AdminLM Backup` and the old `AdminLM Dashboard Backup` cron should be replaced.
- Hermes backup CLI: https://hermes-agent.nousresearch.com/docs/reference/cli-commands (covers what `hermes backup` itself does)
- Service account: `create_grafana_mcp_service_account()` in `bootstrap.sh`
- Cron registration: `install_dashboard_backup_hermes_cron()` in `bootstrap.sh` (replaces the legacy `/etc/cron.d/adminlm-dashboard-backup` system cron)
- Gateway (cron scheduler daemon): `install_hermes_gateway_service()` in `bootstrap.sh` — installs the system-level systemd service that ticks the cron
- Legacy system cron: `/etc/cron.d/adminlm-dashboard-backup` — removed by the new install on re-bootstrap
- The backup script is the source of truth for what lands in the archive; this skill documents it
