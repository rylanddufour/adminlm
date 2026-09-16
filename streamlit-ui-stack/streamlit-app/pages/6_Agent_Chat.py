# pages/6_Agent_Chat.py — AdminLM v1.0 customer Agent Chat.
#
# Card 5 of BACKLOG #64. Single-page chat that NEVER navigates away.
#
# Why no selectbox (2026-08-19): every pattern that uses a selectbox
# to switch between "new" and "continue existing" fights Streamlit's
# widget-state model. The widget\'s own key cannot be written from
# outside the widget callback (StreamlitAPIException); auto-pinning
# via a separate session_state key needs the selectbox\'s index= to
# reset on the rerun (fragile, has edge cases). The cleanest answer:
# no selectbox at all. The page reads st.session_state for the active
# session id and renders either "empty + prompt" or "history + prompt"
# accordingly. The chat_input widget handles its own clearing and
# triggers a script rerun on every submit.
#
# Privacy: chat message BODIES are NEVER written to Loki. Only metadata
# (user_id, session_id, role, msg_len) is shipped.

from __future__ import annotations

import json

import httpx
import streamlit as st

import hermes_client
from auth import require_auth, render_logout_button
from db import (
    add_chat_message,
    create_chat_session,
    get_chat_session,
    list_chat_messages,
    update_chat_session_response,
)
from settings import load as load_settings
from theme import ADMINLM_FAVICON, apply_theme, cyberpunk_title, page_header, page_link_button

st.set_page_config(
    page_title="Agent Chat — AdminLM", page_icon=ADMINLM_FAVICON, layout="wide",
)

if not require_auth():
    st.stop()

# Theme (BACKLOG #72 — Dark Cyber palette). Applied AFTER
# auth so the login form is the only place the default
# light theme bleeds through.
apply_theme()

settings = load_settings()
user_id: int = int(st.session_state.get("user_id") or 0)
username: str = str(st.session_state.get("user") or "unknown")
if not user_id:
    st.error("Session lost its user_id — please log in again.")
    st.stop()

# The active session id lives in session_state (NOT a widget key) so
# we can freely write/read it from anywhere in the script.
active_session_id: str | None = st.session_state.get("_active_chat_session_id")


# ---- Page header ----
# Layout: title on the left, "New Session" button on the right when
# a session is active. The button clears the active pointer (the
# chat is already saved to chat_sessions + chat_messages — pick up
# later from /Chat_Sessions).
# Title on its own line — full width, no column fiddling.
cyberpunk_title("Agent Chat", "agent_chat")
st.caption(
    "Type a question below and press Enter. Your conversation "
    "stays here — no jumping between pages."
)

# New Session button: small, right-aligned, dimmed-primary style
# (BACKLOG #73 item 1). No icon — text-only "New Session". Always
# render; disable when no active session to avoid Streamlit's
# conditional-widget edge case where a button conditional on
# session_state disappears after a chat_input rerun until the user
# navigates away and back.
# Column split [9, 1] pushes the button to the far right without
# giving it the full width the [5, 2] split did (which read as
# "primary action competing with the page title").
_, btn_r = st.columns([9, 1])
with btn_r:
    new_btn = st.button(
        "New Session",
        key="new_session_top",
        type="primary",
        disabled=(active_session_id is None),
        help=(
            "End this conversation and start a new one. "
            "The current chat is saved to Chat Sessions history."
            if active_session_id
            else "No active session to close. Send a message first."
        ),
    )
    if new_btn:
        hermes_client.log_chat_event(
            "chat_session_closed",
            user_id=user_id,
            session_id=active_session_id,
        )
        st.session_state.pop("_active_chat_session_id", None)
        st.rerun()



# ---- Helpers ----
def _short_id(sid: str) -> str:
    return sid.split("-", 1)[0] if "-" in sid else sid[:8]


def _render_message(m: dict) -> None:
    role = m.get("role") or "assistant"
    with st.chat_message(role):
        st.markdown(m.get("content") or "")
        tcs = m.get("tool_calls_json")
        if tcs and role == "assistant":
            try:
                parsed = json.loads(tcs)
            except json.JSONDecodeError:
                parsed = []
            if parsed:
                with st.expander(
                    f"🔧 Tool calls ({len(parsed)})", expanded=False
                ):
                    for tc in parsed:
                        name = tc.get("name", "?")
                        args = tc.get("arguments", "")
                        tc_out = tc.get("output")
                        st.markdown(f"**`{name}`**")
                        if args:
                            st.code(args, language="json")
                        if tc_out is not None:
                            out_str = (
                                tc_out if isinstance(tc_out, str)
                                else json.dumps(tc_out)
                            )
                            truncated = (
                                out_str[:200] + "…"
                                if len(out_str) > 200 else out_str
                            )
                            st.markdown(
                                f"↳ result (≤200 chars): `{truncated}`"
                            )


# ---- Body: empty vs. active ----
if active_session_id is None:
    st.info(
        "This is a fresh conversation. Type your question below and "
        "press Enter to start it."
    )
else:
    row = get_chat_session(active_session_id, user_id)
    if row is None:
        # Should never happen unless the local DB was wiped. Defensive.
        st.warning(
            f"Session `{_short_id(active_session_id)}` is not in your "
            "local store. The next message will start a new session."
        )
        st.session_state.pop("_active_chat_session_id", None)
        active_session_id = None
    else:
        title = row.get("title") or "(untitled)"
        st.caption(
            f"Session `{_short_id(active_session_id)}` — **{title}**"
        )
        msgs = list_chat_messages(active_session_id)
        for m in msgs:
            _render_message(m)


# ---- Chat input + send handling ----
# chat_input is the ONE widget on this page. It clears itself and
# triggers a script rerun on every submit. That natural cycle is what
# makes "stay on the same page" work.
prompt = st.chat_input("Ask IT_ADMIN…")

if prompt:
    hermes_client.log_chat_event(
        "chat_message_sent",
        user_id=user_id,
        session_id=active_session_id,
        role="user",
        msg_len=len(prompt),
    )

    # Echo the user message immediately.
    with st.chat_message("user"):
        st.markdown(prompt)

    default_title = prompt.strip().splitlines()[0][:60] if prompt.strip() else "Chat"

    is_new = active_session_id is None

    # Streaming chat: render the assistant reply live as SSE events arrive
    # from the gateway. Long-running agent turns (cron jobs, multi-tool
    # sequences) no longer look hung — the user sees text + tool calls
    # stream in as the agent works. Replaces the old "st.spinner + wait
    # for full response" pattern that timed out at 60s.
    text_placeholder = st.empty()
    tool_log_placeholder = st.empty()
    # Stream state lives in a dict so _consume_stream can mutate it
    # without `nonlocal` declarations (Pyright-friendly).
    stream_state: dict = {"text_buffer": "", "tool_log": []}

    def _render_streaming_progress() -> None:
        """Re-render the in-progress assistant reply + tool call log.

        Called after each SSE event so the user sees the agent's work
        stream in. Lives inside a closure over stream_state + the two
        placeholders above.
        """
        text_buffer = stream_state["text_buffer"]
        tool_log = stream_state["tool_log"]
        text_placeholder.markdown(text_buffer + "▌")  # blinking caret-ish
        if tool_log:
            with tool_log_placeholder.container():
                with st.expander(
                    f"🔧 Tool calls so far ({len(tool_log)})",
                    expanded=False,
                ):
                    for tc in tool_log:
                        name = tc.get("name", "?")
                        st.markdown(f"**`{name}`**")
                        args = tc.get("arguments", "")
                        if args:
                            st.code(args, language="json")

    def _consume_stream(events):
        """Drive the streaming state machine for an iterator of SSE events.

        Pulled out of the start/continue paths so each call site just
        passes the right generator (start_chat_streaming or
        continue_chat_streaming). Returns the per-turn session_id,
        response_id, and the final text + tool_calls.

        `events` is an iterable of (event_dict, hdr_session_id) tuples.
        """
        sess_id = ""
        resp_id = ""
        tool_call_index: dict[str, dict] = {}
        for event, hdr_session_id in events:
            if hdr_session_id and not sess_id:
                sess_id = hdr_session_id
            et = event.get("type")
            if et == "response.created":
                resp_id = event.get("response", {}).get("id", "") or resp_id
            elif et == "response.output_text.delta":
                delta = event.get("delta", "")
                if delta:
                    stream_state["text_buffer"] += delta
                    _render_streaming_progress()
            elif et == "response.output_item.added":
                item = event.get("item", {}) or {}
                if item.get("type") in ("function_call", "tool_call"):
                    tool_call_index[item.get("id", "")] = {
                        "name": item.get("name", "?"),
                        "arguments": "",
                        "call_id": item.get("call_id", ""),
                    }
                    stream_state["tool_log"] = list(tool_call_index.values())
                    _render_streaming_progress()
            elif et in (
                "response.function_call_arguments.delta",
                "response.function_call_arguments.done",
            ):
                item_id = event.get("item_id", "")
                if item_id in tool_call_index:
                    tool_call_index[item_id]["arguments"] = (
                        tool_call_index[item_id]["arguments"]
                        + (event.get("delta", "") or "")
                    )
                    if et.endswith(".done"):
                        tool_call_index[item_id]["arguments"] = (
                            event.get("arguments", "")
                            or tool_call_index[item_id]["arguments"]
                        )
                    stream_state["tool_log"] = list(tool_call_index.values())
                    _render_streaming_progress()
            elif et == "response.completed":
                resp = event.get("response", {}) or {}
                resp_id = resp.get("id", "") or resp_id
                # Pull the final output array — carries tool_call items
                # with their .output (if the gateway returned the tool
                # result inline). Merge into tool_log so the expander
                # shows the results once we close.
                for item in resp.get("output", []) or []:
                    if item.get("type") in ("function_call", "tool_call"):
                        tc_id = item.get("id", "")
                        existing = tool_call_index.get(tc_id, {})
                        tool_call_index[tc_id] = {
                            "name": item.get("name", existing.get("name", "?")),
                            "arguments": item.get(
                                "arguments", existing.get("arguments", ""),
                            ),
                            "call_id": existing.get("call_id", ""),
                            "output": item.get("output"),
                        }
                stream_state["tool_log"] = list(tool_call_index.values())
                _render_streaming_progress()
        return sess_id, resp_id, stream_state["text_buffer"], list(stream_state["tool_log"])

    # Defaults so post-except persistence code can save partial state
    # when a httpx.TimeoutException fires mid-stream (everything else
    # st.stop()s and never reaches here).
    result: dict = {"session_id": "", "response_id": "", "text": "", "tool_calls": [], "raw": None}

    try:
        if is_new:
            sess_id, response_id, text, tool_calls = _consume_stream(
                hermes_client.start_chat_streaming(
                    user=username, first_message=prompt,
                )
            )
            result = {
                "session_id": sess_id,
                "response_id": response_id,
                "text": text,
                "tool_calls": tool_calls,
                "raw": None,
            }
            # Persist the new session row.
            create_chat_session(
                session_id=sess_id,
                user_id=user_id,
                title=default_title,
                last_response_id=response_id,
            )
            hermes_client.log_chat_event(
                "chat_started",
                user_id=user_id,
                session_id=sess_id,
                msg_len=len(prompt),
                response_id=response_id,
            )
            st.session_state["_active_chat_session_id"] = sess_id
            active_session_id = sess_id
        else:
            sess = get_chat_session(active_session_id, user_id)
            prev = sess.get("last_response_id") if sess else None
            if not prev:
                # Defensive: no prior handle, start a fresh chat via the
                # streaming path so the user still sees progress.
                sess_id, response_id, text, tool_calls = _consume_stream(
                    hermes_client.start_chat_streaming(
                        user=username, first_message=prompt,
                    )
                )
                result = {
                    "session_id": sess_id,
                    "response_id": response_id,
                    "text": text,
                    "tool_calls": tool_calls,
                    "raw": None,
                }
                if sess_id != active_session_id:
                    st.session_state["_active_chat_session_id"] = sess_id
                    active_session_id = sess_id
                    create_chat_session(
                        session_id=sess_id,
                        user_id=user_id,
                        title=default_title,
                        last_response_id=response_id,
                    )
            else:
                # Normal continue path — streaming.
                sess_id, response_id, text, tool_calls = _consume_stream(
                    hermes_client.continue_chat_streaming(
                        session_id=active_session_id,
                        message=prompt,
                        previous_response_id=prev,
                    )
                )
                result = {
                    "session_id": active_session_id,
                    "response_id": response_id,
                    "text": text,
                    "tool_calls": tool_calls,
                    "raw": None,
                }
                update_chat_session_response(
                    session_id=active_session_id,
                    last_response_id=response_id,
                )
            hermes_client.log_chat_event(
                "chat_session_continued",
                user_id=user_id,
                session_id=active_session_id,
                role="user",
                msg_len=len(prompt),
                response_id=response_id,
            )

        # Clear the streaming caret when done. Drop the in-progress
        # tool_log_placeholder — the persisted assistant message below
        # re-renders the tool calls in their final form.
        text_placeholder.markdown(result.get("text", "") or "")
        tool_log_placeholder.empty()
    except hermes_client.HermesAuthError as e:
        st.error(
            "🔑 **Hermes auth failed.** "
            "`HERMES_API_KEY` is missing or rejected by the gateway. "
            f"({e})"
        )
        hermes_client.log_chat_event(
            "chat_error",
            user_id=user_id,
            session_id=active_session_id,
            error_type="HermesAuthError",
            error=str(e),
        )
        st.stop()
    except hermes_client.HermesAPIError as e:
        st.error(
            f"❌ **Hermes API error.** Status {e.status}. "
            f"Body: `{e.body[:200]}`"
        )
        hermes_client.log_chat_event(
            "chat_error",
            user_id=user_id,
            session_id=active_session_id,
            error_type="HermesAPIError",
            error=str(e),
            status=e.status,
        )
        st.stop()
    except httpx.TimeoutException as e:
        # The agent's been working >5min without sending response.completed.
        # The streamed text we have so far is preserved in the DB below;
        # show the user a clear "agent is still going" hint instead of
        # the generic "Chat failed" message.
        st.warning(
            "⏳ **Agent is taking longer than 5 minutes.** "
            "The response so far has been saved to this chat — please "
            "send a follow-up message if you want it to keep working. "
            f"({e})"
        )
        hermes_client.log_chat_event(
            "chat_error",
            user_id=user_id,
            session_id=active_session_id,
            error_type="httpx.TimeoutException",
            error=str(e),
        )
    except Exception as e:
        st.error(f"❌ **Chat failed:** {e}")
        hermes_client.log_chat_event(
            "chat_error",
            user_id=user_id,
            session_id=active_session_id,
            error_type=type(e).__name__,
            error=str(e),
        )
        st.stop()

    text = result.get("text", "") or ""
    tool_calls = result.get("tool_calls", []) or []

    # Persist user + assistant messages.
    add_chat_message(
        session_id=active_session_id,
        role="user",
        content=prompt,
    )
    add_chat_message(
        session_id=active_session_id,
        role="assistant",
        content=text,
        response_id=response_id,
        tool_calls_json=json.dumps(tool_calls) if tool_calls else None,
    )
    hermes_client.log_chat_event(
        "chat_response_received",
        user_id=user_id,
        session_id=active_session_id,
        role="assistant",
        msg_len=len(text),
        response_id=response_id,
        tool_call_count=len(tool_calls),
    )

    # Render the assistant reply in the same run so the user sees it
    # immediately. The chat_input submit already triggered a rerun,
    # so on the next render the history will include this exchange.
    with st.chat_message("assistant"):
        if text:
            st.markdown(text)
        else:
            st.caption("(no text in response — see tool calls)")
        if tool_calls:
            with st.expander(
                f"🔧 Tool calls ({len(tool_calls)})", expanded=False
            ):
                for tc in tool_calls:
                    name = tc.get("name", "?")
                    args = tc.get("arguments", "")
                    tc_out = tc.get("output")
                    st.markdown(f"**`{name}`**")
                    if args:
                        st.code(args, language="json")
                    if tc_out is not None:
                        out_str = (
                            tc_out if isinstance(tc_out, str)
                            else json.dumps(tc_out)
                        )
                        truncated = (
                            out_str[:200] + "…"
                            if len(out_str) > 200 else out_str
                        )
                        st.caption(f"↳ result: `{truncated}`")


# ---- Logout (moved from sidebar to page body) ----
st.markdown("\n---")
render_logout_button()
