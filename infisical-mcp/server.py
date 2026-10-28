# BACKLOG #94 Phase 5 — infisical-mcp first cut (READ-ONLY agent consumer).
#
# FastMCP server that fronts the Infisical REST API for the it_admin agent
# profile. Three tools, all GET-only:
#
#   get_secret(secret_path, secret_key)            → one value (call-time fetch)
#   list_paths(path_prefix)                         → [{secretKey, secretPath, updatedAt}, ...]
#                                                   (NO values — discovery only)
#   list_systems(path_prefix)                       → ["ad", "ssh", "vmware", ...]
#                                                   (unique sorted folder names)
#
# Design notes (do NOT relax these without an architecture-doc update):
#
# * Read-only by construction — no write/update/delete/rotate tool exists.
#   Verified by the per-tool audit + the docstrings' "READ-ONLY" tags.
#   The blast radius of a compromised agent token is read-only on the
#   operator pre-approved paths. Phase 5 acceptance gate.
#
# * Authenticates as INFISICAL_AGENT_TOKEN (the agent-default machine
#   identity created by bootstrap.sh deploy_infisical_stack()). NEVER reads
#   the operator-side token — that's the Streamlit Secrets page's token
#   (full path-scope CRUD via the operator UI). Operator/agent separation
#   is a least-privilege design.
#
# * Every call emits a `loki_logger.log_event` audit event with the
#   secret path + key, NEVER the value. Loki source = "infisical_mcp".
#   See BACKLOG #77 audit pattern (adminlm-ansible-stack/loki_logger.py).
#
# * Each tool has a 5s timeout. httpx raises on transport failure; the MCP
#   layer catches and returns a structured {error, ...} dict instead of a
#   Python traceback (which would surface to the agent and confuse it).
#
# * Endpoint shapes verified against Infisical v0.166.2:
#     - GET /api/v3/secrets/raw/{secretKey}?workspaceId=...&environment=...&secretPath=...
#         returns {secret: {secretKey, secretValue, secretPath, updatedAt, secretComment}}
#     - GET /api/v3/secrets?workspaceId=...&environment=...&secretPath=...&recursive=true
#         returns {secrets: [{secretKey, secretValue, secretPath, updatedAt, ...}]}
#         (we strip secretValue before surfacing — list_paths is discovery only)
#     - GET /api/v2/folders?projectId=...&environment=...&path=...&recursive=true
#         returns {folders: [{id, name, ...}]}
#         (note: /api/v2 not /api/v3 for folders — verified on v0.166.2;
#          projectId not workspaceId for this endpoint; same value either way)
#
# * The /health endpoint is a tiny FastAPI route on the same uvicorn
#   instance so docker-compose healthcheck and bootstrap verify_installation
#   can curl it without negotiating the MCP initialize handshake.

from __future__ import annotations

import argparse
import os
import sys
import traceback
from typing import Any
from urllib.parse import quote

import httpx
from fastmcp import FastMCP

# loki_logger.py is bind-mounted from ../adminlm-ansible-stack at runtime
# (see docker-compose.yml PYTHONPATH). If the import fails (e.g. running
# this script outside of docker for a syntax check), the audit calls become
# no-ops via _safe_log_event below — logging never breaks the read path.
try:
    from loki_logger import log_event  # type: ignore
except ImportError:
    def log_event(stream: str, fields: dict) -> None:  # type: ignore[no-redef]
        return None


# ---------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------

INFISICAL_URL = os.environ.get("INFISICAL_URL", "http://infisical:8090").rstrip("/")
INFISICAL_PROJECT_ID = os.environ.get("INFISICAL_PROJECT_ID", "").strip()
INFISICAL_AGENT_TOKEN = os.environ.get("INFISICAL_AGENT_TOKEN", "").strip()
INFISICAL_ENVIRONMENT = os.environ.get("INFISICAL_ENVIRONMENT", "prod").strip()
# Default prefix for list_paths / list_systems — points at the customer
# IT subtree defined by the architecture doc §5.
DEFAULT_PATH_PREFIX = os.environ.get("INFISICAL_PATH_PREFIX", "/adminlm/it-systems/")

# 5s per BACKLOG #94 task body — every read must time out fast so the
# agent doesn't hang on a slow Infisical. httpx raises on transport
# failure; the MCP layer wraps it into a structured error.
HTTP_TIMEOUT_SECONDS = float(os.environ.get("INFISICAL_HTTP_TIMEOUT", "5"))

# Static operator label — MCP doesn't carry per-call user context (the
# tool is invoked by the agent, not a named human) but loki_logger accepts
# an optional user_id field for grouping.
AUDIT_USER_ID = os.environ.get("INFISICAL_MCP_AUDIT_USER_ID", "agent-it_admin")


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

def _require_config() -> dict | None:
    """Return a structured error if the agent token or project id is missing.

    Returns None on success (caller proceeds), or a dict suitable to
    return directly from one of the tool functions on failure.
    """
    missing = []
    if not INFISICAL_AGENT_TOKEN:
        missing.append("INFISICAL_AGENT_TOKEN")
    if not INFISICAL_PROJECT_ID:
        missing.append("INFISICAL_PROJECT_ID")
    if missing:
        return {
            "error": "config_missing",
            "message": f"Required environment variables not set: {', '.join(missing)}",
            "missing": missing,
        }
    return None


def _auth_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {INFISICAL_AGENT_TOKEN}"}


def _safe_log_event(tool: str, path: str, secret_key: str | None,
                    success: bool, error: str | None = None) -> None:
    """Audit helper. NEVER logs secret_value — only path + key + outcome.

    Swallows logging failures so the read path is never broken by a Loki
    shipper outage. Pattern matches auth.py:_loki_log_event (streamlit).
    """
    try:
        fields: dict[str, Any] = {
            "source": "infisical_mcp",
            "tool": tool,
            "path": path,
            "secret_key": secret_key,
            "success": success,
            "user_id": AUDIT_USER_ID,
        }
        if error is not None:
            fields["error"] = error
        log_event("infisical_mcp", fields)
    except Exception:
        # Audit MUST NOT break the read path.
        pass


def _transport_error(tool: str, path: str, secret_key: str | None,
                     exc: Exception) -> dict:
    """Wrap an httpx / network exception into a structured error dict.

    Audit fires once with success=False. The agent receives a stable
    shape so its retry / discovery logic doesn't have to pattern-match
    Python tracebacks.
    """
    msg = f"{type(exc).__name__}: {exc}"
    _safe_log_event(tool, path, secret_key, success=False, error=msg[:200])
    return {
        "error": "infisical_unreachable",
        "tool": tool,
        "path": path,
        "secret_key": secret_key,
        "message": msg[:500],
    }


def _http_error(tool: str, path: str, secret_key: str | None,
                status: int, body_text: str) -> dict:
    """Wrap a non-2xx HTTP response into a structured error dict."""
    # 404 is a normal "secret not found" — surface as a distinct code so
    # the agent's discovery flow (BACKLOG #94 AC#7) can prompt the
    # operator to add it via Streamlit instead of treating it as a failure.
    if status == 404:
        _safe_log_event(tool, path, secret_key, success=True,
                        error="secret_not_found")
        return {
            "error": "secret_not_found",
            "tool": tool,
            "path": path,
            "secret_key": secret_key,
            "suggested_action": (
                "operator_add_required — add this secret via the AdminLM "
                "Secrets page (Streamlit :8501/secrets) and retry"
            ),
        }
    # 401/403 mean the agent token is missing scope or revoked — distinct
    # from a transport failure so the agent can prompt for re-issuance.
    if status in (401, 403):
        msg = f"HTTP {status}: {body_text[:200]}"
        _safe_log_event(tool, path, secret_key, success=False, error=msg)
        return {
            "error": "agent_token_unauthorized",
            "tool": tool,
            "path": path,
            "secret_key": secret_key,
            "message": msg,
            "suggested_action": (
                "Agent token lacks path scope or has been revoked. "
                "Re-issue via the AdminLM Secrets page scope-policy UI."
            ),
        }
    # Anything else — generic 5xx shape.
    msg = f"HTTP {status}: {body_text[:200]}"
    _safe_log_event(tool, path, secret_key, success=False, error=msg)
    return {
        "error": "infisical_http_error",
        "tool": tool,
        "path": path,
        "secret_key": secret_key,
        "status": status,
        "message": msg,
    }


def _get_json(url: str, params: dict[str, Any]) -> dict:
    """Thin wrapper around httpx.get — raises on transport failure."""
    with httpx.Client(timeout=HTTP_TIMEOUT_SECONDS) as client:
        r = client.get(url, params=params, headers=_auth_headers())
        r.raise_for_status()
        return r.json()


# ---------------------------------------------------------------------
# MCP server
# ---------------------------------------------------------------------

mcp = FastMCP("infisical")


@mcp.tool()
def get_secret(secret_path: str, secret_key: str) -> dict:
    """Fetch one secret value at call time. READ-ONLY.

    The agent calls this when it needs the actual value to authenticate
    against a customer system (e.g. AD admin password). The value is used
    immediately by the calling tool, then discarded — never cached or
    persisted. Every call emits an audit event (path + key, never value).

    Args:
        secret_path: Infisical folder path, e.g. "/adminlm/it-systems/ad/".
            Must end with "/" for a folder-scoped lookup; bare "/" for root.
        secret_key: exact secret key inside that folder,
            e.g. "WINSVR01_ADMIN_PW".

    Returns:
        On success: {secretKey, secretPath, secretValue, updatedAt,
            secretComment}. NOTE: secretValue is included — this is the
            ONLY tool that returns a value; list_paths / list_systems do
            not. The agent should not log or echo this to a human except
            for a typed-confirmation flow.
        On failure: structured {error, ...} dict — see _transport_error /
            _http_error. NEVER a Python traceback.
    """
    cfg_err = _require_config()
    if cfg_err is not None:
        _safe_log_event("get_secret", secret_path, secret_key,
                        success=False, error="config_missing")
        return cfg_err

    # URL-encode the key: httpx does NOT encode path segments, so a key
    # containing "/" or ".." could redirect the GET at a different
    # Infisical endpoint on the same host. safe="" encodes "/" too.
    url = f"{INFISICAL_URL}/api/v3/secrets/raw/{quote(secret_key, safe='')}"
    params = {
        "workspaceId": INFISICAL_PROJECT_ID,
        "environment": INFISICAL_ENVIRONMENT,
        "secretPath": secret_path,
    }
    try:
        data = _get_json(url, params)
    except httpx.HTTPStatusError as e:
        # 404 → secret_not_found (BACKLOG #94 AC#7 discovery flow).
        # 401/403 → agent_token_unauthorized. Other 4xx/5xx → generic.
        # _http_error MUST be matched BEFORE the general httpx.HTTPError
        # below because HTTPStatusError is a subclass of HTTPError.
        return _http_error("get_secret", secret_path, secret_key,
                           e.response.status_code, e.response.text)
    except httpx.HTTPError as e:
        return _transport_error("get_secret", secret_path, secret_key, e)
    except Exception as e:
        # Unexpected — still structured, never traceback.
        return _transport_error("get_secret", secret_path, secret_key, e)

    secret_obj = data.get("secret") if isinstance(data, dict) else None
    if not isinstance(secret_obj, dict):
        _safe_log_event("get_secret", secret_path, secret_key,
                        success=False, error="malformed_response")
        return {
            "error": "malformed_response",
            "message": "Infisical returned no .secret object",
            "tool": "get_secret",
            "path": secret_path,
            "secret_key": secret_key,
        }

    _safe_log_event("get_secret", secret_path, secret_key, success=True)
    return {
        "secretKey": secret_obj.get("secretKey", secret_key),
        "secretPath": secret_obj.get("secretPath", secret_path),
        "secretValue": secret_obj.get("secretValue", ""),
        "updatedAt": secret_obj.get("updatedAt"),
        "secretComment": secret_obj.get("secretComment", ""),
    }


@mcp.tool()
def list_paths(path_prefix: str = DEFAULT_PATH_PREFIX) -> list[dict]:
    """Enumerate secret keys under a path prefix. NO VALUES RETURNED.

    Use this to discover what secrets exist (e.g. "what AD accounts are
    configured?") before deciding which to fetch via get_secret. The
    returned dicts contain only key + path + updatedAt — even if Infisical
    included secretValue in the response, this tool strips it before
    returning. Strict read-only contract.

    Args:
        path_prefix: Infisical folder path to scan recursively. Default
            "/adminlm/it-systems/" scans the entire customer IT subtree.

    Returns:
        Sorted [{secretKey, secretPath, updatedAt}, ...]. NEVER includes
        secretValue. On failure: [] plus a single-element list with an
        {error, ...} dict (the agent can pattern-match element[0]).
    """
    cfg_err = _require_config()
    if cfg_err is not None:
        _safe_log_event("list_paths", path_prefix, None,
                        success=False, error="config_missing")
        return [cfg_err]

    # Endpoint note (verified on Infisical v0.166.2):
    #   The deprecated /api/v3/secrets LIST returns {"secrets": []} even
    #   when secrets exist. The supported replacement is /api/v4/secrets
    #   with `projectId` (not `workspaceId`). Mirrors the same fix in
    #   streamlit-ui-stack/streamlit-app/pages/2_Secrets.py — keep these
    #   two in lockstep when bumping Infisical versions.
    url = f"{INFISICAL_URL}/api/v4/secrets"
    params = {
        "projectId": INFISICAL_PROJECT_ID,
        "environment": INFISICAL_ENVIRONMENT,
        "secretPath": path_prefix,
        "recursive": "true",
    }
    try:
        data = _get_json(url, params)
    except httpx.HTTPStatusError as e:
        return [_http_error("list_paths", path_prefix, None,
                            e.response.status_code, e.response.text)]
    except httpx.HTTPError as e:
        return [_transport_error("list_paths", path_prefix, None, e)]
    except Exception as e:
        return [_transport_error("list_paths", path_prefix, None, e)]

    # /api/v3/secrets response shape (verified on v0.166.2):
    #   { secrets: [{ secretKey, secretValue, secretPath, updatedAt, ...}, ...],
    #     imports: [...] }
    # We drop secretValue defensively — list_paths is discovery only.
    raw_secrets = data.get("secrets", []) if isinstance(data, dict) else []
    out: list[dict] = []
    for s in raw_secrets:
        if not isinstance(s, dict):
            continue
        out.append({
            "secretKey": s.get("secretKey"),
            "secretPath": s.get("secretPath"),
            "updatedAt": s.get("updatedAt"),
        })

    # Stable, predictable order — easier for agents to diff across runs.
    out.sort(key=lambda r: (str(r.get("secretPath") or ""),
                            str(r.get("secretKey") or "")))
    _safe_log_event("list_paths", path_prefix, None,
                    success=True)
    # Attach count in an envelope-ish way without breaking the tool's
    # declared return type (list[dict]). Agent sees a uniform list and can
    # len() it for count.
    return out


@mcp.tool()
def list_systems(path_prefix: str = DEFAULT_PATH_PREFIX) -> list[Any]:
    """Enumerate unique system folder names under a path prefix. READ-ONLY.

    DEPRECATED in v1.0 flat layout (operator decision 2026-10-27).
    v1.0 keeps secrets FLAT under /adminlm/it-systems/ — there are no
    subfolders to enumerate. This tool will return [] for any v1.0 vault.
    Kept in the tool surface (rather than removed) so the agent's tool
    list stays stable; if a future v2.x re-introduces nested folders,
    this tool starts returning useful data again without code changes.

    Use list_paths() for discovery in v1.0 — it returns the same info
    (key + path + updatedAt) without relying on folder structure.

    Args:
        path_prefix: Infisical folder path to scan recursively. Default
            "/adminlm/it-systems/" scans the entire customer IT subtree.

    Returns:
        Sorted unique list[str] of system folder names. Will be [] in
        v1.0 flat layout. On failure: a single-element list containing
        a {error, ...} dict — the agent can pattern-match len() == 1
        and the first element's "error" key. NEVER an exception /
        traceback. The annotation is list[Any] because the failure
        element is a dict, not a str.
    """
    cfg_err = _require_config()
    if cfg_err is not None:
        _safe_log_event("list_systems", path_prefix, None,
                        success=False, error="config_missing")
        return [cfg_err]  # type: ignore[list-item]

    # /api/v2/folders (verified on v0.166.2 — folders live on /api/v2,
    # not /api/v3). Note the parameter is projectId, not workspaceId —
    # same value, different naming convention per endpoint family.
    url = f"{INFISICAL_URL}/api/v2/folders"
    params = {
        "projectId": INFISICAL_PROJECT_ID,
        "environment": INFISICAL_ENVIRONMENT,
        "path": path_prefix,
        "recursive": "true",
    }
    try:
        data = _get_json(url, params)
    except httpx.HTTPStatusError as e:
        return [_http_error("list_systems", path_prefix, None,
                            e.response.status_code, e.response.text)]  # type: ignore[list-item]
    except httpx.HTTPError as e:
        return [_transport_error("list_systems", path_prefix, None, e)]  # type: ignore[list-item]
    except Exception as e:
        return [_transport_error("list_systems", path_prefix, None, e)]  # type: ignore[list-item]

    # /api/v2/folders response: { folders: [{id, name, ...}] }
    raw_folders = data.get("folders", []) if isinstance(data, dict) else []
    names: set[str] = set()
    for f in raw_folders:
        if isinstance(f, dict) and isinstance(f.get("name"), str):
            names.add(f["name"])

    out = sorted(names)
    _safe_log_event("list_systems", path_prefix, None, success=True)
    return out


# ---------------------------------------------------------------------
# /health endpoint
# ---------------------------------------------------------------------
#
# FastMCP's streamable-http transport mounts the MCP protocol at /mcp
# and serves other routes alongside. The cleanest way to expose a tiny
# health probe is a custom FastAPI sub-app — but to avoid pulling in
# fastapi as a direct dep (fastmcp already includes uvicorn + starlette),
# we register a single ASGI route via mcp.custom_route.
#
# Pattern matches inventory-mcp's healthcheck (python socket probe) but
# here we use HTTP because the docker-compose healthcheck uses curl.
# curl-ing the /mcp endpoint returns 406 (Not Acceptable) since MCP
# requires Accept: text/event-stream — see bootstrap.sh verify_installation
# for the same workaround. /health is a plain HTTP 200 endpoint that
# verifies the server is up; deeper readiness (token valid, vault
# reachable) happens on the first real call.

@mcp.custom_route("/health", methods=["GET"])
def _health(_request) -> Any:
    """Liveness probe. Returns 200 with a small JSON body.

    Used by docker-compose healthcheck and bootstrap.sh verify_installation.
    Does NOT verify Infisical reachability — that's deferred to the first
    real MCP call so a transient Infisical outage doesn't crash-loop this
    container.
    """
    from starlette.responses import JSONResponse
    return JSONResponse({
        "status": "ok",
        "service": "infisical-mcp",
        "tools": ["get_secret", "list_paths", "list_systems"],
        "config": {
            "infisical_url": INFISICAL_URL,
            "infisical_project_id_set": bool(INFISICAL_PROJECT_ID),
            "infisical_agent_token_set": bool(INFISICAL_AGENT_TOKEN),
            "environment": INFISICAL_ENVIRONMENT,
            "default_path_prefix": DEFAULT_PATH_PREFIX,
        },
    })


# ---------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="AdminLM infisical-mcp (READ-ONLY)")
    parser.add_argument("--host", default="0.0.0.0", help="bind host (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8003,
                        help="bind port (default 8003; docker-compose.yml matches)")
    args = parser.parse_args()

    # Streamable HTTP transport — same as inventory-mcp / kb-mcp. The MCP
    # endpoint lives at /mcp; the /health route above lives at /health.
    # bootstrap.sh verify_installation probes /health (200) and the MCP
    # endpoint (200|406 — 406 is OK because /mcp requires Accept: text/event-stream).
    mcp.run(transport="streamable-http", host=args.host, port=args.port)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Last-resort safety net — print the traceback to stderr so the
        # container's `docker logs` shows it, but don't double-exit.
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
