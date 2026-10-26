# BACKLOG #94 Phase 5 — infisical-mcp first cut.
#
# Read-only FastMCP server that fronts the Infisical REST API. Three tools
# (get_secret, list_paths, list_systems) all authenticate via the AGENT
# machine-identity access token (INFISICAL_AGENT_TOKEN env var, not the
# operator token — least-privilege separation of concerns). All HTTP calls
# are GET only; no write endpoints are exposed.
#
# The container is bound to 127.0.0.1:8003 on the host (see docker-compose.yml)
# so the customer's network cannot reach it directly. Hermes profiles that
# want to call this MCP must do so from the AdminLM host (it_admin profile).
#
# loki_logger.py is bind-mounted from ../adminlm-ansible-stack at runtime
# (PYTHONPATH set in docker-compose.yml), so we do NOT vendor it into the
# image. Same pattern as streamlit-ui-stack/streamlit-app uses.

FROM python:3.12-slim

WORKDIR /app

# curl is required by the docker-compose healthcheck. python:3.12-slim
# ships without it. ca-certificates keeps HTTPS calls (none in v1.0 — we
# hit the loopback-only infisical container over HTTP — but harmless).
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py /app/server.py

EXPOSE 8003

CMD ["python", "server.py", "--host", "0.0.0.0", "--port", "8003"]
