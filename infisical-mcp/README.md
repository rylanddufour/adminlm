# infisical-mcp (BACKLOG #94 Phase 5)

The read-only bridge between the IT_ADMIN agent and Infisical. Exposes three
tools, all GET-only, all authenticated with the **agent's read-only token**
(not the operator's full-access token).

## What it is

A FastMCP server (Python, ~485 lines) that fronts the Infisical REST API
and exposes a small, audited tool surface to the agent. The container is
bound to `127.0.0.1:8003` — loopback only, never customer-reachable.

## Tools

### `get_secret(secret_path: str, secret_key: str) → dict`

Fetch one secret's value at call time. This is the **only** tool that
returns a value. The agent calls it, uses the value to authenticate against
a customer system (e.g. SSH into a Linux box), then discards it. Never
cached, never persisted.

| arg | type | example |
|---|---|---|
| `secret_path` | `str` | `"/adminlm/it-systems/"` |
| `secret_key` | `str` | `"LINUX_SSH_KEY"` |

Returns `{secretKey, secretPath, secretValue, secretComment, updatedAt}` on
success. Returns structured `{error: "secret_not_found", suggested_action: ...}`
when the secret doesn't exist (BACKLOG #94 AC #7).

### `list_paths(path_prefix: str = "/adminlm/it-systems/") → list[dict]`

Enumerate secret keys under a path prefix. **Never returns values.** Use
this for discovery: "what AD accounts are configured?" before deciding
which to fetch via `get_secret`.

Each entry is `{secretKey, secretPath, updatedAt}`. The defensive strip
ensures `secretValue` and `secretComment` are never included — even if
Infisical sends them.

### `list_systems(path_prefix: str = "/adminlm/it-systems/") → list[str]`

DEPRECATED in v1.0 (operator decision 2026-10-27). v1.0 keeps secrets
FLAT under `/adminlm/it-systems/` — there are no subfolders to enumerate,
so this tool returns `[]` for any v1.0 vault. Use `list_paths()` for
discovery instead. Kept in the tool surface so the agent's tool list
stays stable.

## Audit contract

Every tool call emits one NDJSON line to `~/.hermes/logs/adminlm-infisical-mcp/`
(via `loki_logger.log_event`). Stream `infisical_mcp`. Loki labels
`{job="adminlm-infisical-mcp", source="adminlm_host"}`.

The event payload is **always**:

```json
{
  "tool": "get_secret" | "list_paths" | "list_systems",
  "path": "<the path argument>",
  "secret_key": "<the key argument, or null>",
  "success": true | false,
  "user_id": "agent-it_admin",
  "error": "<optional, only on failure>"
}
```

**Never** includes the secret value. This is the BACKLOG #77 + #94 rule.
The `tests/test_infisical_mcp.py` `test_audit_invariant_no_secret_value_field`
test enforces this — if someone adds a `secret_value` field to the log
event, the test fails.

## Endpoints used

| tool | Infisical endpoint |
|---|---|
| `get_secret` | `GET /api/v3/secrets/raw/{key}?workspaceId=...&environment=...&secretPath=...` |
| `list_paths` | `GET /api/v4/secrets?projectId=...&environment=...&secretPath=...&recursive=true` |
| `list_systems` | `GET /api/v2/folders?projectId=...&environment=...&path=...&recursive=true` |

**Note on `list_paths`:** uses `/api/v4/secrets` (not the deprecated
`/api/v3/secrets` LIST, which returns empty in v0.166.2 even when secrets
exist). Same fix as `streamlit-ui-stack/streamlit-app/pages/2_Secrets.py`.
Keep these two in lockstep when bumping Infisical versions.

## Authentication

- **Header:** `Authorization: Bearer ${INFISICAL_AGENT_TOKEN}`
- **Source:** `~/.hermes/secrets/infisical-agent.env` (chmod 600,
  bind-mounted into the container)
- **Identity:** the agent-default machine identity created by
  `bootstrap.sh deploy_infisical_stack()` step 6c. Has `viewer` role
  on the production project — read-only on operator-pre-approved paths.
- **Blast radius if compromised:** read-only. No write tools exist.

## Deployment

Container: `infisical-mcp`. Image: `adminlm_infisical-mcp`. Bound
`127.0.0.1:8003:8003` (loopback only). Networks: shared `monitoring`
and `infisical` so it can reach `infisical:8090` by container name.

`/health` endpoint returns 200 — used by docker-compose healthcheck and
`bootstrap.sh verify_installation`.

## Tests

```bash
cd adminlm/infisical-mcp
pip install pytest
python3 -m pytest tests/test_infisical_mcp.py -v
```

12 tests cover: tool success paths, transport / 404 / config-missing
errors, audit invariant (no secret value ever in logs), endpoint shape
(`/api/v4/secrets` not `/api/v3/secrets`), list_systems flat-layout
deprecation.

## What is NOT in v1.0

- **No write tools.** No `create_secret`, `update_secret`, `delete_secret`,
  `rotate_secret`. Even if the agent token were compromised, the blast
  radius is read-only. Operator writes go through the Streamlit Secrets
  page (Phase 6 / BACKLOG #95).
- **No folder navigation UI.** v1.0 keeps secrets FLAT; folders exist
  but aren't used for customer-IT-secret grouping.
- **No tags-based filtering.** Tag support is in Infisical's data model
  but not surfaced in the MCP tool surface for v1.0.

## Related

- BACKLOG #94 (Infisical deployment + Streamlit Secrets page)
- BACKLOG #95 (Phase 6 — operator CRUD UI in Streamlit)
- BACKLOG #96 (E2E on `.220` — verified Phase 5 against a live stack)
- BACKLOG #77 (audit pattern — `loki_logger.py`)
