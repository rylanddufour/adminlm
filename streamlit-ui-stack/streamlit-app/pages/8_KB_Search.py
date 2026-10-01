# pages/8_KB_Search.py — AdminLM v1.0 customer KB Search.
#
# Card 6 of BACKLOG #64. Read + add view over the kb-mcp backend.
# All KB access goes through `mcp_client` (MCP HTTP transport). No
# direct SQLite / shared FS access from this page.
#
# Privacy: search/add events log to Loki as METADATA ONLY. The query
# body NEVER lands in Loki — see the `_log` helper below. mcp_client
# itself never logs query bodies either (the rule per BACKLOG #14 /
# #30).
#
# Spec adherence:
# - Auth gate + sidebar logout (consistent with other pages).
# - Top: search input, status multi-select, trust_level multi-select,
#   result count.
# - Submit -> kb_search(query, k=20) -> results table (each result
#   shows a 200-char preview + 'Read more' button that opens a modal
#   dialog with the full markdown content).
# - "Add new KB entry" modal -> kb_add -> refresh list.
# - Loki events: {stream="kb", event="search|add", user_id, query_len,
#   result_count} (no query body).

from __future__ import annotations

import streamlit as st

from auth import require_auth, render_logout_button
from mcp_client import (
    MCPFormatError,
    MCPUnavailableError,
    MCPToolError,
    kb_add,
    kb_list,
    kb_search,
)
from settings import load as load_settings
from theme import ADMINLM_FAVICON, apply_theme, cyberpunk_title, page_header, page_link_button, section_header

st.set_page_config(
    page_title="KB Search — AdminLM",
    page_icon=ADMINLM_FAVICON, layout="wide",
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

# ---- Loki logger (best-effort; never break the page on logging) ----
def _log(event: str, **fields) -> None:
    """Log a kb_search page event. NEVER includes the query body.

    Fields always include user_id + query_len + result_count so the
    audit trail is useful without leaking what the customer searched
    for. If `result_count` is not provided, callers should still set
    it (we'll treat absent as 0 in Loki).
    """
    try:
        from loki_logger import log_event
        log_event(
            "kb",
            {
                "event": event,
                "page": "KB_Search",
                "user_id": user_id,
                "username": username,
                **{k: v for k, v in fields.items() if v is not None},
            },
        )
    except Exception:
        pass


cyberpunk_title("KB Search", "kb_search")
st.caption(
    "Search the knowledge base. Click **📖 Read more** under any "
    "result to expand the full content. Add new entries via the "
    "**+ Add** button."
)


# ---- Filter row + search input ----
# Layout: search input spans 3 cols on row 1, then status/trust/tags
# share a second row of 3 cols. The TL0-TL3 trust ladder explainer
# lives in a st.popover() next to the trust-level multiselect so it
# doesn't take screen real estate unless the user clicks it.
fcol1, fcol2, fcol3 = st.columns([3, 2, 2])
with fcol1:
    query = st.text_input(
        "Search",
        value=st.session_state.get("kb_search_query", ""),
        placeholder="e.g. restart streamlit  (or 'cisc' for prefix-match, \"exact phrase\", OR)",
        key="kb_search_query_input",
        # BACKLOG #73 item 5: streamlit's tooltip renderer collapses single
        # \n to a space (confirmed on .220 2026-10-01 — the bullet list
        # rendered as one wall of text). The Trust Level tooltip above
        # works because it uses \n\n between every line. Match that
        # pattern here.
        help=(
            "FTS5 syntax (kb-mcp's flavor):\n"
            "\n"
            "• Plain word: matches anywhere in the entry.\n"
            "\n"
            "• Last word auto-prefixed: `cisc` finds Cisco, Cisco switch, etc.\n"
            "\n"
            "• Explicit prefix: `cisco*` matches anything starting with cisco.\n"
            "\n"
            "• Multiple prefixes: `cisco* OR juniper*`.\n"
            "\n"
            "• Exact phrase: `\"streamlit restart\"` keeps words together.\n"
            "\n"
            "• Column restrict: `title:cisco` searches the title column only.\n"
            "\n"
            "NOT supported (FTS5 is prefix-only):\n"
            "\n"
            "• Suffix: `*sco` — no match.\n"
            "\n"
            "• Substring/wildcard: `*lit`, `*sw*`, `?isco` — no match.\n"
            "\n"
            "• For suffix/substring, use plain words (auto-prefix applies)\n"
            "\n"
            "  or multiple `prefix*` terms joined with OR."
        ),
    )
with fcol2:
    status_filter = st.multiselect(
        "Status",
        options=["pending", "approved", "rejected", "all"],
        default=[],
        key="kb_status_filter",
        help=(
            "Filter entries by review status.\n\n"
            "pending 🟠 — written, awaiting a human review.\n\n"
            "approved 🟢 — reviewed and accepted.\n\n"
            "rejected 🔴 — reviewed and marked as not useful.\n\n"
            "all — every status (including any future values)."
        ),
    )
with fcol3:
    # Trust ladder explainer becomes the multiselect's own help tooltip
    # (BACKLOG #73 item 5): same ? icon as the Search box above, no
    # separate popover button needed. Tooltip text is plain — no markdown
    # rendering in tooltips — so the bold/italics and the SQL field-name
    # reference are dropped; emojis + TL labels stay so the visual ladder
    # still reads the same as before.
    trust_filter = st.multiselect(
        "Trust Level",
        options=["TL0", "TL1", "TL2", "TL3", "all"],
        default=[],
        key="kb_trust_filter",
        help=(
            # Each TL is intentionally one short line so the tooltip's word-wrap
            # never combines the tail of one TL with the start of the next.
            # Blank line between blocks gives a clear visual separator.
            "TL0 ⚪ — agent-written, pending review.\n\n"
            "TL1 🟡 — agent-written, lightly reviewed.\n\n"
            "TL2 🔵 — customer-written or fully reviewed.\n\n"
            "TL3 🟢 — customer-written and approved.\n\n"
            "Set when the entry is first written; does not change on later edits."
        ),
    )

# Search button moved under the Tags row (BACKLOG #73 item 5b).
# Render order below is: filter widgets → tags → Search button → results.


# ---- Tag filter (client-side, BACKLOG #69 (c)) ----
# We compute the union of all tags from the visible result set so the
# multiselect only shows tags that actually appear. This avoids fetching
# a separate kb_list call (kb-mcp's kb_search already returns tags per
# row) and avoids listing stale tags from deleted entries. Multi-select
# uses AND semantics: an entry must have ALL selected tags to match.
#
# On first page load (no prior search in session_state) the dropdown
# would otherwise be empty — populate it once via kb_list so the user
# can filter by tag BEFORE clicking Search. Cached for 60s.
@st.cache_data(ttl=30, show_spinner=False)
def _all_tags_from_results(rows: list[dict]) -> list[str]:
    """Return sorted unique tag union across the given rows.

    Cached on the input rows (by id() — Streamlit's @st.cache_data
    keys on the actual list, so each call with new results recomputes).
    """
    tags: set[str] = set()
    for r in rows or []:
        for t in (r.get("tags") or []):
            if t:
                tags.add(str(t))
    return sorted(tags)


@st.cache_data(ttl=60, show_spinner=False)
def _initial_kb_for_tags() -> list[dict]:
    """Single kb_list call on first page load to populate the tag
    dropdown. Cached 60s — subsequent reruns within the TTL don't
    re-hit kb-mcp. Failure returns [] silently so the page still
    renders (just with an empty tag dropdown until the next refresh).

    IMPORTANT: this populates the Tags dropdown ONLY — it does NOT
    auto-fill the results list. Results stay empty until the user
    clicks Search, per BACKLOG #73 item 5b operator decision.
    """
    try:
        return kb_list(limit=200)
    except Exception:
        return []


# Tag options derived from a one-shot kb_list call cached for 60s.
# The results list itself stays empty — operator wants results to
# appear ONLY after the user clicks Search, not on page load.
_tag_options: list[str] = _all_tags_from_results(_initial_kb_for_tags())

tagcol1, tagcol2 = st.columns([3, 1])
with tagcol1:
    tag_filter = st.multiselect(
        "Tags (OR — entry must have ANY selected)",
        options=_tag_options,
        default=[],
        key="kb_tag_filter",
        help=(
            "Filter by tags assigned to entries. OR semantics — an entry "
            "is included if it carries at least one of the selected tags. "
            "Pick multiple tags to broaden the result set."
        ),
    )
with tagcol2:
    if _tag_options:
        st.caption(f"{len(_tag_options)} tag(s) available")

# Search button — left-aligned, immediately under the Tags row.
_btncol1, _btncol2 = st.columns([1, 4])
with _btncol1:
    search_clicked = st.button(
        "Search", type="primary", use_container_width=True, key="kb_search_btn"
    )


# ---- Helpers ----
_STATUS_COLORS = {
    "pending": "🟠",
    "approved": "🟢",
    "rejected": "🔴",
}

_TRUST_COLORS = {
    "TL0": "⚪",  # pending, agent-written
    "TL1": "🟡",
    "TL2": "🔵",
    "TL3": "🟢",  # customer-written, approved
}


def _trust_badge(level: int | None) -> str:
    """Render a trust-level TL0..TL3 badge from the int trust_level_at_creation."""
    if level is None:
        return "⚪ K?"
    k = f"TL{int(level)}"
    return f"{_TRUST_COLORS.get(k, '⚪')} {k}"


def _status_badge(status: str | None) -> str:
    s = (status or "unknown").lower()
    return f"{_STATUS_COLORS.get(s, '⚪')} {s}"


def _matches_filters(
    entry: dict, statuses: list[str], trusts: list[str],
    tags: list[str] | None = None,
) -> bool:
    """Return True iff entry passes the user-selected filters.

    Tag filter is OR — entry must carry at least one of the selected
    tags. Empty/None means "no tag filter applied".
    """
    if statuses and "all" not in statuses:
        if (entry.get("status") or "").lower() not in statuses:
            return False
    if trusts and "all" not in trusts:
        k = f"TL{entry.get('trust_level_at_creation', 0)}"
        if k not in trusts:
            return False
    if tags:
        entry_tags = set(t for t in (entry.get("tags") or []) if t)
        if not (set(tags) & entry_tags):
            return False
    return True


def _preview(content: str, n: int = 200) -> str:
    """First N chars of content with whitespace collapsed."""
    if not content:
        return ""
    flat = " ".join(content.split())
    return flat[:n] + ("…" if len(flat) > n else "")


def _full_content_block(entry: dict) -> None:
    """Render the full markdown content of one KB entry.

    Used inside the per-row 'Read more' expander below. Pulled out
    so the same render logic can be reused if we ever need it from
    another place (e.g. a future detail page).
    """
    st.markdown(
        f"{_status_badge(entry.get('status'))} · "
        f"{_trust_badge(entry.get('trust_level_at_creation'))} · "
        f"updated `{entry.get('updated_at', '?')}`"
    )
    content_md = entry.get("content", "") or ""
    st.markdown(content_md)


@st.dialog("KB Entry", width="large")
def _show_full_entry(entry: dict) -> None:
    """Modal dialog rendering the full markdown content of one entry.

    DEPRECATED — replaced by per-row st.expander('Read more').
    Kept around as a reference; the @st.dialog call no longer fires
    because nothing invokes _show_full_entry anywhere in the page.
    Safe to delete in a future cleanup pass.
    """
    title = entry.get("title", "(no title)")
    st.markdown(f"### 📄 {title}")
    _full_content_block(entry)
    _log("entry_viewed", entry_id=entry.get("id"))


# ---- Run the search ----
# The user explicitly clicks Search (search_clicked) — there is no
# auto-search on filter changes. With a query typed, hit kb_search.
# With an empty query, hit kb_list so status / trust / tag filters
# resolve against a broader entry set. Both paths feed results into
# session_state so subsequent reruns keep showing the last result set
# until the user clicks Search again.
#
# Per operator decision (BACKLOG #73 item 5b, 2026-08-30): results
# must NOT auto-render on page load. The page should land empty until
# the user clicks Search.
results: list[dict] = []
err_msg: str | None = None

if search_clicked:
    try:
        if query:
            with st.spinner("Searching KB…"):
                results = kb_search(query=query, k=20)
        else:
            # Empty-query path: pull a broader set via kb_list so
            # tag-only / status-only / trust-only searches work.
            # Limit 200 covers the realistic KB size for a customer
            # VM; pagination is a future concern if we ever exceed.
            with st.spinner("Loading KB…"):
                results = kb_list(limit=200)
        st.session_state["results"] = list(results)
    except MCPUnavailableError as e:
        err_msg = f"KB service unavailable: {e}"
    except MCPFormatError as e:
        # Per BACKLOG #14 — non-MCP-shaped response is a real problem.
        # Log full body to Loki, show truncated in UI, BLOCK.
        _log("kb_format_error", error=str(e)[:500])
        st.error(
            "❌ **KB MCP returned a non-MCP response.** This is a "
            "backend regression, not a UI bug. The response body has "
            "been logged to Loki under `stream=kb event=kb_format_error`. "
            f"First 300 chars: `{str(e)[:300]}`"
        )
        st.stop()
    except MCPToolError as e:
        err_msg = f"KB tool error: {e}"
    except Exception as e:
        err_msg = f"KB search failed: {type(e).__name__}: {e}"

    if err_msg:
        _log("kb_search_error", query_len=len(query), error=err_msg[:300])

    # Log the search (metadata only — never the query body).
    _log(
        "search",
        query_len=len(query),
        result_count=len(results),
        status_filter=",".join(status_filter),
        trust_filter=",".join(trust_filter),
        tag_filter=",".join(tag_filter),
    )

if err_msg:
    st.warning(f"⚠️ {err_msg}")


# ---- Apply client-side filters then render ----
filtered = [
    r for r in results
    if _matches_filters(r, status_filter, trust_filter, tag_filter)
]

st.caption(f"**{len(filtered)}** of {len(results)} result(s)")


# ---- Results table ----
section_header("Results")
if not filtered and (query or search_clicked or tag_filter or status_filter or trust_filter):
    st.info("No KB entries match your search + filters.")
elif not filtered:
    st.info("Type a query, pick a filter, or click Search to look up KB entries.")

for r in filtered:
    rid = r.get("id")
    cols = st.columns([6, 1, 1, 1])
    with cols[0]:
        # Title is plain text (no button) — the preview below shows
        # the first 200 chars of content. Full content lives in the
        # 'Read more' expander below each row so long entries don't
        # crowd other results (expander stays collapsed by default).
        st.markdown(f"**📄 {r.get('title', '(no title)')}**")
        st.caption(_preview(r.get("content", "")))
        if r.get("content"):
            with st.expander("📖 Read more", expanded=False):
                _full_content_block(r)
                _log("entry_viewed", entry_id=r.get("id"))
    with cols[1]:
        st.markdown(_status_badge(r.get("status")))
    with cols[2]:
        st.markdown(_trust_badge(r.get("trust_level_at_creation")))
    with cols[3]:
        st.caption(f"`{r.get('updated_at', '?')}`")


# ---- "Add new KB entry" modal ----
section_header("New KB Entry")
with st.expander("➕ Add new KB entry", expanded=False):
    with st.form("kb_add_form", clear_on_submit=True):
        new_title = st.text_input(
            "Title",
            key="kb_add_title",
            help="Short, scannable — this is what people search for. Required.",
        )
        new_content = st.text_area(
            "Content (markdown)",
            key="kb_add_content",
            height=200,
            help="Runbook / fact / gotcha body. Markdown is rendered on drill-down.",
        )
        new_entry_type = st.selectbox(
            "Entry type",
            options=["runbook", "fact", "gotcha"],
            key="kb_add_type",
        )
        new_tags = st.text_input(
            "Tags (comma-separated)",
            key="kb_add_tags",
            help="e.g. network, opnsense, restart",
        )
        submitted = st.form_submit_button("Add entry")
    if submitted:
        title_clean = (new_title or "").strip()
        content_clean = (new_content or "").strip()
        tag_list = [
            t.strip() for t in (new_tags or "").split(",") if t.strip()
        ]
        if not title_clean:
            st.error("Title is required.")
        elif not content_clean:
            st.error("Content is required.")
        else:
            try:
                with st.spinner("Adding entry…"):
                    row = kb_add(
                        title=title_clean,
                        content=content_clean,
                        entry_type=new_entry_type,
                        tags=tag_list,
                        created_by="customer",
                    )
                entry_id = row.get("id") if isinstance(row, dict) else None
                _log(
                    "add",
                    entry_id=entry_id,
                    entry_type=new_entry_type,
                    tag_count=len(tag_list),
                )
                st.success(
                    f"✅ Added entry **'{title_clean}'** "
                    f"(id={entry_id}). It is now in the table above."
                )
                # Rerun so the new entry shows in the list.
                st.rerun()
            except MCPUnavailableError as e:
                _log("kb_add_error", error=str(e)[:300])
                st.error(f"KB service unavailable: {e}")
            except MCPToolError as e:
                _log("kb_add_error", error=str(e)[:300])
                st.error(f"KB tool error: {e}")
            except Exception as e:
                _log("kb_add_error", error=str(e)[:300])
                st.error(
                    f"Add failed: {type(e).__name__}: {e}"
                )


# ---- Logout (moved from sidebar to page body) ----
st.markdown("---")
render_logout_button()