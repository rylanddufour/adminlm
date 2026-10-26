# skills/adminlm-secrets.md — IT system secret retrieval via infisical-mcp

## Purpose

How the IT_ADMIN agent retrieves customer IT credentials from the
AdminLM vault at call time. The vault stores per-system passwords, API
keys, and service creds (Active Directory admin, SSH jump host,
vSphere, SaaS provider keys, etc.); the agent fetches the value when
it actually needs to use it, never holds it persistently, and discards
it immediately after the calling tool returns.

**When to use:** any time the agent is about to authenticate against a
customer IT system and needs the credential for that system. Typical
call sites: AD account operations, SSH session setup, vSphere API
calls, vendor portal logins, Ansible playbook runs that need a
machine-local account.

**Not for:** operator-driven secret management (creation, update,
deletion, rotation, token management). The operator uses the Streamlit
Secrets page directly for those flows — the agent's MCP is read-only by
design.

## Path taxonomy

The vault is organised by IT system. Every secret lives under a folder
named after the system it authenticates against:

```
/adminlm/it-systems/<system>/<secret_key>
```

Examples:

- `/adminlm/it-systems/ad/<KEY>` — Active Directory account passwords
- `/adminlm/it-systems/ssh/<KEY>` — SSH jump host credentials
- `/adminlm/it-systems/vmware/<KEY>` — vCenter / ESXi accounts
- `/adminlm/it-systems/saas-api-1/<KEY>` — third-party SaaS API keys

The default scope for `list_paths` and `list_systems` is
`/adminlm/it-systems/` — the entire customer IT subtree. Pass an
explicit prefix (e.g. `/adminlm/it-systems/ad/`) to narrow the scan.

If the system you need isn't listed by `list_systems`, the customer
hasn't added credentials for it yet — surface this as a "cannot
proceed, add via Streamlit" instruction rather than guessing or trying
common system names.

## Available MCP tools

The agent calls the three tools through the `infisical-mcp` MCP server
(registered in the `it_admin` Hermes profile). All three are READ-ONLY —
no write, update, delete, or rotate capability exists on the agent
side, by design.

### `get_secret(secret_path, secret_key) -> dict`

Fetch one secret value at call time. Returns
`{secretKey, secretPath, secretValue, updatedAt, secretComment}`.

- `secret_value` is included in the response — this is the ONLY tool
  that returns a value. Use it, then discard.
- 404 → the secret doesn't exist yet. The error envelope carries a
  `suggested_action: operator_add_required` field — surface that as a
  structured note ("cannot proceed — add via the AdminLM Secrets page
  and retry") rather than retrying or improvising.
- 401/403 → the agent token lacks scope or has been revoked. Distinct
  error code so the agent can prompt the operator to re-issue rather
  than treating it as a transient failure.

### `list_paths(path_prefix="/adminlm/it-systems/") -> list[dict]`

Enumerate secret keys under a path prefix. Returns
`[{secretKey, secretPath, updatedAt}, ...]` — NO VALUES, even if the
underlying API included them. Strict discovery-only contract.

Use this BEFORE `get_secret` when the agent doesn't know the exact
key name (e.g. "what AD service accounts are configured?"). Sort order
is stable across calls (by secretPath, then secretKey), so diffing two
listings is meaningful.

### `list_systems(path_prefix="/adminlm/it-systems/") -> list[str]`

Enumerate unique system folder names under a path prefix. Returns a
sorted list like `["ad", "ssh", "vmware", "saas-api-1"]`.

Use this FIRST when the agent doesn't even know what systems exist
(e.g. "show me what we can authenticate against"). The list is the
agent's first step before drilling into a specific system via
`list_paths`.

## Example usage

**Scenario:** the user asks "reboot the Windows file server WinSrv-01".

```
> user: "reboot WinSrv-01"
> agent: list_systems()                              # discover what's available
>         → ["ad", "ssh", "vmware", "winrm", ...]
> agent: list_paths("/adminlm/it-systems/winrm/")    # find the WinRM cred key
>         → [{secretKey: "WINSRV01_WINRM_PASS", secretPath: "/adminlm/it-systems/winrm/", updatedAt: "..."}]
> agent: get_secret("/adminlm/it-systems/winrm/", "WINSRV01_WINRM_PASS")
>         → {secretValue: "<value>", ...}
> agent: <uses value in mcp__server__windows__reboot("WinSrv-01")>
> agent: <discards the value — no echo, no log, no persistence>
```

Fetch → use → log → discard. The agent never holds the secret
persistently.

**Scenario:** the user asks "what can we authenticate against?"

```
> user: "what customer systems have credentials configured?"
> agent: list_systems() → ["ad", "ssh", "vmware", "saas-api-1"]
> agent: <reports back to the user with the system names>
```

No values are ever exposed to the user from a `list_*` call. If the
user asks "show me the AD password", refuse — that's operator-only via
the Streamlit Secrets page.

## Audit model

Every MCP call emits a structured audit event to Loki (label
`job="adminlm-infisical-mcp"`, stream `infisical_mcp`). The event
contains:

- `source`: always `"infisical_mcp"`
- `tool`: `get_secret` | `list_paths` | `list_systems`
- `path`: the `secret_path` argument (for `list_*`, the path prefix)
- `secret_key`: the key argument (for `get_secret` only — `list_*`
  calls have `secret_key=null`)
- `success`: `True` | `False`
- `error`: error message on failure (truncated to 200 chars)
- `user_id`: static operator label (the agent doesn't carry per-call
  user context, so this is a fixed value identifying the calling
  profile)

**CRITICAL — never log the secret value.** The audit event explicitly
excludes `secret_value`. The agent's tool-calling loop must not
echo the value into a log line, a stream, or a human-visible message
unless the user is in a typed-confirmation flow and explicitly asks
for it. The vault is designed for "use it then forget it" — every
egress of the value increases the audit footprint.

## Pitfalls

- **Don't try to write.** If the agent needs to create / update /
  delete / rotate a secret, that's operator-only via the Streamlit
  Secrets page. The MCP server exposes no write tools; the agent
  token has no write grants. Attempting to write surfaces a
  structured `agent_token_unauthorized` error — treat that as a
  prompt to tell the user "this is operator-only; open Streamlit to
  make the change."
- **Don't cache.** No MCP tool caches values, and the agent shouldn't
  either. Each credential use should start with a fresh `get_secret`
  call so the audit log shows every use and a rotated password takes
  effect immediately on the next call.
- **Don't enumerate values.** `list_paths` strips `secret_value`
  before returning. If you need a value, call `get_secret` for that
  specific key — never try to "collect all secrets by listing."
- **404 ≠ bug.** When `get_secret` returns `error: secret_not_found`,
  the agent's job is to surface the `suggested_action` to the
  operator, NOT to retry, NOT to fall back to guessing the value,
  NOT to escalate to a "system error" framing.
- **Tool errors are structured, not tracebacks.** Every failure
  returns a dict with `error`, `tool`, `path`, `secret_key`, and
  either `message` or `suggested_action`. Pattern-match on the
  `error` field; never assume the response shape on a Python
  traceback path.
- **The MCP is loopback-only.** `infisical-mcp` binds to
  `127.0.0.1:8003` on the AdminLM host. It is NOT reachable from a
  remote network. Don't try to call it from a profile running on a
  different machine.
