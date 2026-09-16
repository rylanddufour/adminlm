# hermes_client.py
# Shared client utilities for AdminLM v1.0 customer Streamlit UI.
#
# Card 4 (BACKLOG #64) introduced this module with HMAC signing for the
# adminlm-ansible-runner + body redaction before persisting to SQLite.
# Card 5 (Agent Chat + Chat Sessions, BACKLOG #64) extends it with the
# Hermes Responses-API / sessions client.
#
# This module owns:
#
#   * HMAC-SHA256 request signing for the adminlm-ansible-runner API.
#     The signature is computed over the raw request body (no canonicalization)
#     so what gets sent over the wire is exactly what gets hashed. The header
#     format is the same Stripe / GitHub pattern: "X-Signature: sha256=<hex>".
#
#   * Body redaction before persisting to playbook_run_events.payload.
#     The Card 4 acceptance criteria explicitly require that no password,
#     passphrase, or secret VALUE lands in the database. We always sign
#     the ORIGINAL body (the runner needs the real creds to exec ansible)
#     and only redact on the way INTO the DB.
#
#   * Hermes API server client (Card 5):
#       POST /v1/responses          — start a chat session / continue
#       GET  /api/sessions          — list past sessions
#       GET  /api/sessions/<id>     — single session
#       DELETE /api/sessions/<id>   — delete session
#     All routed through a single `_hermes_request()` chokepoint that
#     attaches the Authorization + X-Hermes-Profile headers.
#
#   * Run-id + chat-event lifecycle logging to loki_logger so the run
#     / conversation can be traced end-to-end via Loki even though Loki
#     does NOT have a `run_id` or `session_id` LABEL (Card 2's alloy.yml
#     only emits `job`/`source` labels from the path matcher; the
#     identifiers live in the JSON payload).
#
# SECURITY:
#   - Every call to the runner MUST go through sign_request + post_signed
#     so the HMAC is never bypassed. If you find yourself wanting to call
#     httpx.post(runner_url + "/run", ...) directly, DON'T. Use post_signed.
#   - redact_secrets is best-effort: it scrubs every key in _SENSITIVE_KEYS
#     recursively in dicts and a simple regex pass over free-form strings.
#     It is NOT a defense against a determined attacker exfiltrating the
#     SQL store directly — it's the v1.0 "don't accidentally write
#     passwords to disk" guard.
#   - Chat message BODIES must NEVER land in Loki. log_chat_event only
#     records metadata + msg_len, never the message text. This is the
#     BACKLOG #64 v1.0 privacy contract for the chat stream.

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import uuid
from typing import Any

import httpx

try:
    # loki_logger is a sibling symlink in the streamlit-app dir (Card 3
    # setup). Importing is best-effort; if the symlink isn't there the
    # log_run_event call silently no-ops.
    from loki_logger import log_event as _loki_log_event
except Exception:  # pragma: no cover - exercised only if symlink missing
    def _loki_log_event(stream, fields):  # type: ignore[no-redef]
        return None


# ---------------------------------------------------------------------------
# Chat (Card 5 — Agent Chat + Chat Sessions, BACKLOG #64)
# ---------------------------------------------------------------------------
#
# Talks to Hermes's API server (Card 1 enabled it on .220, port 8642). The
# server exposes:
#
#   POST /v1/responses          — OpenAI Responses API shape. Body has
#                                 {model, input, stream?, previous_response_id?}.
#                                 Returns {id, status, model, output[], usage}.
#                                 The X-Hermes-Session-Id response header carries
#                                 the server-side session UUID; per-turn
#                                 `id` ("resp_...") is the chain handle for the
#                                 next `previous_response_id`.
#
#   GET  /api/sessions          — OpenAI list shape. {object:"list", data:[...],
#                                 limit, offset, has_more}. Each row carries
#                                 id, source, model, title, started_at,
#                                 last_active, message_count, tool_call_count,
#                                 preview, pinned, archived, hidden, ...
#
#   GET  /api/sessions/<id>     — Single session row wrapped in
#                                 {object:"hermes.session", ...}.
#
#   DELETE /api/sessions/<id>   — Returns {object:"hermes.session.deleted",
#                                 deleted:true}. 404 after deletion.
#
# Auth: every call goes through `_hermes_request()` which adds
#   Authorization: Bearer <HERMES_API_KEY>
# and a 10s connect / 60s read timeout. Failure modes are deliberately
# non-fatal — see the helper docstring.
#
# LOCATIONS / ENV VARS:
#   HERMES_API_BASE_URL — full base URL incl. /v1 suffix. Default
#                         "http://host.docker.internal:8642/v1" (the
#                         streamlit-ui container talks to the Hermes
#                         gateway running on the host's s6-overlay).
#   HERMES_API_KEY      — 64-char hex from /home/ansible/.hermes/.env's
#                         API_SERVER_KEY. Injected via docker-compose env.
#                         If unset, all chat methods raise HermesAuthError.
#   HERMES_MODEL        — model alias passed to /v1/responses. Default
#                         "minimax/minimax-m3" (Card 1 verified this alias
#                         works — Hermes routes it through to the
#                         configured provider, OpenRouter in v1.0).
#   HERMES_PROFILE      — Hermes profile to drive. Default "it_admin".
#                         We pass it as a header so the gateway routes the
#                         conversation through the right skill set; the
#                         body itself does NOT include profile selection.


class HermesClientError(RuntimeError):
    """Base class for hermes_client chat failures."""


class HermesAuthError(HermesClientError):
    """HERMES_API_KEY not set, or the gateway rejected the bearer token."""


class HermesAPIError(HermesClientError):
    """Gateway returned a non-2xx status. Carries response text."""

    def __init__(self, status: int, body: str, url: str) -> None:
        super().__init__(f"Hermes API {status} on {url}: {body[:300]}")
        self.status = status
        self.body = body
        self.url = url


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def hermes_api_base_url() -> str:
    """Return the Hermes API server base URL (with /v1 suffix).

    This is the base for /v1/responses + /v1/models (OpenAI Responses
    API shape). For /api/sessions the gateway serves them at the ROOT
    (not under /v1/), so list_sessions / get_session / delete_session
    use `_api_base()` below instead of this URL.
    """
    v = os.environ.get("HERMES_API_BASE_URL", "").strip()
    return v or "http://host.docker.internal:8642/v1"


def _api_base() -> str:
    """Base URL for non-/v1 endpoints (/api/sessions, etc.).

    Hermes serves the session API at the root of the gateway, not under
    /v1/, so we strip the trailing /v1 from the configured base. If
    the operator sets HERMES_API_BASE_URL=http://host:8642 (no /v1),
    we use it as-is.
    """
    base = hermes_api_base_url().rstrip("/")
    if base.endswith("/v1"):
        return base[: -len("/v1")]
    return base


def hermes_api_key() -> str:
    """Return the bearer token for the Hermes API server. Empty string if not set.

    Returns "" (not None) when unset so callers can pass it straight into
    the Authorization header. `start_chat`/`continue_chat` raise
    HermesAuthError if it's empty.
    """
    return os.environ.get("HERMES_API_KEY", "").strip()


def hermes_model() -> str:
    """Return the model alias for /v1/responses. Default matches Card 1's probe."""
    return os.environ.get("HERMES_MODEL", "minimax/minimax-m3").strip() or "minimax/minimax-m3"


def hermes_profile() -> str:
    """Return the Hermes profile name for chat routing. Default it_admin."""
    return os.environ.get("HERMES_PROFILE", "it_admin").strip() or "it_admin"


# ---------------------------------------------------------------------------
# Low-level HTTP
# ---------------------------------------------------------------------------

# Default HTTP timeouts for non-streaming helpers (start_chat/continue_chat).
# Streaming helpers use the same values internally. Cron-job agents and
# other long-running tool sequences can take well over a minute; the
# previous 60s read cap made any agent turn running >1 cron job look like
# a hang. 300s read / 120s write is generous for v1.x.
_DEFAULT_TIMEOUT = httpx.Timeout(connect=10.0, read=300.0, write=120.0, pool=10.0)


def _hermes_request(
    method: str,
    path: str,
    *,
    json_body: dict | None = None,
    timeout: httpx.Timeout | None = None,
) -> httpx.Response:
    """Single chokepoint for Hermes API server calls.

    Adds the Authorization header. `path` is appended to the base URL —
    callers pass either "v1/responses" or "api/sessions"; the chokepoint
    resolves the right form by inspecting the base URL.

    Raises:
        HermesAuthError: HERMES_API_KEY is unset.
        httpx.RequestError: network/timeout/etc — callers may catch and
            surface as "Hermes unreachable".
    """
    key = hermes_api_key()
    if not key:
        raise HermesAuthError(
            "HERMES_API_KEY is not set in the streamlit-ui container env. "
            "Set it in docker-compose.yml (or .env) and rebuild."
        )
    # /v1/* paths (POST /v1/responses, GET /v1/models) use the configured
    # base (which ends in /v1). /api/* paths (GET /api/sessions) are
    # served at the root of the gateway, so we swap to _api_base() for
    # those. This avoids accidentally building /v1/api/sessions.
    if path.startswith("/api/") or path.startswith("api/"):
        base = _api_base()
        # normalize the leading-slash form
        p = path.lstrip("/")
    else:
        base = hermes_api_base_url().rstrip("/")
        if base.endswith("/v1") and path.startswith("v1/"):
            p = path[len("v1/"):]
        elif not base.endswith("/v1") and path.startswith("/v1"):
            p = path[len("/v1"):]
        else:
            p = path.lstrip("/")
    url = f"{base}/{p.lstrip('/')}"
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        # X-Hermes-Profile: the gateway routes via this profile name.
        # Card 1 verified the gateway reads it; safe default = "it_admin".
        "X-Hermes-Profile": hermes_profile(),
    }
    return httpx.request(
        method,
        url,
        headers=headers,
        json=json_body,
        timeout=timeout or _DEFAULT_TIMEOUT,
    )


def _raise_for_status(r: httpx.Response) -> None:
    """Convert a non-2xx response into HermesAPIError."""
    if r.status_code < 400:
        return
    # 401 means we have a key but the gateway rejected it; map to the
    # specific subclass so callers can show "auth failed" without
    # confusing the user with a generic "Hermes API 401".
    if r.status_code in (401, 403):
        raise HermesAuthError(f"Hermes auth failed: {r.status_code} {r.text[:200]}")
    raise HermesAPIError(r.status_code, r.text, str(r.url))


# ---------------------------------------------------------------------------
# Output parsing
# ---------------------------------------------------------------------------

def _extract_text_and_tools(output: list[dict]) -> tuple[str, list[dict]]:
    """Pull the assistant text and any tool-call records out of /v1/responses.

    The Responses-API output array is a list of items. v1.0 Hermes only
    emits two shapes:

      {type: "message", role: "assistant",
       content: [{type: "output_text", text: "..."}, ...]}

      {type: "function_call", name: "...",
       arguments: "...", call_id: "..."}    (server-side tool execution
                                              record — present when the
                                              agent invoked an MCP tool)

    The "output" array is read-only from the client's perspective; tool
    execution happened server-side, so we just describe what happened.

    Returns:
        (text, tool_calls) where text is the concatenated assistant text
        and tool_calls is the raw list of function_call items (each with
        name/arguments/call_id, possibly also an `output` field when the
        gateway returns the tool result inline).
    """
    texts: list[str] = []
    tool_calls: list[dict] = []
    for item in output or []:
        t = item.get("type")
        if t == "message":
            for chunk in item.get("content", []) or []:
                if chunk.get("type") == "output_text":
                    texts.append(chunk.get("text", ""))
        elif t in ("function_call", "tool_call"):
            tool_calls.append(item)
    return "".join(texts).strip(), tool_calls


# ---------------------------------------------------------------------------
# Chat methods (streaming + non-streaming)
# -----------------------------------------------------------------------------


def _iter_sse_events(response: httpx.Response):
    """Yield parsed SSE event dicts from an httpx streaming response.

    The gateway emits OpenAI Responses-API SSE events:
        event: response.created
        data: {"type": "response.created", ...}

    Empty lines separate events; comment lines start with ':'. We ignore
    comments and the 'event:' line (we read the type from `data`).

    Yields:
        dict (the parsed JSON `data` payload) per event.

    Raises:
        httpx.RequestError: network / timeout / etc.
        json.JSONDecodeError: a non-JSON data line slipped through.
    """
    for line in response.iter_lines():
        if not line:
            continue
        if line.startswith(":"):
            continue
        # Strip the "event: " / "data: " prefix and any \r
        if line.startswith("data:"):
            payload = line[len("data:"):].lstrip()
        else:
            # OpenAI Responses API streams also use 'event:' lines; ignore them
            continue
        if payload.strip() == "[DONE]":
            return
        yield json.loads(payload)


def start_chat(user: str, first_message: str) -> dict:
    """Start a new IT_ADMIN chat session.

    Non-streaming convenience wrapper around start_chat_streaming(). Collects
    the full SSE event stream and returns the same shape as before — keeps
    Card 5 / BACKLOG #64's external API stable. New UI work uses
    start_chat_streaming() directly to show live progress.

    Args:
        user: username (for audit logging only — body does NOT include it;
            Hermes uses X-Hermes-Profile header for routing).
        first_message: the user's first prompt.

    Returns:
        {
            "session_id":   "<X-Hermes-Session-Id UUID>",
            "response_id":  "<resp_...>",
            "text":         "<assistant text>",
            "tool_calls":   [{name, arguments, call_id, output?}, ...],
            "usage":        {input_tokens, output_tokens, total_tokens},
            "raw":          <full JSON response>,
        }

    Raises:
        HermesAuthError, HermesAPIError, httpx.RequestError.
    """
    session_id = ""
    response_id = ""
    final_output: list[dict] = []
    usage: dict = {}
    body_for_exc: dict = {}
    try:
        for event, hdr_session_id in start_chat_streaming(user, first_message):
            t = event.get("type")
            if t == "response.created":
                response_id = event.get("response", {}).get("id", "") or response_id
            elif t == "response.completed":
                resp = event.get("response", {}) or {}
                response_id = resp.get("id", "") or response_id
                final_output = resp.get("output", []) or []
                usage = resp.get("usage", {}) or {}
            if hdr_session_id:
                session_id = hdr_session_id
        # If we didn't get a completed event, fall back to whatever we collected
        if not final_output and body_for_exc:
            final_output = body_for_exc.get("output", []) or []
            usage = body_for_exc.get("usage", {}) or {}
    except httpx.HTTPError:
        # Re-raise — callers handle auth/api/network distinctly
        raise
    text, tool_calls = _extract_text_and_tools(final_output)
    if not session_id or not response_id:
        raise HermesAPIError(
            200,
            f"Missing session/response id: session_id={session_id!r} "
            f"response_id={response_id!r}",
            "<streaming>",
        )
    return {
        "session_id": session_id,
        "response_id": response_id,
        "text": text,
        "tool_calls": tool_calls,
        "usage": usage,
        "raw": {"output": final_output, "usage": usage},
    }


def start_chat_streaming(user: str, first_message: str):
    """Stream a new chat turn as SSE events.

    Yields:
        (event_dict, session_id_str) tuples. session_id_str is the value of
        the X-Hermes-Session-Id header from the first chunk (empty until
        the first event is received). event_dict is the parsed `data`
        payload of each SSE event.

    Raises:
        HermesAuthError: HERMES_API_KEY unset.
        HermesAPIError: gateway returned non-2xx on the first chunk.
        httpx.RequestError: network / timeout.
    """
    body = {"model": hermes_model(), "input": first_message, "stream": True}
    yield from _stream_chat_turn(body)


def continue_chat(session_id: str, message: str, previous_response_id: str) -> dict:
    """Continue an existing chat session.

    Non-streaming wrapper around continue_chat_streaming(). Same return
    shape as start_chat(). See start_chat()'s docstring + the
    IMPORTANT note about session_id vs previous_response_id below.

    IMPORTANT: Hermes chaining uses `previous_response_id` (per-turn
    response handle), NOT `conversation_id` or `session_id`. The
    `session_id` we return from start_chat is the X-Hermes-Session-Id
    UUID — useful for `delete_session` but NOT for chaining the next
    turn. Callers must persist `response_id` (the per-turn handle)
    alongside the session_id in their DB and pass it back here.
    """
    if not previous_response_id:
        raise HermesAPIError(
            0,
            "continue_chat requires previous_response_id (the resp_... from "
            "the prior turn). Got empty string.",
            "continue_chat",
        )
    session_id = ""
    response_id = ""
    final_output: list[dict] = []
    usage: dict = {}
    try:
        for event, hdr_session_id in continue_chat_streaming(
            session_id, message, previous_response_id
        ):
            t = event.get("type")
            if t == "response.created":
                response_id = event.get("response", {}).get("id", "") or response_id
            elif t == "response.completed":
                resp = event.get("response", {}) or {}
                response_id = resp.get("id", "") or response_id
                final_output = resp.get("output", []) or []
                usage = resp.get("usage", {}) or {}
            if hdr_session_id:
                session_id = hdr_session_id
    except httpx.HTTPError:
        raise
    text, tool_calls = _extract_text_and_tools(final_output)
    return {
        "session_id": session_id or session_id,  # echo the caller's value
        "response_id": response_id,
        "text": text,
        "tool_calls": tool_calls,
        "usage": usage,
        "raw": {"output": final_output, "usage": usage},
    }


def continue_chat_streaming(
    session_id: str, message: str, previous_response_id: str,
):
    """Stream a continuing chat turn as SSE events.

    See start_chat_streaming() for the yield shape. session_id argument
    here is the X-Hermes-Session-Id UUID — echoed back for logging.
    previous_response_id is the per-turn `resp_...` handle that chains
    the conversation.
    """
    body = {
        "model": hermes_model(),
        "input": message,
        "stream": True,
        "previous_response_id": previous_response_id,
    }
    yield from _stream_chat_turn(body)


def _stream_chat_turn(json_body: dict):
    """Internal chokepoint that opens the streaming request + iterates SSE.

    Yields (event_dict, session_id_str) tuples. On a non-2xx response
    (caught from the first byte of the stream) raises HermesAPIError so
    the UI can show a status code.

    The X-Hermes-Session-Id header is captured on the response and
    re-yielded on every event so callers always know the session id
    (without having to track it across events themselves).
    """
    # Same URL-resolution logic as _hermes_request(). We deliberately
    # don't share via a helper because streaming needs `client.stream()`
    # (which doesn't have a request() equivalent) and we want the
    # session_id header available on the first event.
    key = hermes_api_key()
    if not key:
        raise HermesAuthError(
            "HERMES_API_KEY is not set in the streamlit-ui container env. "
            "Set it in docker-compose.yml (or .env) and rebuild."
        )
    base = hermes_api_base_url().rstrip("/")
    if base.endswith("/v1"):
        url = f"{base}/responses"
    else:
        url = f"{base}/v1/responses"
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "X-Hermes-Profile": hermes_profile(),
    }
    session_id = ""
    # Use a streaming client so we don't buffer the full body.
    # Read/write timeouts: connect=10s (local Docker network), read=300s
    # (cron-job agents can take minutes), write=120s, pool=10s. Same as
    # _DEFAULT_TIMEOUT below.
    timeout = httpx.Timeout(connect=10.0, read=300.0, write=120.0, pool=10.0)
    with httpx.Client(timeout=timeout) as client:
        with client.stream("POST", url, headers=headers, json=json_body) as r:
            # Capture session id from the response headers (set by the
            # gateway on the first chunk of every turn).
            session_id = r.headers.get("X-Hermes-Session-Id", "").strip()
            if r.status_code >= 400:
                # Drain a small amount of the body for the error message
                # then raise. Streaming responses don't have r.text.
                snippet = b""
                try:
                    for chunk in r.iter_bytes(chunk_size=4096):
                        snippet += chunk
                        if len(snippet) > 4096:
                            break
                except Exception:
                    pass
                if r.status_code in (401, 403):
                    raise HermesAuthError(
                        f"Hermes auth failed: {r.status_code} {snippet[:200].decode(errors='replace')}"
                    )
                raise HermesAPIError(
                    r.status_code,
                    snippet[:2000].decode(errors="replace"),
                    str(r.url),
                )
            for event in _iter_sse_events(r):
                yield event, session_id


# Update _DEFAULT_TIMEOUT so the non-streaming helpers (still used by
# tests and any caller that wants the full body in one shot) also have
# the same generous read window. Cron-job agents and other long-running
# tool sequences can take well over a minute; the previous 60s cap made
# any agent turn running >1 cron job look like a hang.
# (Definition lives at the top of the file alongside _hermes_request.)


def list_sessions(user_id: int | None = None) -> list[dict]:
    """List Hermes-side chat sessions.

    Hermes stores sessions globally per profile (it_admin in v1.0); the
    `user_id` filter is applied client-side AFTER we enrich with the
    local SQLite mirror (see pages/7_Chat_Sessions.py — it joins the
    Hermes list against `chat_sessions WHERE user_id = ?`). Passing None
    here means "give me everything Hermes has".

    The shape of the returned list is the raw row objects from
    Hermes's /api/sessions `data` array. Each has:

        id, source, user_id, model, title, started_at, ended_at,
        end_reason, message_count, tool_call_count, input_tokens,
        output_tokens, ..., preview, pinned, archived, hidden, ...

    Returns:
        list of session dicts. Empty list on 404 or transport failure
        (logged, not raised — the UI falls back to local-SQLite-only).
    """
    try:
        r = _hermes_request("GET", "api/sessions")
        _raise_for_status(r)
        body = r.json()
        return list(body.get("data", []))
    except (HermesClientError, httpx.RequestError) as e:
        try:
            _loki_log_event("streamlit", {
                "event": "hermes_list_sessions_failed",
                "page": "Chat_Sessions",
                "error": str(e),
                "error_type": type(e).__name__,
            })
        except Exception:
            pass
        return []


def get_session(session_id: str) -> dict | None:
    """Fetch a single session row from Hermes. None on 404 / failure."""
    try:
        r = _hermes_request("GET", f"api/sessions/{session_id}")
        if r.status_code == 404:
            return None
        _raise_for_status(r)
        body = r.json()
        # /api/sessions/<id> wraps the row in {object:"hermes.session", ...}
        return body if body.get("object") == "hermes.session" else body
    except (HermesClientError, httpx.RequestError):
        return None


def delete_session(session_id: str) -> bool:
    """Delete a Hermes-side session. Returns True on confirmed deletion.

    Idempotent: if the session is already gone (404), we return True so
    the local SQLite cleanup isn't blocked by the user's prior delete.
    """
    try:
        r = _hermes_request("DELETE", f"api/sessions/{session_id}")
        if r.status_code == 404:
            return True
        _raise_for_status(r)
        body = r.json()
        return bool(body.get("deleted"))
    except (HermesClientError, httpx.RequestError) as e:
        try:
            _loki_log_event("streamlit", {
                "event": "hermes_delete_session_failed",
                "page": "Chat_Sessions",
                "session_id": session_id,
                "error": str(e),
                "error_type": type(e).__name__,
            })
        except Exception:
            pass
        return False


# ---------------------------------------------------------------------------
# Chat Loki helpers (Card 5)
# ---------------------------------------------------------------------------
#
# Privacy: chat message bodies MUST NOT land in Loki (per BACKLOG #64 v1.0
# privacy contract). We log the metadata that ties the event to a session
# + the message length — enough for ops dashboards / message-count graphs
# without leaking customer prompts.

def log_chat_event(
    event_type: str,
    *,
    user_id: int | None,
    session_id: str | None,
    role: str | None = None,
    msg_len: int | None = None,
    **fields: Any,
) -> None:
    """Append one streamlit.log event tagged with chat metadata.

    Recognized event_type values used by the chat pages:
        chat_started          — user opened a new session
        chat_message_sent     — user sent a message (role="user")
        chat_response_received — agent replied (role="assistant")
        chat_session_continued — second+ turn in same session
        chat_session_loaded   — user opened an existing session
        chat_session_deleted  — user deleted a session

    All events use stream="chat" so Loki queries can pull just chat events:
        {job="adminlm-streamlit"} | stream="chat"
    """
    payload: dict[str, Any] = {
        "page": "Agent_Chat",
        "user_id": user_id,
        "session_id": session_id,
    }
    if role is not None:
        payload["role"] = role
    if msg_len is not None:
        payload["msg_len"] = msg_len
    payload.update(fields)
    try:
        _loki_log_event("chat", {
            "event": event_type,
            **payload,
        })
    except Exception:
        pass  # logging must never break the chat flow


# ---------------------------------------------------------------------------
# HMAC (Card 4 — Run Playbook)
# ---------------------------------------------------------------------------

SIG_PREFIX = "sha256="


def runner_secret() -> str:
    """Return the shared secret used to sign requests to adminlm-ansible-runner.

    MUST match the runner's RUNNER_HMAC_SECRET. Default
    "dev-secret-rotate-me" matches Card 2's runner compose default. In
    production, set RUNNER_HMAC_SECRET in the streamlit-ui-stack/
    docker-compose.yml environment to the operator's chosen secret.
    """
    s = os.environ.get("RUNNER_HMAC_SECRET", "").strip()
    return s or "dev-secret-rotate-me"


def sign_request(body: bytes, secret: str | None = None) -> str:
    """Compute the X-Signature header value for a request body.

    Returns the string "sha256=<hex>". The body MUST be the EXACT bytes
    that will be sent on the wire. For JSON, json.dumps(payload).encode().

    Args:
        body: raw bytes to sign. Use json.dumps(payload, separators=(",", ":"))
            then .encode("utf-8") so the signing canonicalization matches
            whatever the runner reconstructs (it doesn't reconstruct; it
            just hashes request.body() verbatim). Consistency here only
            matters for the client to compute the same digest the server
            will.
        secret: shared secret. Defaults to runner_secret().

    Returns:
        The X-Signature header value, e.g. "sha256=ab12...".
    """
    if secret is None:
        secret = runner_secret()
    digest = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    return f"{SIG_PREFIX}{digest}"


def post_signed(
    url: str,
    payload: dict[str, Any],
    *,
    timeout: float = 300.0,
    headers: dict[str, str] | None = None,
) -> httpx.Response:
    """POST a JSON body to `url` with the X-Signature header attached.

    This is the ONLY caller that should hit the runner. Centralizing the
    signing here means an HMAC bypass requires editing hermes_client.py,
    not silently calling httpx.post directly.

    Args:
        url: full URL, e.g. "http://adminlm-ansible-runner:8000/run".
        payload: dict that will be JSON-serialized. Use sort-free,
            canonical form (separators=(",", ":")) so debuggers can
            reproduce the signature.
        timeout: request timeout in seconds. The runner streams NDJSON so
            a 5-minute default covers long playbooks without hanging the
            thread.
        headers: optional extra headers. X-Signature is added
            automatically.

    Returns:
        httpx.Response. Callers stream .iter_lines() for NDJSON.

    Raises:
        httpx.HTTPStatusError: NOT raised here — callers decide whether to
            treat 401 as "auth_failed" and 5xx as a runner outage.
    """
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    h = {"Content-Type": "application/json"}
    if headers:
        h.update(headers)
    h["X-Signature"] = sign_request(body)
    return httpx.post(url, content=body, headers=h, timeout=timeout)


# ---------------------------------------------------------------------------
# Redaction (Card 4 — Run Playbook)
# ---------------------------------------------------------------------------

# Lower-case, plus a few explicit two-word phrases ("ssh_password",
# "become_password"). Match is on substring of the key, not whole word,
# so e.g. "user_password_hash" or "db_passphrase_kid" still get scrubbed.
# The trailing "pass" covers Ansible's short-form variables (Ansible
# docs intentionally recommend both `ansible_ssh_pass` and
# `ansible_ssh_password`; both must be scrubbed).
_SENSITIVE_KEYS: frozenset[str] = frozenset({
    "password",
    "passwd",
    "pass",
    "passphrase",
    "secret",
    "api_key",
    "apikey",
    "token",
    "ssh_password",
    "become_password",
    "private_key",
})

# Free-form regex: catches "password=foo" / "secret: bar" inside any string
# value. Conservative — only matches `key=value` / `key: value` patterns
# next to a word from _SENSITIVE_KEYS so we don't scrub innocuous strings.
_REDACT_IN_STRINGS = re.compile(
    r"(?i)(" + "|".join(sorted(_SENSITIVE_KEYS)) + r")\s*[=:]\s*([^\s,;}\]\"']+)"
)


def redact_secrets(value: Any) -> Any:
    """Recursively scrub secrets in-place-style from `value`.

    Behavior:
      - dict: walk every key; if the key matches _SENSITIVE_KEYS, replace
        the VALUE with the literal string "***REDACTED***". Recurse into
        the remaining keys.
      - list/tuple: recurse on each element.
      - str: run a regex pass that catches 'password=foo' style patterns
        and replaces the value half with '***REDACTED***'.
      - everything else: returned unchanged (int, float, bool, None).

    Returns the scrubbed structure (deep-copied; the caller's input is not
    mutated).
    """
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for k, v in value.items():
            if any(s in str(k).lower() for s in _SENSITIVE_KEYS):
                out[k] = "***REDACTED***"
            else:
                out[k] = redact_secrets(v)
        return out
    if isinstance(value, list):
        return [redact_secrets(v) for v in value]
    if isinstance(value, tuple):
        return tuple(redact_secrets(v) for v in value)
    if isinstance(value, str):
        return _REDACT_IN_STRINGS.sub(r"\1=***REDACTED***", value)
    return value


def payload_is_clean(payload_json: str) -> bool:
    """Sanity check for the acceptance criterion: no row containing
    `password=` or `secret=` in the payload JSON.

    Implemented as a substring scan over the (already-redacted) row text.
    Use after INSERT to confirm the row's serialized text would not
    trigger a basic secret-leak audit. Returns True if neither substring
    appears.
    """
    low = payload_json.lower()
    return ("password=" not in low) and ("secret=" not in low)


# ---------------------------------------------------------------------------
# Run lifecycle helpers (DB + Loki)
# ---------------------------------------------------------------------------

def new_run_id() -> str:
    """Return a fresh uuid4 string. Use for playbook_runs.id and Loki tags."""
    return str(uuid.uuid4())


def short_run_id(run_id: str) -> str:
    """Return the first 8 hex chars of a run id. Used in tables to keep
    columns narrow without sacrificing uniqueness within a session."""
    if not run_id:
        return "(no run id)"
    return run_id.split("-", 1)[0] if "-" in run_id else run_id[:8]


def log_run_event(event_type: str, run_id: str, **fields: Any) -> None:
    """Append one streamlit.log event tagged with the run_id.

    Used by 3_Run_Playbook.py and 5_Run_Detail.py to leave an audit
    trail in Loki. Loki's `run_id` is in the JSON PAYLOAD (not a label),
    so Grafana queries must use pipe-filter `|= "run_id=<uuid>"`. See
    5_Run_Detail.py for the pre-built link.
    """
    try:
        _loki_log_event("streamlit", {
            "event": event_type,
            "run_id": run_id,
            "page": "Run_Playbook",
            **fields,
        })
    except Exception:
        pass  # logging must never break the run flow
