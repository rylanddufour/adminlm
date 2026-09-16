# AdminLM - AI Agent Managed Services for SMBs

Self-hosting infrastructure platform using Hermes Agent.

## Prerequisites

- Ubuntu Server (24.04 recommended)
- User with **sudo privileges** (Hermes runs as this user)
- **Passwordless sudo** for that user — required. The docs-site Hermes installer
  inside `bootstrap.sh` runs `sudo` non-interactively many times (apt installs,
  Docker install, hermes-gateway.service enable, dashboard systemd unit). If
  sudo prompts for a password and stdin is closed (the usual `curl | bash`
  invocation), those `sudo` calls fail silently and downstream steps (Hermes
  Agent install + the Hermes-managed Node 22 binary that the Dashboard Vite
  build depends on) never complete. See `### "Web UI build failed; dashboard
  will not start"` below for the symptom this produces.
- Internet connectivity for downloading images

### Configuring passwordless sudo

```bash
# As root (or a sudo-capable user), give the install user passwordless sudo.
# Replace 'youruser' with the account that will run bootstrap.sh.
echo "youruser ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-adminlm-install
sudo chmod 440 /etc/sudoers.d/90-adminlm-install

# Verify it works without a password prompt
sudo -n true && echo "OK — passwordless sudo is working" || echo "FAIL — see above"
```

> **Why not just keep passwordless sudo in `/etc/sudoers`?** Use a drop-in
> file under `/etc/sudoers.d/` (mode 0440) — it's the standard pattern, easy
> to remove cleanly after install, and won't be clobbered by future
> `/etc/sudoers` edits.

## Deployment Process

### Quick Start (Recommended)

The bootstrap script supports both CLI arguments and interactive mode. **CLI is recommended** because piped input (`curl | bash`) doesn't support interactive prompts.

```bash
# Replace YOUR_API_KEY with your actual API key
curl -fsSL https://raw.githubusercontent.com/rylanddufour/adminlm/main/bootstrap.sh | bash -s -- --api-key YOUR_API_KEY --provider openrouter
```

**Supported providers:** `openai`, `anthropic`, `openrouter`, `google`

Example with model:
```bash
curl -fsSL https://raw.githubusercontent.com/rylanddufour/adminlm/main/bootstrap.sh | bash -s -- --api-key sk-xxx --provider openrouter --model openai/chatgpt-4o-latest
```

### Interactive Mode (Advanced)

If you prefer to be prompted for each option, clone the script first and run it interactively:

```bash
# Download script first
curl -fsSL -o bootstrap.sh https://raw.githubusercontent.com/rylanddufour/adminlm/main/bootstrap.sh

# Make executable and run (stdin will be your terminal)
chmod +x bootstrap.sh
./bootstrap.sh
```

**What bootstrap.sh does:**
- Installs Docker + Docker Compose
- Installs Hermes Agent dependencies (Python, Node.js, ffmpeg, ripgrep)
- Clones Hermes Agent repo
- Configures your API key
- Auto-deploys the monitoring stack

```bash
# Install Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# Build web UI
cd ~/.hermes/hermes-agent/web
npm install
npm run build

# Create systemd service
sudo tee /etc/systemd/system/hermes-dashboard.service > /dev/null << 'EOF'
[Unit]
Description=Hermes Agent Web Dashboard
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=/home/$USER/.hermes/hermes-agent
ExecStart=/bin/bash -c 'source .venv/bin/activate && exec hermes dashboard --port 9119 --host 0.0.0.0 --insecure --skip-build --no-open'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable hermes-dashboard
sudo systemctl start hermes-dashboard
```

## Accessing Services

| Service | URL | Credentials |
|---------|-----|-------------|
| **Hermes Dashboard** | `http://<host-ip>:9119` | Random basic_auth (see below) |
| Grafana | `http://<host-ip>:3000` | `admin` / random — auto-set on first boot, change immediately |
| Prometheus | `http://<host-ip>:9090` | None |
| Loki | `http://<host-ip>:3100` | None |
| Alloy | `http://<host-ip>:12345` | None (debug UI) |
| **Inventory MCP** | `http://<host-ip>:8001/mcp` | None (streamable-http, registered to `default` + `it_admin` profiles) |

### Retrieving Hermes Dashboard credentials

The dashboard password is **auto-generated** by `bootstrap.sh generate_dashboard_credentials()` (lines 678–751) and saved to `/var/log/hermes-bootstrap-credentials.log` (mode 0600). It is **not** shown in bootstrap stdout.

```bash
sudo cat /var/log/hermes-bootstrap-credentials.log
```

> **Security note:** The dashboard uses `dashboard.basic_auth.*` (basic_auth gate, not `--insecure`). The credentials are written to the log file separately so the customer can retrieve them. **Restrict access to trusted IPs only** with a firewall — see below.

### Recommended Firewall Rules

The Hermes Dashboard exposes API keys and configuration. Restrict access to trusted IPs only:

```bash
# Enable UFW if not already enabled
sudo ufw enable

# Allow your admin IP to access Hermes Dashboard (replace with your IP)
sudo ufw allow from 203.0.113.10/32 to any port 9119

# Allow your IP to access Grafana and Prometheus
sudo ufw allow from 203.0.113.10/32 to any port 3000,9090

# Deny direct access to Hermes Dashboard from the internet
sudo ufw deny 9119

# Check status
sudo ufw status
```

**Alternative: Use Tailscale VPN**
- If Tailscale is installed, connect via VPN instead of exposing ports
- Zero exposed ports = maximum security

**Dynamic IPs:** If your IP changes frequently, consider:
- Using Tailscale for access
- Using a VPN

## Architecture (v2.1 — current)

```
┌─────────────────────────────────────────────────────────────┐
│                    Host System (Ubuntu 24.04)                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐                                        │
│  │   Hermes Agent   │  (Python venv at ~/.hermes/hermes-agent)│
│  │  ──────────────  │  • default profile (customer-facing)    │
│  │  • SOUL.md       │  • it_admin profile (19 skills, BACKLOG │
│  │  • 19 skills     │    #20 — Cisco, UniFi, Aruba, AD,      │
│  │  • mcp_servers   │    DNS/DHCP, vSphere, Windows Server)   │
│  │    (DICT format, │  • skills.write_approval: true         │
│  │     PR #7)       │  • skills.guard_agent_created: true     │
│  │  • skill safety  │    (PR #8, BACKLOG #22)                 │
│  │    gates         │                                        │
│  └────────┬─────────┘                                        │
│           │                                                  │
│           │ systemd: hermes-dashboard.service (basic_auth)  │
│           ▼                                                  │
│  ┌──────────────────┐                                        │
│  │ Hermes Dashboard │  :9119, basic_auth (random password)   │
│  │   (web UI)       │  creds in /var/log/hermes-bootstrap-    │
│  │                  │  credentials.log                        │
│  └──────────────────┘                                        │
│                                                             │
│  ┌──────────── Docker Compose stacks ──────────────────────┐ │
│  │                                                        │ │
│  │  Observability:        MCP:           Inventory:        │ │
│  │  ┌──────────────┐      ┌────────┐     ┌──────────────┐  │ │
│  │  │  Alloy       │      │grafana │     │ inventory-   │  │ │
│  │  │ (privileged) │      │  -mcp  │     │     mcp      │  │ │
│  │  │  cadvisor +  │      └────────┘     │  :8001/mcp   │  │ │
│  │  │  node_exp    │                      └──────────────┘  │ │
│  │  └──────┬───────┘                      ┌──────────────┐  │ │
│  │         ▼                              │     nmap-    │  │ │
│  │  ┌──────────────┐     ┌────────┐       │  discovery   │  │ │
│  │  │  Prometheus  │ ──▶ │Grafana │       │  (NET_RAW +  │  │ │
│  │  │    :9090     │     │ :3000  │       │   NET_ADMIN) │  │ │
│  │  └──────────────┘     └────────┘       └──────────────┘  │ │
│  │  ┌──────────────┐                                       │ │
│  │  │    Loki      │  (systemd journal + container logs)   │ │
│  │  │    :3100     │                                       │ │
│  │  └──────────────┘                                       │ │
│  │  ┌──────────────┐                                       │ │
│  │  │  Promtail    │  (syslog receiver :514 only;         │ │
│  │  │              │   legacy :1514/:2514 removed in     │ │
│  │  │              │   BACKLOG #44 step 10 — network     │ │
│  │  │              │   devices continue via :514.)        │ │
│  │  └──────────────┘                                       │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**Key changes since v2.0 (see [BACKLOG.md](BACKLOG.md)):**

- **Inventory stack** (BACKLOG #14) — `inventory-mcp` exposes 7 device-management tools via MCP, plus optional `nmap-discovery` for network scanning
- **Grafana MCP** — agent can query Grafana (dashboards, datasources, alerts) via the `grafana-mcp` container
- **IT_ADMIN profile** (BACKLOG #20) — single generalist datacenter IT admin profile replacing 4 planned specialists (16-19)
- **Hermes basic_auth** (PR #6) — dashboard now uses `dashboard.basic_auth.*` in `~/.hermes/config.yaml` (random password per install)
- **MCP server config DICT format** (PR #7, BACKLOG #21) — `mcp_servers` in profile config now matches Hermes CLI's expected dict shape
- **Skill safety gates** (PR #8, BACKLOG #22) — `skills.write_approval: true` (writes staged for review) + `skills.guard_agent_created: true` (scans for malicious patterns)

## Troubleshooting

### "Web UI build failed; dashboard will not start"

This message is misleading — the Vite build itself is fine. The real cause
is almost always **the docs-site Hermes installer inside `bootstrap.sh`
couldn't run `sudo` non-interactively**, so the Hermes-managed Node binary
never landed at `$HOME/.hermes/node/bin/`. Without that Node, `npm install`
falls back to the system Node (usually Ubuntu 24.04's Node 20), which is
rejected by `web/package.json`'s `engines` constraint:

```
npm error code EBADENGINE
npm error Not compatible with your version of node/npm
npm error Required: {"node":"^22.22.0 || ^24.11.0 || >=26.0.0", ...}
npm error Actual:   {"node":"v20.x.x", ...}
```

The build then fails and `bootstrap.sh` reports "Web UI build failed" — but
the real fix is to give the install user passwordless sudo (see
[Prerequisites](#prerequisites)) and re-run bootstrap.sh.

**Verify on the affected host:**

```bash
# 1. Was Hermes-managed Node installed?
ls -la ~/.hermes/node/bin/node
# If missing → sudo was blocking the docs-site installer.

# 2. Can sudo run non-interactively?
sudo -n true && echo "OK" || echo "FAIL"
# If FAIL → fix sudoers (see Prerequisites above), then re-run bootstrap.sh.

# 3. Confirm the build works once the right Node is on PATH:
export PATH="$HOME/.hermes/node/bin:$HOME/.hermes/.local/bin:$PATH"
cd ~/.hermes/hermes-agent/web
npm install && npm run build
```

Re-run bootstrap.sh after fixing sudo:

```bash
cd ~/adminlm && git pull && bash bootstrap.sh
```

(The build is idempotent — it's safe to re-run end-to-end.)

### Check container status
```bash
docker ps
```

### View logs
```bash
docker compose logs -f
```

### Restart a service
```bash
docker compose restart <service-name>
```

### Check Alloy logs
```bash
docker logs alloy
```

### Access Alloy debug UI
```bash
# Port 12345 provides the Alloy UI for debugging
curl http://localhost:12345
```

## Files

- `GOAL.md` - Deployment specification for Hermes
- `bootstrap.sh` - Initial VM setup script
- `docker-compose.mcp.yml` - MCP server configuration
- `docker-compose.inventory.yml` - Inventory stack (MCP + nmap discovery)
- `inventory-stack/` - Inventory stack source
- `research/` - Architecture research + design docs
- `skills/` - Hermes skills bundled with the platform