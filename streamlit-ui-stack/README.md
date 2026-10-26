# streamlit-ui-stack

AdminLM v1.0 customer Streamlit UI shell (BACKLOG #64, Card 3).

## What this is

The customer-facing web UI for the v1.0 private deployment. One container
on the shared `monitoring` Docker network:

| Container       | Purpose                                                                                  | Exposed? |
|-----------------|------------------------------------------------------------------------------------------|----------|
| `streamlit-ui`  | Streamlit app (Home / Settings / Health). Talks to backends over HTTP. NO docker socket. | Yes (8501) |

The other backends it talks to (`adminlm-ansible-runner`, `kb-mcp`,
`inventory-mcp`, `loki`, `grafana`) live in their own stacks. They are
reachable on the `monitoring` network by container name. The Hermes Web
Dashboard runs on the host (s6-overlay) and is reached via
`host.docker.internal` (the compose file adds the special
`host.docker.internal:host-gateway` mapping so this works without operator
config).

## Layout

```
streamlit-ui-stack/
├── docker-compose.yml          # streamlit-ui (port 8501, on monitoring)
├── Dockerfile                  # python:3.12-slim + streamlit + bcrypt + httpx
├── requirements.txt            # streamlit>=1.39, bcrypt, httpx, python-multipart
├── README.md                   # this file
├── data/                       # bind-mounted for streamlit-ui.db + loki_logger/*.log
├── .streamlit/
│   └── config.toml             # theme (AdminLM-blue) + server settings
└── streamlit-app/
    ├── Home.py                 # entry point: auth gate + landing dashboard
    ├── auth.py                 # bcrypt verify + session_state + logout
    ├── db.py                   # SQLite connect + idempotent schema migration
    ├── loki_logger.py          # symlink to ../adminlm-ansible-stack/loki_logger.py
    ├── settings.py             # load URLs + customer name from env
    └── pages/
        ├── 1_Settings.py       # read-only config + health subsection
        ├── 2_Secrets.py        # BACKLOG #94 Phase 3 — read-only Infisical vault viewer
        └── 3_Run_Playbook.py   # Card 4 — HMAC-signed ansible run
```

## Bring it up

```bash
cd /home/openclaw/AdminLM
docker compose -f streamlit-ui-stack/docker-compose.yml up -d --build
```

The container starts, runs the schema migrations on first request, and
serves on port 8501.

## Auth (v1.0 single admin)

Set via env vars on the container (compose defaults shown):

| Env var                         | Default       | Purpose                              |
|---------------------------------|---------------|--------------------------------------|
| `STREAMLIT_ADMIN_USERNAME`      | `admin`       | login username                       |
| `STREAMLIT_ADMIN_PASSWORD_HASH` | (unset)       | bcrypt hash — production path        |
| `STREAMLIT_ADMIN_PASSWORD`      | `admin`       | plain text — v1.0 fallback ONLY      |

When only `_PASSWORD` is set (no `_HASH`), a warning is emitted at startup.
This is intentional for v1.0 private deployment — operators can rotate
per-customer passwords via a simple env-var swap. For multi-tenant v2,
swap to bcrypt hashes (the v2 user model reads `password_hash` from the
SQLite `users` table).

Generate a bcrypt hash:
```bash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'YOUR_PASSWORD', bcrypt.gensalt()).decode())"
```

## Test it

```bash
# 1. Health check
curl -sI http://localhost:8501/_stcore/health | head -1
# → HTTP/1.1 200 OK

# 2. Landing page HTML
curl -s http://localhost:8501/ | head -20

# 3. SQLite tables after first login
sqlite3 streamlit-ui-stack/data/streamlit-ui.db ".tables"
# → chat_sessions playbook_run_events playbook_runs ui_settings users

# 4. Admin user row
sqlite3 streamlit-ui-stack/data/streamlit-ui.db "SELECT * FROM users"
# → 1|admin||2026-08-18 13:50:00

# 5. Loki query for streamlit events
curl -s -G http://localhost:3100/loki/api/v1/query \
    --data-urlencode 'query={job="adminlm-streamlit"}' \
    | jq '.data.result | length'
# → ≥1 after login + home view
```

## Loki plumbing

- `loki_logger.py` writes NDJSON to `/data/streamlit-ui/logs/<stream>.log`
  inside the container (env var `LOKI_LOG_DIR`).
- The host bind-mount maps `${HOME}/.hermes/logs/adminlm-streamlit` →
  `/data/streamlit-ui/logs`.
- The host's existing `alloy` container tails `${HOME}/.hermes/logs` and
  ships anything under `adminlm-streamlit/*.log` to Loki with
  `job="adminlm-streamlit"`, `source="adminlm_host"`.
- See `config/alloy.yml` for the matching `local.file_match` /
  `loki.source.file` block (added by Card 3, additive — Card 2's
  `adminlm-ansible` block is untouched).

## Security notes

- `streamlit-ui` does **not** mount `/var/run/docker.sock`. The only
  container in the AdminLM stack that does is `adminlm-ansible-runner`
  (Card 2). Streamlit → runner → docker-exec is the privilege-bounded
  path for playbook execution (Card 4).
- Plain-text passwords are never written to disk. The `users.password_hash`
  column is reserved for v2 multi-user; v1.0 admin credentials come from
  the env vars above and stay out of the DB.
- Bind-mounts from `./streamlit-app` and `./.streamlit` are read-only
  inside the container (`:ro`), so a misbehaving page can't corrupt the
  operator's working copy on the host.

## Card scope

- ✅ Card 3: shell + auth + SQLite + Loki + Home + Settings + Health.
- ⏭️ Card 4: Run Playbook page (HMAC-signed `POST /run` to the runner).
- ⏭️ Card 5: Agent Chat page (Hermes `/v1/responses` chat).
- ⏭️ Card 6: KB Search + Inventory Search pages.
- ⏭️ Card 7: `docker-compose.v1-private.yml` overlay + bootstrap integration.

### BACKLOG #94 Phase 3 — Secrets page

- Secrets page (`/Secrets` on :8501) — operator-facing read-only view of the
  Infisical vault (BACKLOG #94 Phase 3). The page lists secrets under
  `/adminlm/it-systems/` and supports click-to-reveal with Loki audit logging.
  The Infisical UI itself stays bound to `127.0.0.1:8090`; the operator token is
  provisioned by `bootstrap.sh deploy_infisical_stack()` and lives in
  `~/.hermes/secrets/infisical-operator.env`.

## Card status

- Card 3 (this card): shell + auth + SQLite + Loki plumbing + Home/Settings/Health pages + E2E verify on .220.
- Card 4–6: pages built on this shell.
- Card 7: bootstrap wires `deploy_streamlit_ui_stack()` into the v1.0 private customer overlay compose.

---

## Card 7 integration (BACKLOG #64, Card 7)

As of Card 7 this stack is **never deployed standalone** on a customer
host. The customer-facing install path is the overlay compose at the
repo root:

```bash
cd ~/AdminLM
docker compose -f docker-compose.yml -f docker-compose.v1-private.yml up -d
```

The overlay `include:`s `streamlit-ui-stack/docker-compose.yml` (this
file) and `adminlm-ansible-stack/docker-compose.yml`. Bind mounts, env
vars, healthchecks, and image tags defined here flow through unchanged.
The overlay only adds a `adminlm-v1-private=true` label to the three
v1.0 services.

`bootstrap.sh` gains two new functions called from `main()`:

- `deploy_adminlm_ansible_stack()` — gated on
  `AdminLM_DEPLOY_V1_PRIVATE=true` (or `--v1-private`). Brings up the
  Card 2 stack first (the runner).
- `deploy_streamlit_ui_stack()` — same gate, scopes to `streamlit-ui`.
  Order matters: the runner must be up before streamlit-ui posts
  HMAC-signed requests to it.

Both functions are idempotent (a no-op on a healthy install) and
hard-gated. `print_v1_private_post_install()` prints the Streamlit
URL, default credentials reminder, customer flow TL;DR, and Loki
query labels at the end of the bootstrap run.

See `docs/streamlit-ui.md` for the user-facing guide.
