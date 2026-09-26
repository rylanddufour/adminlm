# settings.py
# Load backend URLs + customer name from environment variables,
# with operator-editable overrides from the ui_settings table.
#
# Two groups of URLs:
#   - Backend URLs (used for /health probes, container-to-container):
#     hermes_url, kb_url, inventory_url, loki_url, ansible_runner_url.
#   - Quick Links (browser-facing, host IP):
#     open_hermes_url, open_grafana_url, open_inventory_url.
#     (open_kb_url removed from the surfaced set — KB is a v1.0
#     read-only inventory of agent playbooks/notes; the Home page
#     Quick Links never rendered it and the Settings form no longer
#     exposes it. The dataclass field is kept for env-override
#     backwards-compatibility but no UI surface reads it.)
#
# Both groups persist in ui_settings. Health probes use Backend URLs
# (docker-internal hostnames). The Home page's Quick Links buttons
# use the Quick Links group (host IP) so the operator can click them
# and open the service in their browser.
#
# v1.0 customer stack sets these in docker-compose.yml. The Settings
# page can override any URL via the ui_settings table; those
# overrides take precedence over env.
#
# Host-IP substitution (BACKLOG #90): the OPEN_*_URL defaults below
# ship with the canonical .220 homelab IP. bootstrap.sh's
# substitute_streamlit_quicklinks() rewrites them at install time to
# the customer's actual host IP and writes a `# host-substituted: <ip>`
# sentinel so re-runs skip cleanly. Same pattern as
# substitute_host_ip() (BACKLOG #87 / prometheus.yml).

from __future__ import annotations

import os
from dataclasses import dataclass


def _overrides() -> dict[str, str]:
    try:
        from db import get_ui_settings
        return get_ui_settings()
    except Exception:
        return {}


@dataclass(frozen=True)
class Settings:
    # Identity
    customer_name: str
    admin_username: str
    # Backend URLs (used for /health probes, container-to-container)
    hermes_url: str
    kb_url: str
    inventory_url: str
    loki_url: str
    prometheus_url: str
    grafana_url: str
    ansible_runner_url: str
    # Quick Links (browser-facing, host IP)
    open_hermes_url: str
    open_grafana_url: str
    open_kb_url: str
    open_inventory_url: str

    @property
    def backends(self) -> list[tuple[str, str, str]]:
        """List of (display_name, base_url, health_path) for the health probe.

        Uses Backend URLs (container-internal hostnames), NOT the
        Quick Links group. Each backend declares its own `health_path`
        suffix because the convention varies across services:
        - /health (most apps; includes ansible-runner, kb-mcp, etc. — many
          return 404/302 but `_check_one` treats any HTTP response as reachable)
        - /-/ready (Prometheus 2.x; returns 200 when ready to serve)
        - /api/health (Grafana; returns 200 with build info)

        BACKLOG #68 — added Prometheus + Grafana (previously missing).
        """
        return [
            ("Hermes Dashboard", self.hermes_url, "/health"),
            ("KB MCP", self.kb_url, "/health"),
            ("Inventory MCP", self.inventory_url, "/health"),
            ("Loki", self.loki_url, "/health"),
            ("Prometheus", self.prometheus_url, "/-/ready"),
            ("Grafana", self.grafana_url, "/api/health"),
            ("Ansible Runner", self.ansible_runner_url, "/health"),
        ]

    @property
    def quicklinks(self) -> list[tuple[str, str]]:
        """List of (label, url) for the Home page Quick Links buttons.

        Uses the Quick Links group (browser-facing, host IP).
        KB MCP was removed in the same patch (BACKLOG #73 item 6b):
        the kb-mcp web UI is comment-outed and the operator reaches
        KB content through the Streamlit KB Search sidebar page.
        """
        return [
            ("Open Hermes Dashboard", self.open_hermes_url),
            ("Open Grafana", self.open_grafana_url),
            ("Open Inventory MCP", self.open_inventory_url),
        ]


def _env_or(key: str, default: str) -> str:
    """Read from env, then ui_settings override, then default.
    Empty override is treated as "use env default" (matches the
    Settings page's "Reset to default" UX)."""
    o = _overrides().get(key)
    if o is not None and o != "":
        return o
    return os.environ.get(key, default)


def load() -> Settings:
    return Settings(
        customer_name=_env_or(
            "ADMINLM_CUSTOMER_NAME", "dufour-int",
        ),
        admin_username=_env_or(
            "STREAMLIT_ADMIN_USERNAME", "admin",
        ),
        # Backend URLs (container-to-container, /health probes).
        hermes_url=_env_or(
            "HERMES_URL", "http://host.docker.internal:9119",
        ),
        kb_url=_env_or(
            "KB_MCP_URL", "http://kb-mcp:8002",
        ),
        inventory_url=_env_or(
            "INVENTORY_MCP_URL", "http://inventory-mcp:8001",
        ),
        loki_url=_env_or(
            "LOKI_URL", "http://loki:3100",
        ),
        prometheus_url=_env_or(
            "PROMETHEUS_URL", "http://prometheus:9090",
        ),
        ansible_runner_url=_env_or(
            "ANSIBLE_RUNNER_URL", "http://adminlm-ansible-runner:8000",
        ),
        grafana_url=_env_or(
            "GRAFANA_URL", "http://grafana:3000",
        ),
        # Quick Links (browser-facing, host IP). Defaults point at
        # the same host IP the operator types into the Settings page
        # most often. Override per field if a service is on a
        # different host.
        open_hermes_url=_env_or(
            "OPEN_HERMES_URL", "http://192.168.0.220:9119",
        ),
        open_grafana_url=_env_or(
            "OPEN_GRAFANA_URL", "http://192.168.0.220:3000",
        ),
        open_kb_url=_env_or(
            "OPEN_KB_URL", "http://192.168.0.220:8002",
        ),
        open_inventory_url=_env_or(
            "OPEN_INVENTORY_URL", "http://192.168.0.220:8001",
        ),
    )


# ---- Editable field registry ----
# The Settings page uses this to render form fields. Each field has
# a `group` key ("Backend URLs" or "Quick Links") so the page can
# split them into two sections.

EDITABLE_FIELDS: list[dict] = [
    # --- Backend URLs (used for /health probes) ---
    {
        "key": "HERMES_URL",
        "group": "Backend URLs",
        "label": "Hermes Dashboard",
        "default": "http://host.docker.internal:9119",
        "help": "Internal URL for the /health probe. Should be "
                "docker-reachable (e.g. http://host.docker.internal:9119 "
                "or http://hermes:9119 on the monitoring network).",
    },
    {
        "key": "GRAFANA_URL",
        "group": "Backend URLs",
        "label": "Grafana",
        "default": "http://grafana:3000",
        "help": "Internal URL for the /health probe. "
                "Container-internal; usually http://grafana:3000.",
    },
    {
        "key": "KB_MCP_URL",
        "group": "Backend URLs",
        "label": "KB MCP",
        "default": "http://kb-mcp:8002",
        "help": "Internal URL for the /health probe. Container-internal.",
    },
    {
        "key": "INVENTORY_MCP_URL",
        "group": "Backend URLs",
        "label": "Inventory MCP",
        "default": "http://inventory-mcp:8001",
        "help": "Internal URL for the /health probe. Container-internal.",
    },
    {
        "key": "LOKI_URL",
        "group": "Backend URLs",
        "label": "Loki",
        "default": "http://loki:3100",
        "help": "Internal URL for the /health probe. Container-internal.",
    },
    {
        "key": "PROMETHEUS_URL",
        "group": "Backend URLs",
        "label": "Prometheus",
        "default": "http://prometheus:9090",
        "help": "Internal URL for the /-/ready probe. Container-internal; "
                "usually http://prometheus:9090. Note: the Home page probes "
                "this URL at /-/ready (Prometheus's readiness endpoint).",
    },
    {
        "key": "ANSIBLE_RUNNER_URL",
        "group": "Backend URLs",
        "label": "Ansible Runner",
        "default": "http://adminlm-ansible-runner:8000",
        "help": "Internal URL for the /health probe. Container-internal.",
    },
    # --- Quick Links (browser-facing, host IP) ---
    {
        "key": "OPEN_HERMES_URL",
        "group": "Quick Links",
        "label": "Hermes Dashboard (browser)",
        "default": "http://192.168.0.220:9119",
        "help": "URL the operator clicks from the Home page. "
                "Should be the host IP (or external DNS) so the "
                "browser can reach it. Example: http://192.168.0.220:9119.",
    },
    {
        "key": "OPEN_GRAFANA_URL",
        "group": "Quick Links",
        "label": "Grafana (browser)",
        "default": "http://192.168.0.220:3000",
        "help": "Browser-facing Grafana URL. Example: http://192.168.0.220:3000.",
    },
    # --- Identity ---
    {
        "key": "ADMINLM_CUSTOMER_NAME",
        "group": "Identity",
        "label": "Customer name",
        "default": "dufour-int",
        "help": "Display name shown in the sidebar and at the top of every page.",
    },
    {
        "key": "STREAMLIT_ADMIN_USERNAME",
        "group": "Identity",
        "label": "Admin username",
        "default": "admin",
        "help": "Login username for the streamlit UI.",
    },
]
