# BACKLOG #94 Phase 5.x — tests for infisical-mcp.
#
# Coverage targets (audit invariant is critical):
#   1. get_secret success → returns {secretKey, secretPath, secretValue, ...}
#   2. get_secret 404 → structured {error: "secret_not_found", ...}
#   3. get_secret transport error → structured {error: "transport_error", ...}
#   4. get_secret config_missing → {error: "config_missing", ...}
#   5. list_paths success → sorted [{secretKey, secretPath, updatedAt}, ...]
#      with secretValue STRIPPED (defensive)
#   6. list_paths empty vault → []
#   7. list_systems flat-layout → [] (deprecated behavior)
#   8. **AUDIT INVARIANT**: every _safe_log_event call NEVER includes
#      a `secret_value` field — secret values must never land in logs.
#      This is the BACKLOG #77 + #94 rule. Regression-test it.
#
# Mock strategy: monkeypatch `_get_json` (the thin httpx wrapper inside
# server.py) so we don't need a real Infisical instance. The tool
# functions only call _get_json, so this covers the full tool surface.
# Audit log calls are captured via a monkeypatched `log_event`.
#
# Run: pytest tests/test_infisical_mcp.py -v

from __future__ import annotations

import importlib
import os
import sys
from unittest.mock import patch

import pytest

# Set required env vars BEFORE importing server.py — it reads them at
# module load time and freezes them as INFISICAL_AGENT_TOKEN etc.
os.environ.setdefault("INFISICAL_URL", "http://mock-infisical:8090")
os.environ.setdefault("INFISICAL_PROJECT_ID", "00000000-0000-4000-8000-000000000001")
os.environ.setdefault("INFISICAL_ENVIRONMENT", "prod")
os.environ.setdefault("INFISICAL_AGENT_TOKEN", "test-token-not-real")
os.environ.setdefault("INFISICAL_HTTP_TIMEOUT", "5")

# Repo layout: tests/ is a sibling of server.py
HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_PATH = os.path.dirname(HERE)
sys.path.insert(0, SERVER_PATH)

# Import server; will pick up the test env vars set above.
server = importlib.import_module("server")


@pytest.fixture
def audit_log():
    """Capture every log_event() call so tests can assert shape."""
    captured: list[dict] = []

    def fake_log_event(stream: str, fields: dict) -> None:
        captured.append({"stream": stream, "fields": dict(fields)})

    with patch.object(server, "log_event", side_effect=fake_log_event):
        yield captured


# ============================================================
# get_secret — success / 404 / transport / config
# ============================================================

def test_get_secret_success_returns_value(audit_log):
    """Success path: returns the secret value plus metadata."""
    fake_response = {
        "secret": {
            "secretKey": "WINDOWS_ADMIN_PASSWORD",
            "secretPath": "/adminlm/it-systems/",
            "secretValue": "REDACTED-DO-NOT-LOG",
            "secretComment": "user and password for all windows servers",
            "updatedAt": "2026-10-27T22:07:36.794Z",
        }
    }
    with patch.object(server, "_get_json", return_value=fake_response):
        result = server.get_secret("/adminlm/it-systems/", "WINDOWS_ADMIN_PASSWORD")

    assert result["secretKey"] == "WINDOWS_ADMIN_PASSWORD"
    assert result["secretValue"] == "REDACTED-DO-NOT-LOG"
    assert result["secretComment"] == "user and password for all windows servers"
    # Audit event captured; success=True, no error field
    assert len(audit_log) == 1
    assert audit_log[0]["fields"]["success"] is True
    assert audit_log[0]["fields"]["tool"] == "get_secret"


def test_get_secret_404_returns_structured_secret_not_found(audit_log):
    """404 from Infisical must surface as structured secret_not_found
    so the agent can prompt the operator (BACKLOG #94 AC#7).
    httpx.raise_for_status() raises HTTPStatusError on 4xx, which the
    tool catches BEFORE the general httpx.HTTPError and routes to
    _http_error()."""
    import httpx

    def fake_get_json(url, params):
        # Simulate what httpx would raise — build a real HTTPStatusError.
        request = httpx.Request("GET", url)
        response = httpx.Response(404, request=request,
                                  text='{"message":"Secret not found"}')
        raise httpx.HTTPStatusError("HTTP 404", request=request,
                                   response=response)

    with patch.object(server, "_get_json", side_effect=fake_get_json):
        result = server.get_secret("/adminlm/it-systems/", "MISSING_KEY")

    assert result["error"] == "secret_not_found"
    assert result["tool"] == "get_secret"
    assert result["path"] == "/adminlm/it-systems/"
    assert result["secret_key"] == "MISSING_KEY"
    assert "operator_add_required" in result["suggested_action"]
    # Audit log records the 404 as success=True with error=secret_not_found
    assert len(audit_log) == 1
    assert audit_log[0]["fields"]["success"] is True
    assert audit_log[0]["fields"]["error"] == "secret_not_found"


def test_get_secret_transport_error_returns_structured(audit_log):
    """Network/transport failure: structured error, never traceback."""
    import httpx
    with patch.object(
        server, "_get_json",
        side_effect=httpx.ConnectError("connection refused"),
    ):
        result = server.get_secret("/adminlm/it-systems/", "ANY_KEY")

    assert result["error"] == "infisical_unreachable"
    assert result["tool"] == "get_secret"
    assert "connection refused" in result["message"].lower()
    # Audit logs the transport failure (the `error` field captures the
    # exception type+message, not a stable code — that's by design, so
    # operators can see the actual cause in Loki).
    assert audit_log[-1]["fields"]["success"] is False
    assert "ConnectError" in audit_log[-1]["fields"]["error"]
    assert "connection refused" in audit_log[-1]["fields"]["error"]


def test_get_secret_config_missing_when_token_blank(audit_log):
    """Without INFISICAL_AGENT_TOKEN, returns config_missing without
    even attempting the HTTP call."""
    with patch.object(server, "INFISICAL_AGENT_TOKEN", ""):
        result = server.get_secret("/adminlm/it-systems/", "ANY_KEY")

    assert result["error"] == "config_missing"
    assert audit_log[-1]["fields"]["error"] == "config_missing"


# ============================================================
# list_paths — success / empty / secretValue strip
# ============================================================

def test_list_paths_returns_keys_without_values(audit_log):
    """list_paths must NEVER return secretValue, even if Infisical
    includes it in the response (defensive strip)."""
    fake_response = {
        "secrets": [
            {
                "secretKey": "LINUX_SSH_KEY",
                "secretPath": "/adminlm/it-systems/",
                "secretValue": "REDACTED-DO-NOT-LOG",
                "secretComment": "ssh key for all linux servers",
                "updatedAt": "2026-10-28T02:07:36.794Z",
            },
            {
                "secretKey": "WINDOWS_ADMIN_PASSWORD",
                "secretPath": "/adminlm/it-systems/",
                "secretValue": "REDACTED-DO-NOT-LOG",
                "secretComment": "user and password for all windows servers",
                "updatedAt": "2026-10-28T02:07:36.883Z",
            },
        ],
        "imports": [],
    }
    with patch.object(server, "_get_json", return_value=fake_response):
        result = server.list_paths("/adminlm/it-systems/")

    assert len(result) == 2
    assert result[0]["secretKey"] == "LINUX_SSH_KEY"
    assert result[1]["secretKey"] == "WINDOWS_ADMIN_PASSWORD"
    # CRITICAL: secretValue MUST NOT appear in the response
    for entry in result:
        assert "secretValue" not in entry, "list_paths leaked secretValue"
        assert "secretComment" not in entry
        assert set(entry.keys()) == {"secretKey", "secretPath", "updatedAt"}


def test_list_paths_empty_vault_returns_empty_list(audit_log):
    with patch.object(server, "_get_json",
                      return_value={"secrets": [], "imports": []}):
        result = server.list_paths("/adminlm/it-systems/")

    assert result == []


def test_list_paths_transport_error_returns_single_error_dict(audit_log):
    """Transport failure surfaces as [{error: "transport_error"}]
    (a single-element list with the structured error so the agent can
    pattern-match on element[0]['error'] without catching exceptions)."""
    import httpx
    with patch.object(server, "_get_json",
                      side_effect=httpx.ReadTimeout("timeout")):
        result = server.list_paths("/adminlm/it-systems/")

    assert len(result) == 1
    assert result[0]["error"] == "infisical_unreachable"


def test_list_paths_calls_v4_endpoint_with_projectid(audit_log):
    """Regression sentinel: list_paths must use /api/v4/secrets with
    projectId (not the deprecated /api/v3/secrets with workspaceId,
    which returns empty in v0.166.2)."""
    captured: dict = {}

    def fake_get_json(url: str, params: dict):
        captured["url"] = url
        captured["params"] = params
        return {"secrets": [], "imports": []}

    with patch.object(server, "_get_json", side_effect=fake_get_json):
        server.list_paths("/adminlm/it-systems/")

    assert captured["url"].endswith("/api/v4/secrets")
    assert "projectId" in captured["params"]
    assert "workspaceId" not in captured["params"]


# ============================================================
# list_systems — flat-layout returns []
# ============================================================

def test_list_systems_returns_empty_in_flat_layout(audit_log):
    """In v1.0 (operator decision 2026-10-27) secrets are FLAT, so
    list_systems returns [] even when the /api/v2/folders endpoint
    succeeds. Documented behavior; not a bug."""
    fake_folders = {"folders": []}
    with patch.object(server, "_get_json", return_value=fake_folders):
        result = server.list_systems("/adminlm/it-systems/")

    assert result == []


def test_list_systems_returns_folder_names_if_present(audit_log):
    """If a future v2.x re-introduces nested folders, list_systems
    starts returning names again. Sanity: the function shape still works."""
    fake_folders = {"folders": [
        {"id": "1", "name": "ad"},
        {"id": "2", "name": "ssh"},
        {"id": "3", "name": "windows"},
    ]}
    with patch.object(server, "_get_json", return_value=fake_folders):
        result = server.list_systems("/adminlm/it-systems/")

    assert result == ["ad", "ssh", "windows"]


# ============================================================
# AUDIT INVARIANT — every log_event call must NEVER include
# the secret value. This is the BACKLOG #77 + #94 rule.
# Regression-test it: even if someone adds a `secret_value=...`
# kwarg, this test fails.
# ============================================================

def test_audit_invariant_no_secret_value_field(audit_log):
    """CRITICAL: across every tool call, no log_event call ever
    receives a field named secret_value, secretValue, value,
    password, credential, or token."""
    # Trigger every tool path.
    with patch.object(server, "_get_json",
                      return_value={"secret": {
                          "secretKey": "K", "secretValue": "REDACTED",
                          "secretPath": "/adminlm/it-systems/",
                          "updatedAt": "2026-10-27",
                          "secretComment": "test",
                      }}):
        server.get_secret("/adminlm/it-systems/", "K")

    with patch.object(server, "_get_json",
                      return_value={"secrets": [{
                          "secretKey": "K", "secretValue": "REDACTED",
                          "secretPath": "/adminlm/it-systems/",
                          "updatedAt": "2026-10-27",
                      }], "imports": []}):
        server.list_paths("/adminlm/it-systems/")

    with patch.object(server, "_get_json",
                      return_value={"folders": []}):
        server.list_systems("/adminlm/it-systems/")

    # Now check: across all captured events, NO field that could
    # plausibly be a secret value.
    forbidden_field_names = {
        "secret_value", "secretvalue", "value", "password",
        "credential", "token",
    }
    for event in audit_log:
        for field_name in event["fields"]:
            assert field_name.lower() not in forbidden_field_names, (
                f"audit_log leaked a secret-bearing field "
                f"{field_name!r} in event {event}"
            )


def test_audit_event_always_includes_path_and_tool(audit_log):
    """Every audit event must have at minimum: tool name + path +
    success bool. Loki dashboards rely on these fields being present."""
    with patch.object(server, "_get_json",
                      return_value={"secret": {
                          "secretKey": "K", "secretValue": "REDACTED",
                          "secretPath": "/adminlm/it-systems/",
                          "updatedAt": "2026-10-27",
                      }}):
        server.get_secret("/adminlm/it-systems/", "K")

    assert len(audit_log) >= 1
    event = audit_log[0]["fields"]
    assert event["tool"] == "get_secret"
    assert event["path"] == "/adminlm/it-systems/"
    assert isinstance(event["success"], bool)
