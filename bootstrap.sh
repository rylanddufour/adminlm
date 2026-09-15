#!/bin/bash
# Hermes Infrastructure Bootstrap Script v2.1
# Usage: curl -fsSL https://raw.githubusercontent.com/rylanddufour/adminlm/main/bootstrap.sh | bash -s -- --api-key YOUR_KEY --provider openrouter
#
# Options:
#   --api-key KEY       Your LLM provider API key (required for non-interactive)
#   --provider NAME    Provider: openai, anthropic, openrouter, google (default: openrouter)
#   --model MODEL      Model name (optional, will prompt if omitted)
#   --auto-deploy     Automatically deploy stack after setup (default: true)
#   --no-auto-deploy  Skip auto-deploy (manual mode)
#
# Interactive mode (no args):
#   curl ... | bash    # Prompts for API key and provider

set -e

# ============================================
# Version Sentinel — refuse auto-upgrade across versions.
#
# The shipped VERSION file lives in the same directory as this script.
# A customer's previously-installed version lives at $INSTALL_BASE_DIR/adminlm/VERSION.
# Mismatch ⇒ print upgrade instructions and exit 0 (be safe, do nothing).
# To force an upgrade, the customer (or Ryland via SSH) does:
#     rm ~/adminlm/VERSION && cd ~/adminlm && git pull && bash bootstrap.sh
# Or to skip migration safety, edit ~/adminlm/VERSION to match the new shipped version.
# ============================================

SHIPPED_VERSION="$(cat "$(dirname "${BASH_SOURCE[0]:-$0}")/VERSION" 2>/dev/null || echo "")"
INSTALLED_VERSION_FILE="$INSTALL_BASE_DIR/adminlm/VERSION"

if [[ -n "$SHIPPED_VERSION" && -f "$INSTALLED_VERSION_FILE" ]]; then
    INSTALLED_VERSION="$(cat "$INSTALLED_VERSION_FILE" 2>/dev/null || echo "")"
    if [[ "$INSTALLED_VERSION" != "$SHIPPED_VERSION" ]]; then
        echo "============================================"
        echo "  AdminLM VERSION MISMATCH — bootstrap halted"
        echo "============================================"
        echo ""
        echo "  Installed version:  $INSTALLED_VERSION"
        echo "  Shipped version:    $SHIPPED_VERSION"
        echo ""
        echo "  Bootstrap does NOT auto-upgrade across versions."
        echo "  To upgrade, run ONE of:"
        echo ""
        echo "    # Full upgrade (recommended; runs migrations):"
        echo "    rm $INSTALLED_VERSION_FILE && cd $INSTALL_BASE_DIR/adminlm && git pull && bash bootstrap.sh"
        echo ""
        echo "    # Skip migration safety (advanced; ONLY if you know what's changing):"
        echo "    echo $SHIPPED_VERSION > $INSTALLED_VERSION_FILE && bash bootstrap.sh"
        echo ""
        exit 0
    fi
fi

# ============================================
# Configuration
# ============================================

INFRA_REPO="${INFRA_REPO:-https://github.com/rylanddufour/adminlm.git}"
INFRA_BRANCH="${INFRA_BRANCH:-main}"
INSTALL_BASE_DIR="${INSTALL_BASE_DIR:-$HOME}"
HERMES_HOME="${HERMES_HOME:-$INSTALL_BASE_DIR/.hermes}"
DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-2.24.0}"
HERMES_PORT="${HERMES_PORT:-9119}"
HERMES_USER="${HERMES_USER:-$USER}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# log_* writes to stderr so it cannot contaminate $(...) command substitutions.
# Functions that need to return a value via stdout (like clone_infra_repo)
# must only emit the value to stdout — informational logging must go to stderr.
log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ============================================
# CLI Argument Parsing
# ============================================

CLI_API_KEY=""
CLI_PROVIDER="openrouter"
CLI_MODEL=""
AUTO_DEPLOY=true
DASHBOARD_USER="admin"
# BACKLOG #64 (v1.0 customer-facing deployment). The customer-facing services
# (adminlm-ansible + adminlm-ansible-runner + streamlit-ui) are always deployed
# with the main stack — they live in docker-compose.yml, not an overlay.
# Customer-vs-operator visibility is governed by authentication, not install
# flags.
# Removed 2026-08-20: --v1-private CLI flag and ADMINLM_DEPLOY_V1_PRIVATE env var.

while [[ $# -gt 0 ]]; do
    case $1 in
        --api-key)
            CLI_API_KEY="$2"
            shift 2
            ;;
        --provider)
            CLI_PROVIDER="$2"
            shift 2
            ;;
        --model)
            CLI_MODEL="$2"
            shift 2
            ;;
        --auto-deploy)
            AUTO_DEPLOY=true
            shift
            ;;
        --no-auto-deploy)
            AUTO_DEPLOY=false
            shift
            ;;
        --dashboard-user)
            DASHBOARD_USER="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --api-key KEY       Your LLM provider API key"
            echo "  --provider NAME     Provider: openai, anthropic, openrouter, google (default: openrouter)"
            echo "  --model MODEL       Model name (optional)"
            echo "  --auto-deploy       Automatically deploy stack after setup (default)"
            echo "  --no-auto-deploy    Skip auto-deploy"
            echo "  --dashboard-user USER   Username for the Hermes dashboard (default: admin)"
            echo ""
            echo "Examples:"
            echo "  $0 --api-key sk-xxx --provider openrouter"
            echo "  $0 --api-key sk-xxx --provider openai --model gpt-4o"
            echo "  $0                  # Interactive mode"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ============================================
# Provider Configuration
# ============================================

declare -A PROVIDER_ENV_VARS=(
    [openai]="OPENAI_API_KEY"
    [anthropic]="ANTHROPIC_API_KEY"
    [openrouter]="OPENROUTER_API_KEY"
    [google]="GOOGLE_API_KEY"
)

declare -A PROVIDER_MODELS=(
    [openai]="gpt-4o gpt-4o-mini gpt-4-turbo gpt-4"
    [anthropic]="claude-sonnet-4-20250514 claude-3-5-sonnet-20240620 claude-3-5-haiku-20240307 claude-3-opus-20240229"
    [openrouter]="openai/chatgpt-4o-latest openai/chatgpt-4o-mini anthropic/claude-sonnet-4 google/gemini-2.5-pro"
    [google]="gemini-2.5-pro gemini-2.0-flash gemini-1.5-pro"
)

# ============================================
# Interactive Selection Functions
# ============================================

interactive_select_provider() {
    echo ""
    echo "============================================"
    echo "  Select your LLM Provider"
    echo "============================================"
    echo ""
    echo "  [1] OpenAI"
    echo "  [2] Anthropic"
    echo "  [3] OpenRouter (default)"
    echo "  [4] Google"
    echo ""
    read -p "Enter choice [1-4]: " choice

    case $choice in
        1) PROVIDER="openai" ;;
        2) PROVIDER="anthropic" ;;
        3) PROVIDER="openrouter" ;;
        4) PROVIDER="google" ;;
        *) PROVIDER="openrouter" ;;
    esac

    echo "  Selected: $PROVIDER"
    echo ""
}

interactive_select_model() {
    local available_models="${PROVIDER_MODELS[$PROVIDER]}"
    local i=1
    local model_array=()
    
    echo "============================================"
    echo "  Select Model for $PROVIDER"
    echo "============================================"
    echo ""
    
    for model in $available_models; do
        echo "  [$i] $model"
        model_array+=("$model")
        i=$((i + 1))
    done
    echo ""
    echo "  [$(($i))] Custom model (enter name)"
    echo ""
    
    read -p "Enter choice [1-$(($i))]: " choice
    
    if [ "$choice" -ge 1 ] && [ "$choice" -le ${#model_array[@]} ]; then
        MODEL="${model_array[$((choice-1))]}"
    elif [ "$choice" -eq $(($i)) ]; then
        read -p "Enter model name: " MODEL
    else
        MODEL=""
    fi
    
    echo "  Selected: ${MODEL:-default}"
    echo ""
}

interactive_get_api_key() {
    echo "============================================"
    echo "  Enter API Key"
    echo "============================================"
    echo ""
    echo "  Provider: $PROVIDER"
    echo "  Model: ${MODEL:-default}"
    echo ""
    read -p "  API Key: " -s API_KEY
    echo ""
    echo ""
}

# ============================================
# Provider/Model Resolution
# ============================================

resolve_provider_model() {
    # If CLI args provided, use them
    if [ -n "$CLI_API_KEY" ]; then
        PROVIDER="$CLI_PROVIDER"
        
        MODEL="$CLI_MODEL"
        
        API_KEY="$CLI_API_KEY"
        
        # Validate provider
        if [ -z "${PROVIDER_ENV_VARS[$PROVIDER]}" ]; then
            log_error "Unknown provider: $PROVIDER"
            log_info "Valid providers: ${!PROVIDER_ENV_VARS[@]}"
            exit 1
        fi
        
        return 0
    fi
    
    # Interactive mode
    interactive_select_provider
    interactive_select_model
    interactive_get_api_key
}

# ============================================
# Pre-flight Checks
# ============================================

# Block until the dpkg lock is released, or timeout after ${1:-300}s.
# Common contention with unattended-upgrades (Ubuntu's automatic security-
# update service), which holds the dpkg lock while applying security
# updates in the background. Returns 0 when safe to apt, non-zero on
# timeout. Call once immediately before each `sudo apt(-get) ...`.
wait_for_dpkg_lock() {
    local timeout="${1:-300}"  # default 5 minutes
    local elapsed=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$timeout" ]; then
            log_error "Timed out waiting for dpkg lock (${timeout}s)"
            return 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 0
}

# Verify the hermes-gateway.service is actually listening on :8642 and :9119.
# Default unit is Type=simple, which systemd considers "active" the
# instant the PID exists — before any socket bind. If the gateway is in
# the restart-flap window (Restart=always + RestartSec=5) when probed,
# is-active may report active but the ports are unbound. Probing the
# actual ports is the proof-of-life.
#
# On probe failure: try systemctl restart once + re-probe. If still
# down after restart, surface as hard failure (don't infinite-loop).
#
# Args:
#   $1 = label for log lines (e.g. "install-time" or "verify-time")
# Returns 0 on success, 1 on hard failure.
verify_gateway_port_bind() {
    local label="${1:-port-bind check}"
    local attempt=0
    local max_attempts=3
    local wait_s=15

    while [ "$attempt" -lt "$max_attempts" ]; do
        attempt=$((attempt + 1))
        # Use `curl -s -o /dev/null` (no -f). The `-f` flag treats any
        # HTTP error as a connection failure, but /v1/models returns
        # 401 (correctly — it expects auth). A 401 still proves the
        # port is bound and the server is answering. Use `-w '%{http_code}'`
        # to capture the status without exiting non-zero on >=400.
        local p9119_code p8642_code
        p9119_code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:9119/)
        p8642_code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:8642/v1/models)
        if [ -n "$p9119_code" ] && [ -n "$p8642_code" ] && [ "$p9119_code" != "000" ] && [ "$p8642_code" != "000" ]; then
            log_success "  ✓ hermes-gateway ports bound (${label}, attempt $attempt; :9119=$p9119_code, :8642=$p8642_code)"
            return 0
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            log_warn "  ! hermes-gateway ports not bound (${label}, attempt $attempt/$max_attempts; :9119=$p9119_code, :8642=$p8642_code); restarting..."
            if sudo systemctl restart hermes-gateway.service 2>&1 | tail -3; then
                sleep "$wait_s"
            else
                log_warn "  ! systemctl restart returned non-zero (${label})"
            fi
        fi
    done

    log_error "  ✗ hermes-gateway ports still unbound after $max_attempts attempts (${label})"
    log_error "    Diagnose: sudo systemctl status hermes-gateway.service"
    log_error "    Logs:    sudo journalctl -u hermes-gateway.service -n 50"
    return 1
}

check_prerequisites() {
    log_info "Running prerequisites check..."

    if [ "$EUID" -eq 0 ]; then
        log_warn "Running as root is not recommended. Run as a regular user with sudo."
    fi

    local missing_cmds=()
    for cmd in curl git; do
        if ! command -v $cmd &> /dev/null; then
            missing_cmds+=($cmd)
        fi
    done

    if [ ${#missing_cmds[@]} -ne 0 ]; then
        log_info "Installing missing dependencies: ${missing_cmds[*]}"
        wait_for_dpkg_lock || return 1
        sudo apt update
        wait_for_dpkg_lock || return 1
        sudo apt install -y "${missing_cmds[@]}" jq
    fi

    # Runtime libs that the docs-site installer's Hermes-managed Node binary
    # dynamically links against. Without libatomic1, Node 26 fails to start on
    # a fresh Ubuntu VM with `error while loading shared libraries:
    # libatomic.so.1` (the docs-site installer then tries to redownload Node,
    # which hits the same error again). libstdc++6 and libgcc-s1 are usually
    # preinstalled on Ubuntu 22.04+ but we list them defensively so apt skips
    # them if already present.
    #
    # BACKLOG #64 v1.0-private (2026-08-20): a customer VM rolled back to a
    # pre-install snapshot and the bootstrap bailed at install_hermes() with
    # the libatomic.so.1 error. Install here so install_hermes() can't fail.
    local missing_libs=()
    # libatomic1 etc. are Node runtime deps (BACKLOG #40). build-essential is
    # the C/C++ toolchain the Hermes docs-site installer needs to compile
    # native modules (e.g. node-pty, bcrypt Node bindings). Without it, the
    # docs-site installer's Node bootstrap step prints "Could not install a
    # C++ compiler automatically" and exits with the toolchain missing,
    # which surfaces on fresh Ubuntu 24.04 VMs where build-essential is NOT
    # preinstalled. Build-essential is multi-MB but apt skips if installed.
    # 2026-09-10: surfaced during fresh AdminLM install (BACKLOG #78 step 6
    # E2E); the docs-site installer started requiring a C++ toolchain that
    # wasn't needed for earlier Hermes versions.
    for lib in libatomic1 libstdc++6 libgcc-s1 build-essential; do
        if ! dpkg -s "$lib" >/dev/null 2>&1; then
            missing_libs+=("$lib")
        fi
    done
    if [ ${#missing_libs[@]} -ne 0 ]; then
        log_info "Installing Node runtime libs + C++ toolchain: ${missing_libs[*]}"
        wait_for_dpkg_lock || return 1
        # Refresh the apt index BEFORE the install. On a fresh VM the
        # mirror's Packages.gz can be stale (e.g. bzip2 1.0.8-5.1build0.1
        # listed but the .deb is gone), which would 404 the install and
        # bail bootstrap mid-stream. Hit 2026-09-11 during the BACKLOG
        # #78 step 6 fresh install. Idempotent on re-runs.
        sudo apt update
        wait_for_dpkg_lock || return 1
        sudo apt install -y "${missing_libs[@]}"
    fi

    # Node.js is intentionally NOT installed here. The canonical Nous
    # docs-site installer (install_hermes, below) ships its own
    # Hermes-managed Node and validates it against the `engines` constraint
    # in web/package.json — so we don't have to track upstream Node major
    # bumps here. The previous approach (Node install here) was reverted in
    # commit 026fd64 because the underlying issue was using a stripped-down
    # GitHub-raw installer that doesn't manage Node; the proper fix is to
    # delegate Node management to the docs-site installer.

    log_success "Prerequisites check complete"
}

# ============================================
# Docker Installation
# ============================================

install_docker() {
    log_info "Checking for Docker..."

    if command -v docker &> /dev/null; then
        log_success "Docker is already installed: $(docker --version)"
        return 0
    fi

    log_info "Installing Docker..."

    wait_for_dpkg_lock || return 1
    sudo apt update
    wait_for_dpkg_lock || return 1
    sudo apt install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    wait_for_dpkg_lock || return 1
    sudo apt update
    wait_for_dpkg_lock || return 1
    sudo apt install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin

    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker "$HERMES_USER"

    log_success "Docker installed successfully"
    log_warn "You may need to log out and back in for docker group membership"
}

# ============================================
# Docker Compose
# ============================================

install_docker_compose() {
    log_info "Checking Docker Compose..."

    if docker compose version &> /dev/null; then
        log_success "Docker Compose plugin is available"
        return 0
    fi

    if command -v docker-compose &> /dev/null; then
        log_success "Docker Compose standalone is installed"
        return 0
    fi

    log_info "Installing Docker Compose standalone..."

    sudo curl -L "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose

    log_success "Docker Compose installed"
}

# ============================================
# Hermes Installation
# ============================================

install_hermes() {
    log_info "Checking for Hermes Agent..."

    # Always ensure the Hermes-managed Node + CLI are on PATH for the rest
    # of this bootstrap session — particularly build_dashboard_ui(), which
    # runs `npm install` directly. The docs-site installer ships Node at
    # $HERMES_HOME/node/bin/ (verified .220: v22.23.2, npm 10.9.8 — both
    # meet web/package.json's `engines` constraint) and the hermes CLI at
    # $HERMES_HOME/.local/bin/. Neither is on the default PATH, so without
    # this export `npm` is unfindable. This must run on EVERY bootstrap
    # invocation — including re-runs where Hermes is already installed and
    # the install below is skipped — hence why it sits above the
    # idempotency check.
    export PATH="$HERMES_HOME/node/bin:$HERMES_HOME/.local/bin:$PATH"

    if ! grep -q 'hermes-infrastructure' ~/.bashrc 2>/dev/null; then
        echo '' >> ~/.bashrc
        echo '# Hermes Infrastructure' >> ~/.bashrc
        echo 'export PATH="$HOME/.hermes/node/bin:$HOME/.hermes/.local/bin:$PATH"' >> ~/.bashrc
    fi

    if [ -f "$HERMES_HOME/hermes-agent/venv/bin/hermes" ]; then
        log_success "Hermes is already installed"
        return 0
    fi

    log_info "Installing Hermes Agent..."
    mkdir -p "$HERMES_HOME"
    # Use the canonical Nous docs-site installer (not the GitHub raw source).
    # The docs-site script ships a Hermes-managed Node 22 + validates against
    # the actual `engines` constraint in web/package.json, so we don't have
    # to track Node major versions in bootstrap.sh.
    #   --skip-setup       bypasses the interactive LLM wizard — bootstrap's
    #                      configure_hermes_api() writes ~/.hermes/.env and
    #                      calls `hermes config set model.{provider,default}`
    #                      afterwards (the docs-site installer takes no
    #                      --provider/--model/--api-key flags by design).
    #   --non-interactive  defensive: skip any future user-input stages.
    #   --hermes-home      explicit data dir (default would also work via
    #                      $HERMES_HOME env var, but explicit > implicit).
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --non-interactive --hermes-home "$HERMES_HOME"

    log_success "Hermes Agent installed to $HERMES_HOME"
}

# ============================================
# Clone Infrastructure Repository
# ============================================

clone_infra_repo() {
    log_info "Cloning infrastructure repository..."

    local infra_dir="$INSTALL_BASE_DIR/adminlm"

    if [ -d "$infra_dir/.git" ]; then
        log_info "Repository already exists, pulling latest..."
        cd "$infra_dir"
        # Redirect BOTH stdout and stderr — stdout "Already up to date." or
        # "Updating abc..def" would otherwise leak into $() capture and
        # contaminate INFRA_DIR (used as a path everywhere downstream).
        git pull origin "$INFRA_BRANCH" >/dev/null 2>&1 || log_warn "Could not pull latest"
    else
        log_info "Cloning from $INFRA_REPO"
        git clone -b "$INFRA_BRANCH" "$INFRA_REPO" "$infra_dir" >/dev/null 2>&1
    fi

    log_success "Infrastructure repository ready at $infra_dir"
    # Return value: ONLY the path. log_* above goes to stderr, so stdout is clean
    # for `$(clone_infra_repo)` capture. See log_* definitions for rationale.
    echo "$infra_dir"
}

# ============================================
# Configure Hermes with API Key
# ============================================

configure_hermes_api() {
    local env_file="$HERMES_HOME/.env"
    local env_var="${PROVIDER_ENV_VARS[$PROVIDER]}"
    
    log_info "Configuring Hermes with $PROVIDER provider..."
    
    # Write .env file
    cat > "$env_file" <<EOF
# LLM Provider Configuration
# Generated by bootstrap.sh v2.1

# Provider: $PROVIDER
# Model: ${MODEL:-default}"
${env_var}=${API_KEY}

# Allow all users (change for production security)
GATEWAY_ALLOW_ALL_USERS=true
EOF

    log_success "API key configured for $PROVIDER"

    # Apply provider + model to the default profile's config.yaml
    if [ -f "$HERMES_HOME/hermes-agent/venv/bin/hermes" ]; then
        local hermes_bin="$HERMES_HOME/hermes-agent/venv/bin/hermes"

        log_info "Setting default profile: provider=$PROVIDER model=${MODEL:-(unchanged)}..."

        # Set provider (always — even when --model omitted, --provider still applies)
        "$hermes_bin" config set model.provider "$PROVIDER" 2>/dev/null && \
            log_success "Provider set to $PROVIDER" || \
            log_warn "Could not set provider; leaving upstream default"

        # Set model only when explicitly passed
        if [ -n "$MODEL" ]; then
            "$hermes_bin" config set model.default "$MODEL" 2>/dev/null && \
                log_success "Model set to $MODEL" || \
                log_warn "Could not set model; leaving upstream default"
        fi
    fi
}

# ============================================
# Provision Hermes API server (BACKLOG #66)
# ============================================
#
# The Hermes API server is a gateway platform that exposes the OpenAI
# Responses API (`POST /v1/responses`, `/v1/chat/completions`, `/v1/models`)
# on port 8642 with bearer-token auth. The streamlit-ui container's Agent
# Chat page talks to it.
#
# Three things must be true for it to work on a fresh install:
#   1. `API_SERVER_KEY` is set in `~/.hermes/.env` (16+ chars; we use 64 hex).
#      The gateway platform only enrolls at startup when this is present.
#   2. `api_server.host: 0.0.0.0` is in `~/.hermes/config.yaml` so the
#      platform binds all interfaces, not just loopback. Default is 127.0.0.1
#      which blocks connections from the streamlit-ui container (lives on
#      the Docker monitoring bridge, can't reach loopback on the host).
#   3. `docker compose up -d` is run with `HERMES_API_KEY` exported in the
#      shell env (matches the API_SERVER_KEY value) so the streamlit-ui
#      container receives it. See `docker-compose.yml`'s `${HERMES_API_KEY:?}`
#      substitution — fail-loud if the bootstrap forgot to export it.
#
# All three are handled here. Idempotent: re-running on an already-configured
# host preserves the existing key (doesn't rotate), preserves the existing
# config.yaml block (just appends if missing), and re-exports the env var.
provision_api_server_key() {
    local env_file="$HERMES_HOME/.env"
    local config_yaml="$HERMES_HOME/config.yaml"

    # ---- 1. API_SERVER_KEY in ~/.hermes/.env ----
    if [ ! -f "$env_file" ]; then
        log_warn "$env_file does not exist; configure_hermes_api should run first. Skipping api_server provisioning."
        return 0
    fi

    # Source the .env so API_SERVER_KEY (and everything else Hermes wrote) is
    # in our shell, then re-export API_SERVER_KEY as HERMES_API_KEY for the
    # docker-compose substitution below.
    # shellcheck disable=SC1090
    set -a
    . "$env_file"
    set +a

    if [ -z "${API_SERVER_KEY:-}" ] || [ "${#API_SERVER_KEY}" -lt 16 ]; then
        log_info "API_SERVER_KEY missing or weak in $env_file; generating fresh 64-char hex..."
        local new_key
        new_key=$(openssl rand -hex 32)
        # Append (or replace) in-place. Use awk to avoid duplicates.
        if grep -q '^API_SERVER_KEY=' "$env_file"; then
            sed -i "s|^API_SERVER_KEY=.*|API_SERVER_KEY=$new_key|" "$env_file"
        else
            printf '\n# API server key (Hermes API gateway on port 8642; used by streamlit Agent Chat)\nAPI_SERVER_KEY=%s\n' "$new_key" >> "$env_file"
        fi
        export API_SERVER_KEY="$new_key"
        log_success "API_SERVER_KEY generated and written to $env_file"
    else
        log_info "API_SERVER_KEY already present in $env_file (len=${#API_SERVER_KEY}); preserving"
        export API_SERVER_KEY
    fi

    # Re-export as HERMES_API_KEY so the docker-compose.yml substitution
    # `${HERMES_API_KEY:?}` resolves at `docker compose up -d` time.
    export HERMES_API_KEY="$API_SERVER_KEY"

    # ---- 2. api_server.host: 0.0.0.0 in ~/.hermes/config.yaml ----
    if [ ! -f "$config_yaml" ]; then
        log_warn "$config_yaml does not exist; skipping api_server host binding. Streamlit Agent Chat may not be reachable from the streamlit-ui container."
        return 0
    fi

    if grep -qE '^[[:space:]]*api_server:[[:space:]]*$' "$config_yaml"; then
        # Block exists. Check that host is set to something other than 127.0.0.1.
        # We use a python-ish awk to find the `host:` line that follows `api_server:`
        # and is within 5 lines of it (don't touch unrelated api_server blocks if
        # they appear in nested contexts).
        local host_value
        host_value=$(awk '
            /^[[:space:]]*api_server:[[:space:]]*$/ { in_block=1; next }
            in_block && /^[[:space:]]*host:[[:space:]]*/ { print $2; exit }
            in_block && /^[[:space:]]*[a-zA-Z_]+:[[:space:]]*$/ && !/^[[:space:]]*host:/ { exit }
        ' "$config_yaml")
        if [ "$host_value" = "0.0.0.0" ]; then
            log_info "api_server.host already 0.0.0.0 in $config_yaml; preserving"
        else
            log_info "api_server.host is '$host_value' (not 0.0.0.0); updating so streamlit-ui container can reach :8642..."
            # Replace the first 'host:' line that appears under 'api_server:' block.
            # If no host: line exists in the block, insert one immediately after api_server:.
            if [ -n "$host_value" ]; then
                sed -i "/^[[:space:]]*api_server:[[:space:]]*$/,/^[[:space:]]*[a-zA-Z_]/ s|^[[:space:]]*host:[[:space:]]*.*|  host: 0.0.0.0|" "$config_yaml"
            else
                sed -i "/^[[:space:]]*api_server:[[:space:]]*$/a\\  host: 0.0.0.0\\n  port: 8642" "$config_yaml"
            fi
            log_success "api_server.host set to 0.0.0.0 in $config_yaml"
        fi
    else
        # No api_server block. Append one. Use a heredoc so the YAML stays
        # syntactically valid (no quoting surprises).
        log_info "Adding api_server: {host: 0.0.0.0, port: 8642} block to $config_yaml..."
        cat >> "$config_yaml" <<'YAML'

# Hermes API server (BACKLOG #66 — streamlit Agent Chat)
# Bound to 0.0.0.0 so the streamlit-ui container on the monitoring bridge
# can reach :8642 (loopback 127.0.0.1 would block cross-container traffic).
# API_SERVER_KEY in ~/.hermes/.env gates auth — same value exported as
# HERMES_API_KEY for the docker-compose substitution.
api_server:
  host: 0.0.0.0
  port: 8642
YAML
        log_success "api_server block appended to $config_yaml"
    fi

    # ---- 3. Restart hermes-gateway so the platform re-enrolls with the new key ----
    # The platform only loads at startup (when _has_usable_api_server_key runs).
    # We need to restart for the new key to take effect.
    if command -v systemctl >/dev/null 2>&1 && sudo test -f /etc/systemd/system/hermes-gateway.service 2>/dev/null; then
        log_info "Restarting hermes-gateway.service so api_server platform enrolls with the new key..."
        if sudo systemctl restart hermes-gateway.service; then
            log_success "hermes-gateway restarted"
        else
            log_warn "Failed to restart hermes-gateway; api_server platform may not enroll until next manual restart"
        fi
    else
        log_warn "systemctl or hermes-gateway.service not available; skipping restart. Restart manually: sudo systemctl restart hermes-gateway.service"
    fi

    log_info "HERMES_API_KEY exported to this shell env; docker compose up -d will inherit it"
}

# ============================================
# Configure skill safety gates
# ============================================
# Hardens AdminLM against agent self-modification of skill files. The
# ~/.hermes/profiles/*/skills/*.md paths are NOT in file_tools' sensitive
# path list (only /etc/, /boot/, /usr/lib/systemd/ are protected), so the
# agent can edit its own skills out of the box. Two gates close this gap:
#
#   skills.write_approval:        Stage agent skill writes to /skills pending
#                                 for human review instead of auto-applying.
#   skills.guard_agent_created:   Security-scan agent-created skills for
#                                 exfiltration, persistence, and destructive
#                                 patterns (tools/skills_guard.py scanner).
#
# Both flags are off by default in upstream Hermes. AdminLM turns them on as
# a baseline so a misbehaving subagent or a prompt-injected agent cannot
# silently rewrite its own instructions. Surfaced 2026-06-27 by review of
# tools/file_tools.py + tools/skills_guard.py.

configure_skill_safety() {
    local hermes_bin
    hermes_bin="$HERMES_HOME/hermes-agent/venv/bin/hermes"

    if [ ! -x "$hermes_bin" ]; then
        log_warn "hermes binary not found at $hermes_bin; skipping skill safety config"
        return 0
    fi

    log_info "Hardening agent skill self-modification gates..."

    "$hermes_bin" config set skills.write_approval true > /dev/null 2>&1 && \
        log_success "skills.write_approval=true (skill writes staged for review)" || \
        log_warn "Could not set skills.write_approval"

    "$hermes_bin" config set skills.guard_agent_created true > /dev/null 2>&1 && \
        log_success "skills.guard_agent_created=true (agent-created skills scanned)" || \
        log_warn "Could not set skills.guard_agent_created"
}

# ============================================
# Install default Profile SOUL.md
# ============================================
# The default Profile's persona lives at $INFRA_DIR/profiles/default/SOUL.md
# (shipped in this repo). Copy it into $HERMES_HOME so the runtime picks it
# up — either alongside the top-level config.yaml (single-profile mode) or
# under profiles/default/ (multi-profile mode). Auto-detect which layout
# the Customer is using by checking for an existing profiles/ directory.
# Falls back to writing to both locations so the install is robust against
# either layout the runtime ends up using.

install_default_profile_soul() {
    local source="$INFRA_DIR/profiles/default/SOUL.md"
    local multi_target_dir multi_target single_target

    if [ ! -f "$source" ]; then
        log_warn "Default profile SOUL.md not found at $source; skipping"
        return 0
    fi

    multi_target_dir="$HERMES_HOME/profiles/default"
    multi_target="$multi_target_dir/SOUL.md"
    single_target="$HERMES_HOME/SOUL.md"

    if [ -d "$HERMES_HOME/profiles" ]; then
        # Multi-profile layout — write to profiles/default/SOUL.md only
        mkdir -p "$multi_target_dir"
        if cp "$source" "$multi_target" 2>/dev/null; then
            log_success "Default profile SOUL.md installed at $multi_target"
        else
            log_warn "Could not install default profile SOUL.md to $multi_target"
        fi
    else
        # Single-profile layout — write to top-level SOUL.md only
        if cp "$source" "$single_target" 2>/dev/null; then
            log_success "Default profile SOUL.md installed at $single_target"
        else
            log_warn "Could not install default profile SOUL.md to $single_target"
        fi
    fi
}

# ============================================
# Install IT_ADMIN specialist Profile
# ============================================
# The IT_ADMIN profile lives at $INFRA_DIR/profiles/it_admin/ and copies
# SOUL.md + skills/*.md into $HERMES_HOME/profiles/it_admin/. IT_ADMIN
# requires multi-profile layout — auto-create $HERMES_HOME/profiles/ if
# absent. Backed by BACKLOG #20. Replaces the retired linux_admin +
# network_admin + windows_admin + vsphere_admin split (BACKLOG #16-19).

install_it_admin_profile_soul() {
    local source_dir="$INFRA_DIR/profiles/it_admin"
    local target_dir="$HERMES_HOME/profiles/it_admin"
    local copied=0

    if [ ! -d "$source_dir" ]; then
        log_warn "IT_ADMIN profile source dir not found at $source_dir; skipping"
        return 0
    fi

    # IT_ADMIN requires multi-profile layout; create profiles/ if absent
    if [ ! -d "$HERMES_HOME/profiles" ]; then
        log_info "Multi-profile layout not detected; creating $HERMES_HOME/profiles/"
        if ! mkdir -p "$HERMES_HOME/profiles" 2>/dev/null; then
            log_warn "Could not create $HERMES_HOME/profiles/; IT_ADMIN install skipped"
            return 0
        fi
    fi

    if ! mkdir -p "$target_dir" 2>/dev/null; then
        log_warn "Could not create $target_dir; IT_ADMIN install skipped"
        return 0
    fi

    # Copy SOUL.md
    if [ -f "$source_dir/SOUL.md" ]; then
        if cp "$source_dir/SOUL.md" "$target_dir/SOUL.md" 2>/dev/null; then
            log_success "IT_ADMIN SOUL.md installed at $target_dir/SOUL.md"
            copied=$((copied + 1))
        else
            log_warn "Could not install $target_dir/SOUL.md"
        fi
    else
        log_warn "IT_ADMIN SOUL.md not found at $source_dir/SOUL.md; skipping"
    fi

    # Copy all skill files from skills/*.md
    if [ -d "$source_dir/skills" ]; then
        mkdir -p "$target_dir/skills"
        local skill_count=0
        local skill_file
        for skill_file in "$source_dir/skills/"*.md; do
            if [ -f "$skill_file" ]; then
                local skill_name
                skill_name=$(basename "$skill_file")
                if cp "$skill_file" "$target_dir/skills/$skill_name" 2>/dev/null; then
                    skill_count=$((skill_count + 1))
                else
                    log_warn "Could not install $target_dir/skills/$skill_name"
                fi
            fi
        done
        if [ "$skill_count" -gt 0 ]; then
            log_success "IT_ADMIN $skill_count skill file(s) installed at $target_dir/skills/"
            copied=$((copied + 1))
        fi
    else
        log_warn "IT_ADMIN skills/ directory not found at $source_dir/skills; skipping"
    fi

    if [ "$copied" -gt 0 ]; then
        log_success "IT_ADMIN profile installed ($copied set(s) of files)"
    fi

    # Inherit provider/model/base_url from default profile so IT_ADMIN
    # uses the same LLM as default. Same pattern as the retired
    # install_linux_admin_profile_soul().
    local default_config="$HERMES_HOME/config.yaml"
    local it_admin_config="$target_dir/config.yaml"
    local default_model default_provider default_base_url

    if [ ! -f "$default_config" ]; then
        log_warn "Default profile config.yaml not found at $default_config; IT_ADMIN will use runtime defaults"
        return 0
    fi

    # Extract model.default, model.provider, model.base_url via awk (handles
    # YAML's nested structure). Falls back to empty string if missing.
    default_model=$(awk '/^model:/{flag=1; next} flag && /^  default:/{print $2; exit}' "$default_config")
    default_provider=$(awk '/^model:/{flag=1; next} flag && /^  provider:/{print $2; exit}' "$default_config")
    default_base_url=$(awk '/^model:/{flag=1; next} flag && /^  base_url:/{print $2; exit}' "$default_config")

    if [ -z "$default_model" ] && [ -z "$default_provider" ]; then
        log_warn "Could not extract model.* from default config.yaml; IT_ADMIN will use runtime defaults"
        return 0
    fi

    # Write IT_ADMIN config.yaml. Only include the fields we extracted —
    # leave the rest of the config (terminal, browser, etc.) to runtime
    # defaults so the profile stays minimal.
    cat > "$it_admin_config" <<EOF
# IT_ADMIN profile config
# Inherited from default profile (model.default, model.provider, model.base_url)
# on $(date -u +%Y-%m-%dT%H:%M:%SZ)
model:
  default: ${default_model}
  provider: ${default_provider}
  base_url: ${default_base_url}
EOF

    log_success "IT_ADMIN config.yaml written with provider=$default_provider model=$default_model"
}

# ============================================
# Build Hermes Dashboard Web UI
# ============================================

build_dashboard_ui() {
    local web_dir="$HERMES_HOME/hermes-agent/web"

    if [ ! -d "$web_dir" ]; then
        log_warn "Hermes Dashboard web UI directory not found at $web_dir, skipping build"
        return 0
    fi

    log_info "Building Hermes Dashboard web UI (Vite)..."
    (cd "$web_dir" && npm install --silent && npm run build) || {
        log_error "Web UI build failed; dashboard will not start"
        return 1
    }
    log_success "Hermes Dashboard web UI built"
    return 0
}

# ============================================
# Generate Hermes Dashboard credentials
# ============================================
# Writes dashboard.basic_auth.username/password/secret into
# ~/.hermes/config.yaml so the basic plugin registers and the auth gate
# is satisfied for the non-loopback bind in install_hermes_dashboard_service.
# Credentials are also saved to /var/log/hermes-bootstrap-credentials.log
# (mode 0600, owned by $HERMES_USER) for the customer to retrieve later —
# they're never stored in plaintext on disk anywhere else.

generate_dashboard_credentials() {
    local dashboard_user="${DASHBOARD_USER:-admin}"
    local dashboard_password dashboard_secret credentials_log
    local hermes_bin config_path

    hermes_bin="$HERMES_HOME/hermes-agent/venv/bin/hermes"
    config_path="$HERMES_HOME/config.yaml"
    credentials_log="/var/log/hermes-bootstrap-credentials.log"

    log_info "Generating Hermes Dashboard credentials for user '$dashboard_user'..."

    # Generate 20-char alphanumeric password (URL-safe-ish, no special chars
    # so it survives bash quoting and config.yaml escaping).
    dashboard_password="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)"
    # Generate 32-byte hex secret for session signing.
    dashboard_secret="$(openssl rand -hex 32)"

    # Persist into config.yaml via the Hermes CLI so we don't have to hand-
    # edit YAML (which risks indentation breakage). The basic plugin reads
    # dashboard.basic_auth.{username,password,secret} from config.yaml on
    # dashboard startup; it hashes the plaintext password in-memory at load
    # time (see plugins/dashboard_auth/basic/register() in hermes-agent).
    if [ ! -x "$hermes_bin" ]; then
        log_error "hermes binary not found at $hermes_bin; cannot write dashboard credentials"
        return 1
    fi

    "$hermes_bin" config set dashboard.basic_auth.username "$dashboard_user" > /dev/null 2>&1 || \
        { log_error "Could not set dashboard.basic_auth.username"; return 1; }
    "$hermes_bin" config set dashboard.basic_auth.password "$dashboard_password" > /dev/null 2>&1 || \
        { log_error "Could not set dashboard.basic_auth.password"; return 1; }
    "$hermes_bin" config set dashboard.basic_auth.secret "$dashboard_secret" > /dev/null 2>&1 || \
        { log_error "Could not set dashboard.basic_auth.secret"; return 1; }

    log_success "Dashboard credentials written to $config_path (basic plugin will register on next dashboard start)"

    # Save the plaintext credentials to a 0600 log so the customer can
    # retrieve them later. /var/log is more durable than $HERMES_HOME (a
    # customer rebuilding their user account leaves /var/log intact).
    sudo install -m 0600 -o "$HERMES_USER" /dev/null "$credentials_log" 2>/dev/null || \
        sudo touch "$credentials_log" && sudo chown "$HERMES_USER" "$credentials_log" && sudo chmod 0600 "$credentials_log"
    cat >> "$credentials_log" <<EOF
# Hermes Dashboard credentials
# Generated by bootstrap.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Save these — they are not stored in plaintext anywhere else.
URL:      http://$(hostname -I | awk '{print $1}'):$HERMES_PORT
Username: $dashboard_user
Password: $dashboard_password
EOF
    sudo chown "$HERMES_USER" "$credentials_log" 2>/dev/null || true
    sudo chmod 0600 "$credentials_log" 2>/dev/null || true

    echo ""
    echo "============================================"
    echo "  HERMES DASHBOARD CREDENTIALS"
    echo "  (saved to $credentials_log, mode 0600)"
    echo "============================================"
    echo "  URL:      http://$(hostname -I | awk '{print $1}'):$HERMES_PORT"
    echo "  Username: $dashboard_user"
    echo "  Password: $dashboard_password"
    echo "============================================"
    echo ""

    # Export so downstream functions can reuse if needed (currently informational).
    export DASHBOARD_PASSWORD="$dashboard_password"
    export DASHBOARD_SECRET="$dashboard_secret"
}

# ============================================
# Install Hermes Dashboard systemd service
# ============================================
# Writes a unit file so the dashboard survives reboots and is supervised by
# systemd. Skipped silently on systems without systemd (e.g. containers).
# The unit reuses the same nohup command as before so behaviour is identical.

install_hermes_dashboard_service() {
    # Detect systemd; bail out quietly on non-systemd systems.
    if [ ! -d /run/systemd/system ] && [ ! -d /etc/systemd/system ]; then
        log_info "systemd not detected; skipping dashboard service install"
        return 0
    fi
    if ! command -v systemctl > /dev/null 2>&1; then
        log_info "systemctl not available; skipping dashboard service install"
        return 0
    fi

    local unit_file="/etc/systemd/system/hermes-dashboard.service"
    local hermes_user="${HERMES_USER:-$USER}"
    local hermes_bin="$HERMES_HOME/hermes-agent/venv/bin/hermes"
    local dashboard_log="$HERMES_HOME/logs/dashboard.log"

    # Ensure log dir exists with correct ownership before writing the unit.
    mkdir -p "$HERMES_HOME/logs"

    # /etc/systemd/system/ is root-owned. bootstrap.sh runs as the install user,
    # so every privileged op needs sudo. cat <<EOF | sudo tee > /dev/null writes
    # the unit and then truncates stdout so we don't contaminate $(...) captures.
    sudo tee "$unit_file" > /dev/null <<EOF
[Unit]
Description=Hermes Agent Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$hermes_user
WorkingDirectory=$HERMES_HOME/hermes-agent
ExecStart=$hermes_bin dashboard --port $HERMES_PORT --host 0.0.0.0 --skip-build
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable hermes-dashboard.service > /dev/null 2>&1 || true
    log_success "Installed systemd unit: hermes-dashboard.service"
}

# ============================================
# Start Hermes Dashboard
# ============================================

start_hermes_dashboard() {
    log_info "Starting Hermes Dashboard on port $HERMES_PORT..."

    # Skip if already running
    if curl -s "http://localhost:$HERMES_PORT" > /dev/null 2>&1; then
        log_success "Hermes Dashboard is already running on port $HERMES_PORT"
        return 0
    fi

    # Prefer systemd (auto-restarts on reboot/crash). Fall back to nohup
    # for non-systemd hosts (containers, minimal VMs).
    if command -v systemctl > /dev/null 2>&1 && sudo test -f /etc/systemd/system/hermes-dashboard.service; then
        log_info "Starting via systemd: hermes-dashboard.service"
        sudo systemctl start hermes-dashboard.service
    else
        log_info "Starting via nohup (systemd not available)"
        mkdir -p "$HERMES_HOME/logs"
        (cd "$HERMES_HOME/hermes-agent" && \
            source venv/bin/activate && \
            nohup hermes dashboard --port "$HERMES_PORT" --host 0.0.0.0 --skip-build \
                > "$HERMES_HOME/logs/dashboard.log" 2>&1 &)
    fi

    # Wait for it to respond
    local retries=30
    while [ $retries -gt 0 ]; do
        if curl -s "http://localhost:$HERMES_PORT" > /dev/null 2>&1; then
            log_success "Hermes Dashboard started on port $HERMES_PORT"
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done

    log_error "Failed to start Hermes Dashboard"
    log_info "Check logs at: $HERMES_HOME/logs/dashboard.log"
    return 1
}

# ============================================
# Install Hermes Gateway systemd service
# ============================================
# Writes a unit file so the hermes-gateway daemon (and therefore every
# Hermes cron job, e.g. AdminLM Dashboard Backup) survives reboots and is
# supervised by systemd. The gateway is the daemon that TICKS scheduled
# jobs — without it, cron entries are registered in jobs.json but never
# fire. See hermes_agent/cron/__init__.py: "Cron jobs are executed
# automatically by the gateway daemon".
#
# We use the system-level install (`hermes gateway install --system`) so
# the unit lives in /etc/systemd/system/hermes-gateway.service and is
# started at multi-user.target boot — independent of any user login.
# This is the right scope for a server (Proxmox VM/CT, bare metal). The
# per-user service (`hermes gateway install`, no --system) only starts on
# user login, so it would not survive a reboot of a headless server.
#
# Modeled on install_hermes_dashboard_service above — same pattern,
# same sudo gymnastics for /etc/systemd/system/.

install_hermes_gateway_service() {
    # Bail out quietly on non-systemd systems (containers, minimal VMs).
    if [ ! -d /run/systemd/system ] && [ ! -d /etc/systemd/system ]; then
        log_info "systemd not detected; skipping gateway service install"
        return 0
    fi
    if ! command -v systemctl > /dev/null 2>&1; then
        log_info "systemctl not available; skipping gateway service install"
        return 0
    fi
    local hermes_bin="$HERMES_HOME/hermes-agent/venv/bin/hermes"
    if [ ! -x "$hermes_bin" ]; then
        log_warn "hermes CLI not found at $hermes_bin; skipping gateway service install"
        return 0
    fi

    local hermes_user="${HERMES_USER:-$USER}"

    # `hermes gateway install --system` writes
    # /etc/systemd/system/hermes-gateway.service, runs `systemctl
    # daemon-reload`, and `systemctl enable hermes-gateway.service`. It
    # does NOT start the service — we do that explicitly below so the
    # gateway is up before install_dashboard_backup_hermes_cron() later
    # registers the cron entry.
    #
    # Refuses to install as root unless --run-as-user is given. Bootstrap
    # runs as the install user (e.g. `ansible` on the Proxmox VM), so
    # --run-as-user is just $USER. If a customer runs bootstrap as root
    # (uncommon — they would have lost docker group on next login), we
    # pass --run-as-user root explicitly to keep the install non-fatal.
    # Tier 2 (BACKLOG #83 follow-on): flip the unit to Type=notify with a
    # 120-second watchdog so systemd's is-active reflects the gateway's
    # sd_notify READY=1, not just "PID exists." Default unit is Type=simple
    # — which considers the service "active" the instant its PID forks,
    # before :8642/:9119 bind. With Type=notify, "service alive but ports
    # not bound" is structurally impossible. BACKLOG #83 confirmed this
    # race on a fresh VM during Step 6 E2E. Set BEFORE the install so the
    # gateway-install CLI emits a notify-type unit; harmless re-runs (the
    # config set is idempotent).
    #
    # Note: the canonical Hermes config key is `gateway.startup_watchdog_timeout_seconds`,
    # not `gateway.systemd_watchdog_seconds`. The CLI prints a "not
    # recognized" warning but still writes the value and the gateway-install
    # path reads it correctly (verified on .220: unit came up as
    # `Type=notify + WatchdogSec=120s + NotifyAccess=main`).
    sudo -n "$hermes_bin" config set gateway.startup_watchdog_timeout_seconds 120 >/dev/null 2>&1 || \
        sudo -n "$hermes_bin" config set gateway.systemd_watchdog_seconds 120 >/dev/null 2>&1 || \
        log_warn "Could not set startup_watchdog_timeout_seconds=120; unit may stay Type=simple"

    if [ ! -f /etc/systemd/system/hermes-gateway.service ]; then
        log_info "Installing hermes-gateway as a system service (user=$hermes_user)..."
        local run_as_flag=()
        if [ "$hermes_user" = "root" ]; then
            run_as_flag=(--run-as-user root)
        else
            run_as_flag=(--run-as-user "$hermes_user")
        fi
        if ! sudo "$hermes_bin" gateway install --system "${run_as_flag[@]}" >/dev/null 2>&1; then
            log_warn "hermes gateway install --system failed; cron jobs will not run automatically"
            log_warn "Retry manually: sudo -E $hermes_bin gateway install --system --run-as-user $hermes_user"
            return 0
        fi
        log_success "Installed systemd unit: hermes-gateway.service (system, user=$hermes_user)"
    else
        log_info "hermes-gateway.service already installed; skipping (use --force to refresh)"
        # Re-emit the unit if it pre-dates the watchdog config (Type=notify
        # only). --force overwrites the existing unit; harmless on re-runs
        # (same content for Type=simple units that were already notify).
        if sudo grep -q '^Type=simple' /etc/systemd/system/hermes-gateway.service 2>/dev/null; then
            log_info "  Refreshing unit to Type=notify (watchdog enabled)..."
            local run_as_flag=()
            if [ "$hermes_user" = "root" ]; then
                run_as_flag=(--run-as-user root)
            else
                run_as_flag=(--run-as-user "$hermes_user")
            fi
            sudo "$hermes_bin" gateway install --system --force "${run_as_flag[@]}" >/dev/null 2>&1 || \
                log_warn "  Unit refresh failed; existing Type=simple unit kept"
        fi
    fi

    # Start the service. Idempotent: `systemctl start` on an already-
    # running service is a no-op. We intentionally do NOT use --no-block;
    # blocking here is fast (the service starts in <2s) and gives us a
    # clear log line on success/failure.
    log_info "Starting hermes-gateway.service..."
    if ! sudo systemctl start hermes-gateway.service; then
        log_warn "Failed to start hermes-gateway.service; cron jobs will not run"
        log_warn "Diagnose with: sudo systemctl status hermes-gateway.service"
        return 0
    fi

    # Verify it's actually running (not just "started but crash-looping").
    # systemctl is-active returns 0 only when the service is up.
    if sudo systemctl is-active --quiet hermes-gateway.service; then
        log_success "Hermes gateway is active (system service; survives reboots)"
    else
        log_warn "hermes-gateway.service is installed but not active; check journalctl -u hermes-gateway"
        return 0
    fi

    # Install-time gate: prove the gateway is actually listening on
    # :8642 + :9119 BEFORE returning. Without this, downstream services
    # (streamlit Agent Chat, MCP servers, cron jobs) can race against
    # the gateway's first-boot bind. The helper retries up to 3x with
    # systemctl restart between attempts. Hit on a fresh VM 2026-09-11
    # — gateway was "active" but ports unbound for ~2 min after start.
    if ! verify_gateway_port_bind "install-time"; then
        log_warn "hermes-gateway port-bind failed after retries; downstream services may not connect"
        # Don't return 1 — bootstrap continues. The verify_installation
        # step at the end of bootstrap will catch this again.
    fi
}

# ============================================
# Install Grafana Skills (grafana-core + grafana-lgtm)
# ============================================

install_grafana_skills() {
    local skills_dir="$HERMES_HOME/skills/grafana"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_info "Installing grafana-core and grafana-lgtm skills from grafana/skills..."

    if ! command -v git &> /dev/null; then
        log_warn "git not available; skipping grafana skills install"
        rm -rf "$tmp_dir"
        return 0
    fi

    if ! git clone --depth 1 --quiet https://github.com/grafana/skills.git "$tmp_dir/grafana-skills" 2>/dev/null; then
        log_warn "Could not clone grafana/skills; skipping skills install"
        rm -rf "$tmp_dir"
        return 0
    fi

    local installed=0
    for plugin in grafana-core grafana-lgtm; do
        if [ ! -d "$tmp_dir/grafana-skills/skills/$plugin" ]; then
            log_warn "Plugin $plugin not found in grafana/skills repo; skipping"
            continue
        fi
        for skill_dir in "$tmp_dir/grafana-skills/skills/$plugin"/*/; do
            [ -d "$skill_dir" ] || continue
            local skill_name
            skill_name=$(basename "$skill_dir")
            if [ -f "$skill_dir/SKILL.md" ]; then
                mkdir -p "$skills_dir/$skill_name"
                cp -r "$skill_dir/." "$skills_dir/$skill_name/"
                log_success "Installed skill: grafana/$skill_name"
                installed=$((installed + 1))
            fi
        done
    done

    rm -rf "$tmp_dir"

    if [ "$installed" -gt 0 ]; then
        log_success "Installed $installed Grafana skill(s) into $skills_dir"
    else
        log_warn "No Grafana skills were installed"
    fi
}

# ============================================
# Create Grafana Service Account for MCP
# ============================================

create_grafana_mcp_service_account() {
    local grafana_url="http://localhost:3000"
    local admin_user="admin"
    local admin_pass="${GRAFANA_PASSWORD:-admin123}"
    local secrets_dir="$HERMES_HOME/secrets"
    local secrets_file="$secrets_dir/grafana-mcp.env"

    log_info "Creating Grafana service account for MCP..."

    # Wait for Grafana to be healthy (up to 60s)
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if curl -sf "${grafana_url}/api/health" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    if [ $attempts -eq 30 ]; then
        log_warn "Grafana not reachable at $grafana_url; skipping SA creation"
        log_warn "Deploy the main stack first (docker compose up -d), then re-run this step"
        return 0
    fi

    # Check if service account + token already exist (idempotent re-runs).
    # The env var name is GRAFANA_SERVICE_ACCOUNT_TOKEN (no _MCP_) because
    # that's what the grafana/mcp-grafana binary actually reads.
    if [ -f "$secrets_file" ] && grep -q "^GRAFANA_SERVICE_ACCOUNT_TOKEN=glsa_" "$secrets_file" 2>/dev/null; then
        log_info "Grafana MCP service account token already exists at $secrets_file"
        # shellcheck disable=SC1090
        set -a; source "$secrets_file"; set +a
        return 0
    fi

    # Create service account. If a SA with this name already exists (from
    # a prior bootstrap run, a manual pre-create, or a re-bootstrap after
    # partial success), Grafana returns 409 Conflict. We detect that case,
    # look up the existing SA's id, and continue to token creation. This
    # makes the function idempotent across re-runs without losing the
    # ability to refresh an expired or missing token.
    local sa_response
    sa_response=$(curl -sf -u "${admin_user}:${admin_pass}" \
        -H "Content-Type: application/json" \
        -X POST "${grafana_url}/api/serviceaccounts" \
        -d '{"name":"adminlm-mcp","role":"Admin","isDisabled":false}' 2>/dev/null) || {
        # 409 conflict path — SA already exists. Look up by name.
        log_info "Service account adminlm-mcp already exists; reusing it"
        sa_response=$(curl -sf -u "${admin_user}:${admin_pass}" \
            "${grafana_url}/api/serviceaccounts/search?query=adminlm-mcp" 2>/dev/null) || {
            log_warn "Could not create OR look up Grafana service account; skipping"
            return 0
        }
    }

    local sa_id
    sa_id=$(echo "$sa_response" | python3 -c "
import json, sys
d = json.load(sys.stdin)
# /api/serviceaccounts POST returns {id, uid, ...}
# /api/serviceaccounts/search returns {serviceAccounts: [{id, name, ...}]}
if isinstance(d, dict) and 'serviceAccounts' in d:
    for sa in d['serviceAccounts']:
        if sa.get('name') == 'adminlm-mcp':
            print(sa.get('id', '')); break
else:
    print(d.get('id', ''))
" 2>/dev/null || echo "")

    if [ -z "$sa_id" ]; then
        log_warn "Service account creation/lookup returned no id; skipping"
        return 0
    fi

    log_info "Using service account id=$sa_id"

    # Create token for the service account. If a token with this name
    # already exists from a prior bootstrap run (whose token value we no
    # longer have because Grafana only returns the key ONCE on creation),
    # Grafana returns 400 ErrTokenAlreadyExists. In that case, revoke the
    # stale token and create a fresh one. We only do this when the env
    # file is missing — if the env file already exists with a valid
    # token, the early-return at the top of this function handles it
    # and we never reach this branch.
    local token_response
    token_response=$(curl -sf -u "${admin_user}:${admin_pass}" \
        -H "Content-Type: application/json" \
        -X POST "${grafana_url}/api/serviceaccounts/${sa_id}/tokens" \
        -d '{"name":"adminlm-mcp-token"}' 2>/dev/null) || {
        log_info "Token 'adminlm-mcp-token' already exists; revoking and recreating"
        # Look up the existing token's id and revoke it.
        local existing_token_id
        existing_token_id=$(curl -sf -u "${admin_user}:${admin_pass}" \
            "${grafana_url}/api/serviceaccounts/${sa_id}/tokens" 2>/dev/null | \
            python3 -c "
import json, sys
for t in json.load(sys.stdin):
    if t.get('name') == 'adminlm-mcp-token':
        print(t.get('id', '')); break
" 2>/dev/null || echo "")
        if [ -z "$existing_token_id" ]; then
            log_warn "Could not look up existing token id; cannot rotate"
            return 0
        fi
        # Revoke the stale token (DELETE returns 204 No Content; -f fails
        # only on 4xx/5xx, so this is fine).
        if ! curl -sf -u "${admin_user}:${admin_pass}" \
            -X DELETE "${grafana_url}/api/serviceaccounts/${sa_id}/tokens/${existing_token_id}" \
            >/dev/null 2>&1; then
            log_warn "Failed to revoke stale token id=$existing_token_id; cannot rotate"
            return 0
        fi
        log_info "Revoked stale token id=$existing_token_id; creating fresh token"
        # Now retry creation.
        token_response=$(curl -sf -u "${admin_user}:${admin_pass}" \
            -H "Content-Type: application/json" \
            -X POST "${grafana_url}/api/serviceaccounts/${sa_id}/tokens" \
            -d '{"name":"adminlm-mcp-token"}' 2>/dev/null) || {
            log_warn "Could not create service account token after revoke; skipping"
            return 0
        }
    }

    local token
    token=$(echo "$token_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('key',''))" 2>/dev/null || echo "")

    if [ -z "$token" ]; then
        log_warn "Token creation returned no key; skipping"
        return 0
    fi

    # Persist token to secrets file. The env var name is
    # GRAFANA_SERVICE_ACCOUNT_TOKEN (no _MCP_) because grafana/mcp-grafana
    # reads that exact var from its environment.
    mkdir -p "$secrets_dir"
    cat > "$secrets_file" <<EOF
# Grafana MCP service account token
# Generated by bootstrap.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Service Account: adminlm-mcp (id: ${sa_id})
# Source: ${grafana_url}/admin/serviceaccounts
GRAFANA_SERVICE_ACCOUNT_TOKEN=${token}
EOF
    chmod 600 "$secrets_file"

    log_success "Grafana service account created (id=${sa_id}); token saved to $secrets_file"
}

# ============================================
# Install Backup Scripts (dashboard backup, etc.)
# ============================================
# Copies script sources from $INFRA_DIR/scripts/ into $HERMES_HOME/scripts/
# and chmods them 0755. Idempotent: skips files that already exist at the
# destination. To force-reinstall, delete the destination file first.
#
# Pre-req: HERMES_HOME must exist (set up by install_hermes) and the SA token
# file must exist at $HERMES_HOME/secrets/grafana-mcp.env (set up by
# create_grafana_mcp_service_account). The adminlm-backup.sh script reads
# that token file at runtime, so install_backup_scripts MUST run after
# create_grafana_mcp_service_account.

install_backup_scripts() {
    local src_dir="$INFRA_DIR/scripts"
    local dest_dir="$HERMES_HOME/scripts"

    if [ ! -d "$src_dir" ]; then
        log_warn "Source scripts dir not found at $src_dir; skipping"
        return 0
    fi

    log_info "Installing backup scripts from $src_dir to $dest_dir..."
    mkdir -p "$dest_dir"

    local installed=0 skipped=0
    # Copy both .sh (shell scripts) and .py (Python helpers). The Python
    # helper install_dashboard_backup_hermes_cron.py edits ~/.hermes/cron/jobs.json
    # and is invoked by the bash function below.
    for src in "$src_dir"/*.sh "$src_dir"/*.py; do
        [ -f "$src" ] || continue
        local name
        name=$(basename "$src")
        local dest="$dest_dir/$name"
        if [ -f "$dest" ]; then
            log_info "  $name already installed; skipping (delete to force reinstall)"
            skipped=$((skipped + 1))
            continue
        fi
        cp "$src" "$dest"
        chmod 0755 "$dest"
        if [ -n "$HERMES_USER" ] && id "$HERMES_USER" &>/dev/null; then
            chown "$HERMES_USER:$HERMES_USER" "$dest" 2>/dev/null || true
        fi
        log_success "  Installed $name"
        installed=$((installed + 1))
    done

    log_success "Backup scripts: installed=$installed skipped=$skipped"
}

# ============================================
# Install Dashboard Backup Cron (Hermes-managed cron)
# ============================================
# Registers a Hermes cron job against the it_admin profile that runs the
# adminlm-backup.sh script daily at 01:00. Replaces the legacy
# /etc/cron.d/adminlm-dashboard-backup system cron (which the Python helper
# removes on first run).
#
# Why Hermes cron over system cron:
#   - Session history + last_status / last_error live in jobs.json; visible via
#     `hermes cron list` instead of having to tail a log file
#   - Optional Telegram delivery when the user configures a messaging service
#     (per Telegram 2026-07-03 — no deliver target set in this installer; user
#     adds it later)
#   - The cron's stored ``profile`` field is metadata only (the scheduler
#     itself runs under the default profile regardless). Future expansion
#     (e.g. a restore-dashboard workflow) can still register additional
#     it_admin-scoped cron jobs as needed.
#
# The shell script (scripts/adminlm-backup.sh) is the workhorse and is
# unchanged. The agent's prompt is a thin wrapper that invokes the script
# and reports the result. See skills/adminlm-backup.md (installed to
# both the it_admin profile AND the default profile by bootstrap) for
# what the agent sees.
#
# Must run AFTER install_backup_scripts (which installs both the shell
# script and the Python helper). The Python helper lives at
# scripts/install_dashboard_backup_hermes_cron.py and is invoked below.

install_dashboard_backup_hermes_cron() {
    local helper="$HERMES_HOME/scripts/install_dashboard_backup_hermes_cron.py"
    if [ ! -x "$helper" ]; then
        log_warn "install_dashboard_backup_hermes_cron.py not found at $helper; skipping"
        log_warn "(install_backup_scripts should have installed it; check that step)"
        return 0
    fi

    # Removing the legacy /etc/cron.d file requires root, so this step
    # uses sudo. Same pattern as the old install_dashboard_backup_cron.
    if [ -f /etc/cron.d/adminlm-dashboard-backup ]; then
        log_info "Removing legacy system cron /etc/cron.d/adminlm-dashboard-backup..."
        if ! sudo rm -f /etc/cron.d/adminlm-dashboard-backup; then
            log_warn "Could not remove legacy cron (sudo failed); remove manually with: sudo rm /etc/cron.d/adminlm-dashboard-backup"
        fi
    fi

    log_info "Registering AdminLM Dashboard Backup as a Hermes cron job (profile=default, daily 01:00)..."
    # The helper handles the jobs.json edit + idempotency + legacy removal.
    # Second arg "default" is legacy/ignored — the helper hardcodes "default"
    # because the cron scheduler runs under the default profile regardless.
    if python3 "$helper" "$HERMES_HOME" default; then
        log_success "Hermes dashboard backup cron installed"
    else
        log_warn "Hermes dashboard backup cron install failed (exit $?); jobs.json may need manual edit"
    fi
}

# BACKLOG #39.6 — register the daily inventory discovery cron.
# install_inventory_discovery_hermes_cron [no args]
# Registers the "AdminLM Inventory Discovery" cron job with Hermes
# (profile=default, daily 02:00). Idempotent — re-running updates the
# existing job in place (matches by name, not id).
# Idempotency + jobs.json edit live in
# scripts/install_inventory_discovery_hermes_cron.py (mirror of the
# install_dashboard_backup_hermes_cron pattern).
install_inventory_discovery_hermes_cron() {
    local helper="$HERMES_HOME/scripts/install_inventory_discovery_hermes_cron.py"
    if [ ! -x "$helper" ]; then
        log_warn "install_inventory_discovery_hermes_cron.py not found at $helper; skipping"
        log_warn "(install_backup_scripts should have installed it; check that step)"
        return 0
    fi
    log_info "Registering AdminLM Inventory Discovery as a Hermes cron job (profile=default, daily 02:00)..."
    # Second arg "default" is legacy/ignored — the helper hardcodes "default"
    # because the cron scheduler runs under the default profile regardless.
    if python3 "$helper" "$HERMES_HOME" default; then
        log_success "Hermes inventory discovery cron installed"
    else
        log_warn "Hermes inventory discovery cron install failed (exit $?); jobs.json may need manual edit"
    fi
}

# BACKLOG #39.7 — end-of-bootstrap kickoff of inventory discovery.
# kickoff_inventory_discovery [no args]
# Runs the inventory discovery ONCE at end of bootstrap, so the customer
# sees the discovered devices in their install summary and the
# regenerate_blackbox + Prom reload chain runs end-to-end before they
# start exploring. Manual kick post-bootstrap: `hermes cron run
# inventory-discovery-it_admin` (the cron registered in #6 is the
# source of truth for the same job).
kickoff_inventory_discovery() {
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local discover_script="$infra_dir/inventory-stack/inventory-discovery/scripts/discover.py"
    if [ ! -x "$discover_script" ]; then
        log_warn "discover.py not found at $discover_script; skipping kickoff discovery"
        log_warn "(the cron will pick this up at 02:00; or run manually:)"
        log_warn "  python3 $discover_script --auto-detect-subnet --timeout 300"
        return 0
    fi
    log_info "Running kickoff inventory discovery (--auto-detect-subnet, 300s timeout)..."
    # Capture output to install log via tee, but don't fail the bootstrap if
    # the kickoff fails (e.g. nmap-discovery container is down, or the
    # customer's network isn't yet reachable). Cron will retry next night.
    if python3 "$discover_script" --auto-detect-subnet --timeout 300 2>&1 | tee -a /tmp/adminlm-kickoff-discovery.log; then
        log_success "Kickoff inventory discovery complete (see /tmp/adminlm-kickoff-discovery.log for details)"
    else
        log_warn "Kickoff inventory discovery returned non-zero (exit ${PIPESTATUS[0]}); cron will retry at 02:00"
    fi
}

# ============================================
# Deploy MCP Stack (grafana-mcp)
# ============================================

deploy_mcp_stack() {
    # INFRA_DIR is set once in main() upfront; this function should not re-clone.
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local mcp_compose="$infra_dir/docker-compose.mcp.yml"

    if [ ! -f "$mcp_compose" ]; then
        log_warn "MCP compose file not found at $mcp_compose; skipping"
        return 0
    fi

    if [ ! -f "$HERMES_HOME/secrets/grafana-mcp.env" ]; then
        log_warn "grafana-mcp.env not found at $HERMES_HOME/secrets/; skipping"
        return 0
    fi

    # Write a .env file next to the compose so the compose can reference
    # ${HERMES_SECRETS_DIR} without hardcoding /home/ansible. This keeps the
    # compose portable across users and $HERMES_HOME values.
    local mcp_env_file="$infra_dir/.env.mcp"
    log_info "Writing MCP compose .env (HERMES_SECRETS_DIR=$HERMES_HOME/secrets)..."
    cat > "$mcp_env_file" <<EOF
HERMES_SECRETS_DIR=$HERMES_HOME/secrets
EOF

    log_info "Deploying MCP stack..."

    # sg docker -c sidesteps the docker-group-not-applied-yet issue that
    # hits the first docker command run in a fresh SSH session after
    # install_docker (usermod -aG docker only takes effect on next login).
    if sg docker -c "docker compose --env-file '$mcp_env_file' -f '$mcp_compose' up -d" 2>&1 | tail -5; then
        log_success "MCP stack deployed (grafana-mcp on port 8000)"
    else
        log_warn "MCP stack deployment failed; continuing"
        return 0
    fi
}

# ============================================
# Deploy Inventory Stack (inventory-mcp + nmap-discovery)
# ============================================

deploy_inventory_stack() {
    # INFRA_DIR is set once in main() upfront.
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local inv_dir="$infra_dir/inventory-stack"
    local inv_compose="$inv_dir/docker-compose.yml"

    if [ ! -f "$inv_compose" ]; then
        log_warn "inventory-stack/docker-compose.yml not found at $inv_compose; skipping"
        return 0
    fi

    log_info "Deploying inventory stack..."

    # sg docker -c sidesteps the docker-group-not-applied-yet issue.
    # Note: only inventory-mcp starts here. nmap-discovery is in the
    # 'discovery' profile and is started separately by start_nmap_discovery()
    # below — see that function for why.
    if sg docker -c "docker compose -f '$inv_compose' up -d" 2>&1 | tail -10; then
        log_success "Inventory stack deployed (inventory-mcp on port 8001)"
    else
        log_warn "Inventory stack deployment failed; continuing"
        return 0
    fi
}

# register_inventory_mcp [profile_name]
# Registers the inventory-mcp MCP server in a Hermes profile's config.yaml.
# Profiles: 'default' (the customer's default Hermes profile) and 'it_admin'
# (the AdminLM specialist IT admin profile). Both profiles get wired in so the
# customer can ask either one about inventory.
#
# Hermes profile paths (verified 2026-06-27 via `hermes profile show <name>`):
#   - default  → ~/.hermes/config.yaml            (the GLOBAL config IS the
#                 default profile's config; ~/.hermes/profiles/default/ is a
#                 dead location Hermes does not read — see BACKLOG #24)
#   - it_admin → ~/.hermes/profiles/it_admin/config.yaml
#                 (named profiles live under ~/.hermes/profiles/<name>/)
#
# For the "default" profile we therefore always write to ~/.hermes/config.yaml,
# regardless of whether the workstation has a ~/.hermes/profiles/ dir. Named
# profiles still use the multi-profile layout when the dir exists, falling back
# to the global config otherwise.
#
# Idempotent — skips if already registered. Also migrates stale inventory-mcp
# blocks accidentally written to ~/.hermes/profiles/default/config.yaml by
# older bootstrap.sh versions (pre-BACKLOG #24) into the global config.
register_inventory_mcp() {
    local profile="${1:-default}"
    local config_path
    local stale_default_config="$HOME/.hermes/profiles/default/config.yaml"

    if [ "$profile" = "default" ]; then
        # The default profile's config IS the global config. Always write here
        # regardless of layout — writing to ~/.hermes/profiles/default/config.yaml
        # is silently ignored by Hermes (BACKLOG #24).
        config_path="$HOME/.hermes/config.yaml"
    elif [ -d "$HOME/.hermes/profiles" ]; then
        # Multi-profile layout for a named profile
        config_path="$HOME/.hermes/profiles/${profile}/config.yaml"
    elif [ -f "$HOME/.hermes/config.yaml" ] || [ -d "$HOME/.hermes" ]; then
        # Single-profile layout fallback
        config_path="$HOME/.hermes/config.yaml"
        profile="default"
    else
        log_error "No Hermes config found at ~/.hermes/ — run bootstrap.sh first?"
        return 1
    fi

    log_info "Registering inventory-mcp in profile '$profile' (config: $config_path)..."

    if [ ! -d "$(dirname "$config_path")" ]; then
        log_warn "Profile dir not found at $(dirname "$config_path") — creating"
        mkdir -p "$(dirname "$config_path")"
    fi

    if [ ! -f "$config_path" ]; then
        log_warn "Profile config not found at $config_path — creating empty config"
        touch "$config_path"
        chmod 600 "$config_path"
    fi

    # Idempotent: skip if already registered (DICT format marker)
    if grep -q '^  inventory-mcp:' "$config_path" 2>/dev/null; then
        log_success "inventory-mcp already registered in profile '$profile'"
    else
        # Backup + append in DICT format (Hermes CLI's tools_config.py:1365 expects
        # a dict, not a list — see BACKLOG #21). DICT format example:
        #   mcp_servers:
        #     inventory-mcp:
        #       url: http://localhost:8001/mcp
        #       transport: streamable-http
        cp "$config_path" "${config_path}.bak"
        cat >> "$config_path" << 'EOF'

mcp_servers:
  inventory-mcp:
    url: http://localhost:8001/mcp
    transport: streamable-http
EOF
        chmod 600 "$config_path"
        log_success "inventory-mcp registered in profile '$profile'"
    fi

    # Migration: if a stale inventory-mcp block was written to the dead
    # ~/.hermes/profiles/default/config.yaml path by an older bootstrap.sh,
    # strip it now so the source of truth is unambiguous.
    if [ "$profile" = "default" ] && [ -f "$stale_default_config" ]; then
        if grep -q '^  inventory-mcp:' "$stale_default_config" 2>/dev/null; then
            cp "$stale_default_config" "${stale_default_config}.bak"
            # Remove the trailing mcp_servers: inventory-mcp: ... block.
            # Use python for a clean YAML-key removal (sed would be fragile with
            # the 2-space indent + nested keys).
            python3 - "$stale_default_config" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Strip the mcp_servers: inventory-mcp: ... block (with leading blank line)
pattern = re.compile(
    r'\n*mcp_servers:\n  inventory-mcp:\n    url: http://localhost:8001/mcp\n    transport: streamable-http\n*$',
    re.MULTILINE
)
new_content = pattern.sub('\n', content).rstrip() + '\n'
with open(path, 'w') as f:
    f.write(new_content)
PYEOF
            chmod 600 "$stale_default_config"
            log_success "Migrated stale inventory-mcp from $stale_default_config to $config_path (BACKLOG #24)"
        fi
    fi
}

# register_grafana_mcp [profile_name]
# Registers the grafana-mcp MCP server in a Hermes profile's config.yaml.
# Grafana MCP exposes 64 tools (dashboard CRUD, datasource queries, alerting,
# user/team/org admin) over streamable-http at http://localhost:8000/mcp.
# Registered for both default and it_admin profiles by main() so a customer
# can ask either profile about Grafana state.
#
# Same Hermes profile path rules as register_inventory_mcp:
#   - default  → ~/.hermes/config.yaml
#   - it_admin → ~/.hermes/profiles/it_admin/config.yaml
# Idempotent — skips if already registered. Does NOT migrate stale entries
# (no known prior bug for grafana-mcp like BACKLOG #24's default-profile issue).
register_grafana_mcp() {
    local profile="${1:-default}"
    local config_path

    if [ "$profile" = "default" ]; then
        config_path="$HOME/.hermes/config.yaml"
    elif [ -d "$HOME/.hermes/profiles" ]; then
        config_path="$HOME/.hermes/profiles/${profile}/config.yaml"
    elif [ -f "$HOME/.hermes/config.yaml" ] || [ -d "$HOME/.hermes" ]; then
        config_path="$HOME/.hermes/config.yaml"
        profile="default"
    else
        log_error "No Hermes config found at ~/.hermes/ — run bootstrap.sh first?"
        return 1
    fi

    log_info "Registering grafana-mcp in profile '$profile' (config: $config_path)..."

    if [ ! -d "$(dirname "$config_path")" ]; then
        log_warn "Profile dir not found at $(dirname "$config_path") — creating"
        mkdir -p "$(dirname "$config_path")"
    fi

    if [ ! -f "$config_path" ]; then
        log_warn "Profile config not found at $config_path — creating empty config"
        touch "$config_path"
        chmod 600 "$config_path"
    fi

    if grep -q '^  grafana-mcp:' "$config_path" 2>/dev/null; then
        log_success "grafana-mcp already registered in profile '$profile'"
        return 0
    fi

    # Append in DICT format (same as inventory-mcp; Hermes CLI tools_config.py:1365
    # expects a dict). If the file already has an mcp_servers: block, append our
    # entry to the END of that block (after any existing entries like inventory-mcp).
    if grep -q '^mcp_servers:' "$config_path" 2>/dev/null; then
        cp "$config_path" "${config_path}.bak"
        python3 - "$config_path" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

# Find mcp_servers: line, then find end of its block (first non-2-space-indented
# line after it that's not blank), insert grafana-mcp entry there.
insert_idx = None
for i, line in enumerate(lines):
    if line.rstrip() == 'mcp_servers:':
        # End of block = first subsequent line that's blank-or-non-indented
        for j in range(i + 1, len(lines)):
            stripped = lines[j].rstrip()
            if stripped == '' or not lines[j].startswith('  '):
                insert_idx = j
                break
        if insert_idx is None:
            insert_idx = len(lines)
        break

if insert_idx is None:
    # mcp_servers: not found despite the grep — shouldn't happen, but append safely
    with open(path, 'a') as f:
        f.write('\nmcp_servers:\n  grafana-mcp:\n    url: http://localhost:8000/mcp\n    transport: streamable-http\n')
else:
    new_entry = ['  grafana-mcp:\n', '    url: http://localhost:8000/mcp\n', '    transport: streamable-http\n']
    out = lines[:insert_idx] + new_entry + lines[insert_idx:]
    with open(path, 'w') as f:
        f.writelines(out)
PYEOF
        chmod 600 "$config_path"
        log_success "grafana-mcp registered in profile '$profile' (merged with existing mcp_servers block)"
    else
        cp "$config_path" "${config_path}.bak"
        cat >> "$config_path" << 'EOF'

mcp_servers:
  grafana-mcp:
    url: http://localhost:8000/mcp
    transport: streamable-http
EOF
        chmod 600 "$config_path"
        log_success "grafana-mcp registered in profile '$profile'"
    fi
}

# install_inventory_discovery_skill
# Copies the inventory-discovery skill (shipped in inventory-stack/) into
# ~/.hermes/skills/inventory-discovery so Hermes can route "inventory X"
# prompts through the discover.py workflow. Idempotent — overwrites on each
# bootstrap run so skill updates ship automatically.
install_inventory_discovery_skill() {
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local src="$infra_dir/inventory-stack/inventory-discovery"
    local dst="$HOME/.hermes/skills/inventory-discovery"

    if [ ! -d "$src" ]; then
        log_warn "inventory-discovery skill source not found at $src; skipping"
        return 0
    fi

    log_info "Installing inventory-discovery skill to $dst..."
    mkdir -p "$dst/scripts"

    # Copy SKILL.md + scripts (overwrite so updates ship automatically)
    cp "$src/SKILL.md" "$dst/SKILL.md"
    cp "$src/scripts/discover.py" "$dst/scripts/discover.py"
    chmod +x "$dst/scripts/discover.py"

    # Lock down perms (skill files shouldn't be world-readable)
    chmod -R u+rwX,go-rwx "$dst"

    log_success "inventory-discovery skill installed (trigger: 'inventory the subnet ...')"
}

# install_default_profile_cron_skills
# Copies profile-scoped skills that are referenced by crons (which run
# under the default profile) into the default profile's skills tree.
#
# Background: the Hermes cron scheduler runs as the default-profile
# process (HERMES_HOME=~/.hermes), so any skill referenced by a cron
# job's ``skills:`` field must be resolvable from the default profile.
# The AdminLM crons (backup, inventory-discovery) currently reference
# their skills by bare name (no profile prefix). The inventory-discovery
# skill is already installed to ~/.hermes/skills/ by
# install_inventory_discovery_skill() above. This function handles the
# backup skill, which lives only at the it_admin profile path.
#
# Idempotent. Skips silently if the source skill or destination tree
# is missing.
install_default_profile_cron_skills() {
    local src_dir="$INFRA_DIR/profiles/it_admin/skills"
    local dst_dir="$HERMES_HOME/skills"

    if [ ! -d "$src_dir" ]; then
        log_warn "it_admin skills source not found at $src_dir; skipping"
        return 0
    fi
    if [ ! -d "$dst_dir" ]; then
        log_warn "default skills dir not found at $dst_dir; skipping"
        return 0
    fi

    local copied=0
    # adminlm-backup is referenced by the backup cron (default profile).
    # Source lives at profiles/it_admin/skills/adminlm-backup.md in the
    # repo; bootstrap's install_it_admin_profile_soul() copies it to
    # ~/.hermes/profiles/it_admin/skills/ but not to ~/.hermes/skills/.
    if [ -f "$src_dir/adminlm-backup.md" ]; then
        cp "$src_dir/adminlm-backup.md" "$dst_dir/adminlm-backup.md"
        chmod u+rwX,go-rwx "$dst_dir/adminlm-backup.md"
        log_success "Default-profile cron skill installed: adminlm-backup"
        copied=$((copied + 1))
    fi

    if [ "$copied" -eq 0 ]; then
        log_info "No default-profile cron skills to install (source missing or already in place)"
    fi
}

# install_inventory_mcp_skill
# Copies the inventory-mcp skill (shipped in inventory-stack/inventory-mcp/)
# into both the default profile's skill tree AND the it_admin specialist
# profile. The MCP server itself is wired by register_inventory_mcp() — this
# function only ships the SKILL.md so the agent knows the tool surface.
# Idempotent — overwrites on each bootstrap run.
install_inventory_mcp_skill() {
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local src="$infra_dir/inventory-stack/inventory-mcp/SKILL.md"
    local default_dst="$HOME/.hermes/skills/inventory-mcp/SKILL.md"
    local it_admin_dst="$HOME/.hermes/profiles/it_admin/skills/inventory-mcp/SKILL.md"

    if [ ! -f "$src" ]; then
        log_warn "inventory-mcp skill source not found at $src; skipping"
        return 0
    fi

    log_info "Installing inventory-mcp skill..."

    # Default profile: ~/.hermes/skills/inventory-mcp/SKILL.md
    mkdir -p "$(dirname "$default_dst")"
    cp "$src" "$default_dst"
    chmod u+rwX,go-rwx "$(dirname "$default_dst")"

    # it_admin specialist profile (BACKLOG #20).
    # If the it_admin profile doesn't exist yet, skip silently — the next
    # install_it_admin_profile_soul() run will create it; the MCP wiring in
    # register_inventory_mcp() will then re-trigger the install. Better than
    # creating the profile dir out of order.
    if [ -d "$HOME/.hermes/profiles/it_admin" ]; then
        mkdir -p "$(dirname "$it_admin_dst")"
        cp "$src" "$it_admin_dst"
        chmod -R u+rwX,go-rwx "$(dirname "$it_admin_dst")"
        log_success "  → default + it_admin"
    else
        log_success "  → default (it_admin profile not yet created; will install on next bootstrap)"
    fi
}

# install_kb_mcp_skill
# Mirrors install_inventory_mcp_skill() for the kb-mcp server (port 8002).
# Same dual-profile install: default + it_admin. Idempotent.
install_kb_mcp_skill() {
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local src="$infra_dir/kb-stack/kb-mcp/SKILL.md"
    local default_dst="$HOME/.hermes/skills/kb-mcp/SKILL.md"
    local it_admin_dst="$HOME/.hermes/profiles/it_admin/skills/kb-mcp/SKILL.md"

    if [ ! -f "$src" ]; then
        log_warn "kb-mcp skill source not found at $src; skipping"
        return 0
    fi

    log_info "Installing kb-mcp skill..."

    # Default profile
    mkdir -p "$(dirname "$default_dst")"
    cp "$src" "$default_dst"
    chmod u+rwX,go-rwx "$(dirname "$default_dst")"

    # it_admin specialist profile (BACKLOG #20)
    if [ -d "$HOME/.hermes/profiles/it_admin" ]; then
        mkdir -p "$(dirname "$it_admin_dst")"
        cp "$src" "$it_admin_dst"
        chmod -R u+rwX,go-rwx "$(dirname "$it_admin_dst")"
        log_success "  → default + it_admin"
    else
        log_success "  → default (it_admin profile not yet created; will install on next bootstrap)"
    fi
}

# start_nmap_discovery
# Starts the nmap-discovery container in the 'discovery' compose profile.
# Idempotent — skips if already running. Requires NET_RAW + NET_ADMIN caps,
# which is why it's opt-in via a separate profile rather than started by
# deploy_inventory_stack() by default.
start_nmap_discovery() {
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local inv_dir="$infra_dir/inventory-stack"
    local inv_compose="$inv_dir/docker-compose.yml"

    if [ ! -f "$inv_compose" ]; then
        log_warn "inventory-stack/docker-compose.yml not found; skipping nmap-discovery"
        return 0
    fi

    # Idempotent: skip if already running
    if command -v docker &> /dev/null && sg docker -c "docker ps --format '{{.Names}}'" 2>/dev/null | grep -q '^nmap-discovery$'; then
        log_success "nmap-discovery already running"
        return 0
    fi

    log_info "Starting nmap-discovery (compose profile 'discovery', requires NET_RAW + NET_ADMIN)..."
    if sg docker -c "docker compose -f '$inv_compose' --profile discovery up -d nmap-discovery" 2>&1 | tail -10; then
        log_success "nmap-discovery started on port 8003 (host-network mode)"
    else
        log_warn "nmap-discovery failed to start; continuing (inventory-mcp still works for CRUD)"
        return 0  # don't fail bootstrap on this
    fi
}

# ============================================
# Deploy KB Stack (kb-mcp)
# ============================================
#
# BACKLOG #30 K2: kb-mcp is a knowledge-base MCP server (SQLite/FTS5) that
# exposes 5 tools (kb_add, kb_search, kb_list, kb_update, kb_delete) plus 2
# bonus tools (kb_add_source, kb_list_sources). Listens on 127.0.0.1:8002.

deploy_kb_stack() {
    # INFRA_DIR is set once in main() upfront.
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local kb_dir="$infra_dir/kb-stack"
    local kb_compose="$kb_dir/docker-compose.yml"

    if [ ! -f "$kb_compose" ]; then
        log_warn "kb-stack/docker-compose.yml not found at $kb_compose; skipping"
        return 0
    fi

    # BACKLOG #47 (sub-item of #30): install SMB/CIFS + NFS client tooling on
    # the AdminLM host so the agent can mount Windows file shares (CIFS) and
    # NFS exports for KB ingestion. cifs-utils provides mount.cifs, nfs-common
    # provides mount.nfs, smbclient is the command-line SMB browser used for
    # share discovery and quick reads. Check via dpkg rather than command -v
    # because mount.{cifs,nfs} live in /sbin and may be off the user's PATH.
    local kb_mount_pkgs=(cifs-utils nfs-common smbclient)
    local missing_mount_pkgs=()
    for pkg in "${kb_mount_pkgs[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            missing_mount_pkgs+=("$pkg")
        fi
    done
    if [ ${#missing_mount_pkgs[@]} -ne 0 ]; then
        log_info "Installing KB mount dependencies: ${missing_mount_pkgs[*]}"
        wait_for_dpkg_lock || return 1
        sudo apt-get update -qq
        wait_for_dpkg_lock || return 1
        sudo apt-get install -y "${missing_mount_pkgs[@]}"
    else
        log_success "KB mount dependencies present: ${kb_mount_pkgs[*]}"
    fi

    log_info "Deploying kb stack..."

    if sg docker -c "docker compose -f '$kb_compose' up -d" 2>&1 | tail -10; then
        log_success "kb stack deployed (kb-mcp on port 8002)"
    else
        log_warn "kb stack deployment failed; continuing"
        return 0
    fi
}

# ============================================
# Deploy v1.0 Customer-Facing Services (BACKLOG #64, Cards 2-6)
# ============================================
#
# The customer-facing services (adminlm-ansible, adminlm-ansible-runner,
# streamlit-ui) live in docker-compose.yml — always deployed with the main
# stack. No opt-in gate, no overlay.
#
# Idempotency: `docker compose ... up -d` is naturally idempotent. It
# skips images that already exist with no context changes, skips recreate
# for services whose config is unchanged, and only restarts containers
# whose env, volumes, or healthcheck actually changed. Re-running
# `bash bootstrap.sh` on a healthy install is a no-op for these services.

deploy_adminlm_ansible_stack() {
    # INFRA_DIR is set once in main() upfront; this function should not re-clone.
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local main_compose="$infra_dir/docker-compose.yml"

    if [ ! -f "$main_compose" ]; then
        log_warn "Main compose not found at $main_compose; skipping adminlm-ansible deploy"
        return 0
    fi

    log_info "Deploying adminlm-ansible (Card 2 — Ansible runtime + runner)..."

    if sg docker -c "docker compose -f '$main_compose' up -d adminlm-ansible adminlm-ansible-runner" 2>&1 | tail -15; then
        log_success "adminlm-ansible stack deployed (Card 2 — ansible + runner on monitoring network)"
    else
        log_warn "adminlm-ansible stack deployment failed; continuing"
        return 0
    fi
}

# Observability stack — the Prometheus / Loki / Grafana / Alloy / Promtail
# / blackbox_exporter services that verify_installation() checks at the end
# of bootstrap. They live in the SAME docker-compose.yml as adminlm-ansible
# + streamlit-ui but were historically deployed by the orchestrator's initial
# setup rather than by bash bootstrap.sh. That left a gap after any
# snapshot rollback + bootstrap: the verify step at the end of bootstrap
# would fail with 'HTTP 000 (expected 200)' for every observability service.
#
# This function fills that gap. It must run BEFORE
# create_grafana_mcp_service_account (which waits up to 60s for Grafana to
# become healthy) so the SA + token creation can succeed.
#
# Idempotency: `docker compose ... up -d` is naturally idempotent. Re-runs
# skip services whose config is unchanged, recreate only containers whose
# env / volumes / healthcheck changed, and rebuild images only if the
# Dockerfile or build context changed. Safe to call on every bootstrap.
#
# HERMES_API_KEY is REQUIRED for streamlit-ui's env interpolation
# (docker-compose.yml uses ${HERMES_API_KEY:?...}). export it the same
# way deploy_streamlit_ui_stack() does — see HERMES_API_KEY handling in
# configure_hermes_api() and provision_api_server_key().
deploy_observability_stack() {
    # INFRA_DIR is set once in main() upfront.
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local main_compose="$infra_dir/docker-compose.yml"

    if [ ! -f "$main_compose" ]; then
        log_warn "Main compose not found at $main_compose; skipping observability deploy"
        return 0
    fi

    log_info "Deploying observability stack (Prometheus / Loki / Grafana / Alloy / Promtail / blackbox_exporter)..."

    # HERMES_API_KEY must be exported so the streamlit-ui service in the
    # same compose file can resolve its ${HERMES_API_KEY:?...} interpolation.
    # Already set by provision_api_server_key() at the top of main() (via
    # export HERMES_API_KEY="$API_SERVER_KEY"), so we just guard here.
    if [ -z "${HERMES_API_KEY:-}" ] && [ -n "${API_SERVER_KEY:-}" ]; then
        export HERMES_API_KEY="$API_SERVER_KEY"
    fi

    # prometheus + loki + grafana + alloy + promtail + alloy-customer + blackbox_exporter.
    # We deliberately do NOT include adminlm-ansible / adminlm-ansible-runner /
    # streamlit-ui here — those are owned by deploy_adminlm_ansible_stack and
    # deploy_streamlit_ui_stack respectively so we can keep them ordered
    # (streamlit-ui needs adminlm-ansible-runner for HMAC-signed POSTs).
    if sg docker -c "docker compose -f '$main_compose' up -d prometheus loki grafana alloy promtail alloy-customer blackbox_exporter" 2>&1 | tail -15; then
        log_success "Observability stack deployed (Prometheus/Loki/Grafana/Alloy/Promtail/blackbox_exporter on monitoring network)"
    else
        log_warn "Observability stack deployment failed; continuing"
        return 0
    fi

    # Wait for Grafana to become healthy before returning. create_grafana_mcp_service_account
    # polls /api/health for 60s but doesn't restart; if we're earlier in the
    # bootstrap flow and observability was just deployed, give it a head
    # start so the SA-creation step succeeds on the first try. Bound at
    # 180s — Loki + Prometheus cold start can take ~90s on a fresh VM.
    log_info "Waiting for Grafana to become healthy (up to 180s)..."
    local attempts=0
    while [ $attempts -lt 90 ]; do
        if curl -sf "http://localhost:3000/api/health" >/dev/null 2>&1; then
            log_success "Grafana is healthy"
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    log_warn "Grafana not yet healthy after 180s; create_grafana_mcp_service_account will retry"
    return 0
}

deploy_streamlit_ui_stack() {
    # INFRA_DIR is set once in main() upfront.
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"
    local main_compose="$infra_dir/docker-compose.yml"

    if [ ! -f "$main_compose" ]; then
        log_warn "Main compose missing; skipping streamlit-ui deploy"
        return 0
    fi

    log_info "Deploying streamlit-ui (Cards 3-6 — customer Streamlit UI)..."

    # streamlit-ui depends on adminlm-ansible-runner being up (HMAC-signed
    # POSTs to it from the Run Playbook page). Docker Compose's
    # depends_on handles that for the full `up -d`, but here we scope
    # to just streamlit-ui. The container will start as soon as the
    # runner's healthcheck reports healthy, regardless of declaration
    # order. If adminlm-ansible-runner isn't up yet, this is a no-op
    # and a second `up -d streamlit-ui` brings it up.
    if sg docker -c "docker compose -f '$main_compose' up -d streamlit-ui" 2>&1 | tail -15; then
        log_success "streamlit-ui deployed (Cards 3-6 — customer UI on port 80)"
    else
        log_warn "streamlit-ui deployment failed; continuing"
        return 0
    fi
}

# register_kb_mcp [profile_name]
# Registers the kb-mcp MCP server in a Hermes profile's config.yaml.
# kb-mcp is the BACKLOG #30 knowledge-base server (SQLite/FTS5) that exposes
# 5 tools (kb_add, kb_search, kb_list, kb_update, kb_delete) over streamable-http
# at http://localhost:8002/mcp. Registered for both default and it_admin profiles
# by main() so a customer can ask either profile about KB entries.
#
# Same Hermes profile path rules as register_inventory_mcp:
#   - default  → ~/.hermes/config.yaml
#                 (the GLOBAL config IS the default profile's config;
#                 ~/.hermes/profiles/default/ is a dead location Hermes does
#                 not read — see BACKLOG #24)
#   - it_admin → ~/.hermes/profiles/it_admin/config.yaml
# Idempotent — skips if already registered. Migrates stale kb-mcp blocks
# accidentally written to ~/.hermes/profiles/default/config.yaml (BACKLOG #24)
# into the global config. If mcp_servers: block already exists (it will, after
# inventory-mcp and grafana-mcp registration), appends the kb-mcp entry to the
# existing block rather than creating a second one.
register_kb_mcp() {
    local profile="${1:-default}"
    local config_path
    local stale_default_config="$HOME/.hermes/profiles/default/config.yaml"

    if [ "$profile" = "default" ]; then
        # The default profile's config IS the global config. Always write here
        # regardless of layout — writing to ~/.hermes/profiles/default/config.yaml
        # is silently ignored by Hermes (BACKLOG #24).
        config_path="$HOME/.hermes/config.yaml"
    elif [ -d "$HOME/.hermes/profiles" ]; then
        # Multi-profile layout for a named profile
        config_path="$HOME/.hermes/profiles/${profile}/config.yaml"
    elif [ -f "$HOME/.hermes/config.yaml" ] || [ -d "$HOME/.hermes" ]; then
        # Single-profile layout fallback
        config_path="$HOME/.hermes/config.yaml"
        profile="default"
    else
        log_error "No Hermes config found at ~/.hermes/ — run bootstrap.sh first?"
        return 1
    fi

    log_info "Registering kb-mcp in profile '$profile' (config: $config_path)..."

    if [ ! -d "$(dirname "$config_path")" ]; then
        log_warn "Profile dir not found at $(dirname "$config_path") — creating"
        mkdir -p "$(dirname "$config_path")"
    fi

    if [ ! -f "$config_path" ]; then
        log_warn "Profile config not found at $config_path — creating empty config"
        touch "$config_path"
        chmod 600 "$config_path"
    fi

    # Idempotent: skip if already registered (DICT format marker)
    if grep -q '^  kb-mcp:' "$config_path" 2>/dev/null; then
        log_success "kb-mcp already registered in profile '$profile'"
    else
        # Append in DICT format (Hermes CLI's tools_config.py:1365 expects a
        # dict, not a list — see BACKLOG #21). If mcp_servers: already exists
        # (it will after inventory-mcp + grafana-mcp), merge into that block.
        # Otherwise append a fresh mcp_servers: block.
        if grep -q '^mcp_servers:' "$config_path" 2>/dev/null; then
            cp "$config_path" "${config_path}.bak"
            python3 - "$config_path" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

# Find mcp_servers: line, then find end of its block (first non-2-space-indented
# line after it that's not blank), insert kb-mcp entry there.
insert_idx = None
for i, line in enumerate(lines):
    if line.rstrip() == 'mcp_servers:':
        # End of block = first subsequent line that's blank-or-non-indented
        for j in range(i + 1, len(lines)):
            stripped = lines[j].rstrip()
            if stripped == '' or not lines[j].startswith('  '):
                insert_idx = j
                break
        if insert_idx is None:
            insert_idx = len(lines)
        break

if insert_idx is None:
    # mcp_servers: not found despite the grep — shouldn't happen, but append safely
    with open(path, 'a') as f:
        f.write('\nmcp_servers:\n  kb-mcp:\n    url: http://localhost:8002/mcp\n    transport: streamable-http\n')
else:
    new_entry = ['  kb-mcp:\n', '    url: http://localhost:8002/mcp\n', '    transport: streamable-http\n']
    out = lines[:insert_idx] + new_entry + lines[insert_idx:]
    with open(path, 'w') as f:
        f.writelines(out)
PYEOF
            chmod 600 "$config_path"
            log_success "kb-mcp registered in profile '$profile' (merged with existing mcp_servers block)"
        else
            cp "$config_path" "${config_path}.bak"
            cat >> "$config_path" << 'EOF'

mcp_servers:
  kb-mcp:
    url: http://localhost:8002/mcp
    transport: streamable-http
EOF
            chmod 600 "$config_path"
            log_success "kb-mcp registered in profile '$profile'"
        fi
    fi

    # Migration: if a stale kb-mcp block was written to the dead
    # ~/.hermes/profiles/default/config.yaml path by an older bootstrap.sh,
    # strip it now so the source of truth is unambiguous.
    if [ "$profile" = "default" ] && [ -f "$stale_default_config" ]; then
        if grep -q '^  kb-mcp:' "$stale_default_config" 2>/dev/null; then
            cp "$stale_default_config" "${stale_default_config}.bak"
            # Remove the trailing mcp_servers: kb-mcp: ... block.
            # Use python for a clean YAML-key removal (sed would be fragile with
            # the 2-space indent + nested keys).
            python3 - "$stale_default_config" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Strip the mcp_servers: kb-mcp: ... block (with leading blank line)
pattern = re.compile(
    r'\n*mcp_servers:\n  kb-mcp:\n    url: http://localhost:8002/mcp\n    transport: streamable-http\n*$',
    re.MULTILINE
)
new_content = pattern.sub('\n', content).rstrip() + '\n'
with open(path, 'w') as f:
    f.write(new_content)
PYEOF
            chmod 600 "$stale_default_config"
            log_success "Migrated stale kb-mcp from $stale_default_config to $config_path (BACKLOG #24)"
        fi
    fi
}

# ============================================
# Auto-Deploy Stack
# ============================================

auto_deploy_stack() {
    log_info "Starting auto-deploy of monitoring stack..."

    # INFRA_DIR is set once in main() upfront.
    local infra_dir="${INFRA_DIR:?INFRA_DIR not set — main() must clone repo first}"

    # Config-as-code: deploy directly from docker-compose.yml.
    # No LLM in the deploy path — the compose file is the single source of truth.
    # Running an agent here previously caused it to "fix" prose-vs-config drift
    # by editing docker-compose.yml on the VM to match hallucinated service lists.
    if [ ! -f "$infra_dir/docker-compose.yml" ]; then
        log_error "docker-compose.yml not found at $infra_dir"
        log_info "Run: cd $infra_dir && docker compose up -d"
        return 1
    fi

    cd "$infra_dir" || return 1

    # Pull images first so a slow mirror doesn't time out the up.
    # sg docker -c sidesteps the docker-group-not-applied-yet issue that
    # hits the first docker command run in a fresh SSH session after
    # install_docker (usermod -aG docker only takes effect on next login).
    if sg docker -c "docker compose pull" 2>&1 | tee /tmp/adminlm_pull.log | tail -5; then
        log_success "Images pulled"
    else
        log_warn "Some images failed to pull; continuing with local cache"
    fi

    if sg docker -c "docker compose up -d" 2>&1 | tee /tmp/adminlm_up.log; then
        log_success "Stack deployed successfully!"
        log_info "Containers:"
        sg docker -c "docker compose ps --format '  {{.Names}}\\t{{.Status}}\\t{{.Ports}}'" || true
    else
        log_error "Stack deployment failed. Retry manually with:"
        log_info "  cd $infra_dir && docker compose up -d"
        return 1
    fi
}
# ============================================
# Verify Installation
# ============================================

# verify_service_health <name> <url> <expected_status>
# Returns 0 if the URL responds with one of the expected HTTP statuses, else 1.
# Treats 302 as success for the Hermes Dashboard (auth gate redirects).
# <expected_status> may be a single code ("200") or pipe-separated list ("200|406").
# Normalizes curl's behavior on SSE/timeout responses (which can produce a
# code that's not exactly 3 digits) to "000".
verify_service_health() {
    local name="$1"
    local url="$2"
    local expected="${3:-200}"
    local code matched c

    code=$(curl -s -o /dev/null --max-time 5 --connect-timeout 3 -w '%{http_code}' "$url" 2>/dev/null)
    # Normalize non-3-digit responses (SSE streams can produce "200" + later
    # timeout-concatenated codes) to "000" so the comparison is meaningful.
    if ! [[ "$code" =~ ^[0-9]{3}$ ]]; then
        code="000"
    fi

    matched=false
    IFS='|' read -ra expected_codes <<< "$expected"
    for c in "${expected_codes[@]}"; do
        if [ "$code" = "$c" ]; then
            matched=true
            break
        fi
    done

    if $matched; then
        if [ "$code" = "302" ] && [ "$name" = "Hermes Dashboard" ]; then
            log_success "  ✓ $name: HTTP $code (auth gate active)"
        else
            log_success "  ✓ $name: HTTP $code"
        fi
        return 0
    else
        log_error "  ✗ $name: HTTP $code (expected $expected)"
        return 1
    fi
}

# list_listening_ports
# Prints the bind address + scope for every known AdminLM port that's
# currently listening. Reads ss(8) output — does not require docker access.
list_listening_ports() {
    local line addr port scope
    while read -r line; do
        # Skip empty lines and headers
        [ -z "$line" ] && continue
        addr=$(echo "$line" | awk '{print $4}')
        [ -z "$addr" ] && continue
        # Extract port (last colon-separated field, strip trailing ] for IPv6)
        port="${addr##*:}"
        port="${port%]}"
        # Filter to known AdminLM ports
        case "$port" in
            514|1514|3000|3100|8000|8001|8002|8003|9090|9119|12345) ;;
            *) continue ;;
        esac
        # Determine scope (public vs localhost-only)
        case "$addr" in
            0.0.0.0:*|"[::]":*) scope="public" ;;
            127.0.0.1:*|"[::1]":*) scope="localhost-only" ;;
            *) scope="other" ;;
        esac
        printf "    %-5s  %-30s  %s\n" "$port" "$addr" "$scope"
    done < <(ss -tlnH 2>/dev/null) | sort -u
}

# print_access_summary
# Prints the customer-facing "Bootstrap Complete!" banner with URLs,
# credentials, listening ports, and a verification hint.
# Reads dashboard creds from /var/log/hermes-bootstrap-credentials.log
# and Grafana creds from $INFRA_DIR/.env (falls back to defaults).
print_access_summary() {
    local host_ip dash_user dash_pass grafana_user grafana_pass gp
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$host_ip" ] && host_ip="localhost"

    dash_user=""
    dash_pass=""
    if [ -f /var/log/hermes-bootstrap-credentials.log ]; then
        dash_user=$(grep '^Username:' /var/log/hermes-bootstrap-credentials.log 2>/dev/null | awk '{print $2}')
        dash_pass=$(grep '^Password:' /var/log/hermes-bootstrap-credentials.log 2>/dev/null | awk '{print $2}')
    fi

    grafana_user="admin"
    grafana_pass="admin123"  # docker-compose default fallback
    if [ -n "$INFRA_DIR" ] && [ -f "$INFRA_DIR/.env" ]; then
        gp=$(grep '^GRAFANA_PASSWORD=' "$INFRA_DIR/.env" 2>/dev/null | cut -d= -f2-)
        [ -n "$gp" ] && grafana_pass="$gp"
    fi

    echo ""
    echo "============================================"
    echo "  Bootstrap Complete!"
    echo "============================================"
    echo ""
    echo "  Access your AdminLM host (http://$host_ip):"
    echo ""
    echo "  📊 Grafana (visualization)"
    echo "     URL:      http://$host_ip:3000"
    echo "     Username: $grafana_user"
    echo "     Password: $grafana_pass"
    echo ""
    echo "  🔒 Hermes Dashboard (chat UI + Agent)"
    echo "     URL:      http://$host_ip:$HERMES_PORT"
    echo "     Username: ${dash_user:-admin}"
    echo "     Password: ${dash_pass:-<not generated yet>}"
    echo ""
    echo "  📈 Monitoring (no auth required)"
    echo "     Prometheus:    http://$host_ip:9090"
    echo "     Loki:          http://$host_ip:3100"
    echo "     Alloy UI:      http://$host_ip:12345"
    echo ""
    echo "  🔧 MCP servers (localhost-only by default)"
    echo "     Inventory MCP: http://localhost:8001/mcp"
    echo "     KB MCP:        http://localhost:8002/mcp"
    echo "     Grafana MCP:   http://localhost:8000/mcp"
    echo ""
    echo "  📝 Verify the LLM is working:"
    echo "     hermes chat -q \"hello!\""
    echo ""
    echo "  🔒 To restrict port $HERMES_PORT to specific IPs:"
    echo "     sudo ufw allow from <your-ip> to any port $HERMES_PORT"
    echo "     sudo ufw enable"
    echo "============================================"
    echo ""
}

# print_customer_facing_post_install
# BACKLOG #64, Card 7: customer-facing post-install summary. Called from
# main() unconditionally now — the customer-facing services always deploy
# with the main stack. Prints:
#   - Streamlit URL (the customer entry point)
#   - Default credentials reminder (bcrypt-hashed from env)
#   - One-line TL;DR of the customer flow (login → Run Playbook → confirm)
#   - Loki label reminder (run_id + stream labels for query)
print_customer_facing_post_install() {
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$host_ip" ] && host_ip="localhost"

    # Pull the customer username/password from the env if set, else fall
    # back to the defaults documented in docker-compose.yml. We do NOT
    # regenerate the password here — that's the customer's first-run
    # responsibility.
    local v1_user="${STREAMLIT_ADMIN_USERNAME:-admin}"
    local v1_pass="${STREAMLIT_ADMIN_PASSWORD:-admin}"
    if [ -n "${STREAMLIT_ADMIN_PASSWORD_HASH:-}" ]; then
        v1_pass="<bcrypt-hashed; set STREAMLIT_ADMIN_PASSWORD in .env>"
    fi

    echo ""
    echo "============================================"
    echo "  Customer-Facing Services (BACKLOG #64)"
    echo "============================================"
    echo ""
    echo "  🌐 Streamlit UI (customer entry point)"
    echo "     URL:      http://$host_ip"
    echo "     Username: $v1_user"
    echo "     Password: $v1_pass"
    echo ""
    echo "  📋 Customer flow (TL;DR):"
    echo "     1. Open the URL above, log in."
    echo "     2. Pick a page: Home / Settings / Run Playbook / Run History"
    echo "        / Agent Chat / KB Search / Inventory Search."
    echo "     3. To run a playbook: select file → check mode → Confirm"
    echo "        in the UI (the human click is the trust boundary;"
    echo "        the agent never runs ansible-playbook directly)."
    echo ""
    echo "  📊 Loki query labels (Grafana → Explore → Loki):"
    echo "     Ansible runs:   {job=\"adminlm-ansible\"}"
    echo "     Streamlit UI:   {job=\"adminlm-streamlit\"}"
    echo "     Per-run query:  {job=\"adminlm-ansible\", run_id=\"<uuid>\"}"
    echo "     UI events:      {stream=\"streamlit|chat|kb|inventory\"}"
    echo ""
    echo "  🔄 Re-deploy (idempotent — no rebuild on healthy state):"
    echo "     cd ~/adminlm"
    echo "     docker compose up -d"
    echo "============================================"
    echo ""
}

verify_installation() {
    log_info "Verifying installation..."
    local errors=0

    # Tool checks
    if ! command -v docker &> /dev/null; then
        log_error "Docker not found"
        errors=$((errors + 1))
    else
        log_success "Docker: $(docker --version)"
    fi

    if docker compose version &> /dev/null 2>&1 || command -v docker-compose &> /dev/null; then
        log_success "Docker Compose: available"
    else
        log_error "Docker Compose not found"
        errors=$((errors + 1))
    fi

    if [ -f "$HERMES_HOME/hermes-agent/venv/bin/hermes" ]; then
        log_success "Hermes: installed"
    else
        log_error "Hermes not found"
        errors=$((errors + 1))
    fi

    if [ -f "$HERMES_HOME/.env" ]; then
        log_success "API key: configured"
    else
        log_warn "API key: not configured"
    fi

    # LLM plumbing smoke test — confirms the API key + provider + model all
    # work end-to-end. A passing "hello!" means Hermes can talk to the LLM.
    if command -v hermes &>/dev/null || [ -x "$HERMES_HOME/hermes-agent/venv/bin/hermes" ]; then
        log_info "LLM smoke test (hermes chat -q \"hello!\")..."
        local hermes_bin="$HERMES_HOME/hermes-agent/venv/bin/hermes"
        [ ! -x "$hermes_bin" ] && hermes_bin="$(command -v hermes)"
        local hello_response
        hello_response=$(timeout 30 "$hermes_bin" chat -q "hello!" 2>&1 | head -c 200 || true)
        if [ -n "$hello_response" ] && ! echo "$hello_response" | grep -qiE 'error|exception|401|unauthorized|api key'; then
            log_success "  ✓ LLM responds to \"hello!\""
        else
            log_warn "  ! LLM smoke test inconclusive (response: ${hello_response:0:80})"
        fi
    fi

    # Service health checks — only if docker compose is actually running
    if command -v docker &> /dev/null && sg docker -c 'docker ps --format "{{.Names}}"' &>/dev/null; then
        log_info "Checking service health..."
        verify_service_health "Prometheus"      "http://localhost:9090/-/ready"            "200"    || errors=$((errors+1))
        verify_service_health "Loki"            "http://localhost:3100/ready"              "200"    || errors=$((errors+1))
        verify_service_health "Grafana"         "http://localhost:3000/api/health"         "200"    || errors=$((errors+1))
        verify_service_health "Alloy"           "http://localhost:12345/-/ready"           "200"    || errors=$((errors+1))
        # MCP servers return 406 (Not Acceptable) to a bare GET because they
        # expect Accept: text/event-stream + a POST with initialize. 200 means
        # the SSE stream opened; 406 means the endpoint exists. Either is OK.
        verify_service_health "Inventory MCP"   "http://localhost:8001/mcp"                "200|406" || errors=$((errors+1))
        verify_service_health "Grafana MCP"     "http://localhost:8000/mcp"                "200|406" || errors=$((errors+1))
        verify_service_health "Hermes Dashboard" "http://localhost:$HERMES_PORT/"          "302"    || errors=$((errors+1))
        # BACKLOG #66 — streamlit + the customer-facing services that PR #41
        # folded into the default install. Also probe the Hermes API server
        # that Agent Chat depends on (port 8642, bearer-token auth).
        verify_service_health "Streamlit UI"    "http://localhost:80/_stcore/health"    "200"    || errors=$((errors+1))
        # BACKLOG #65 — ansible-runner /health probe. The runner listens on
        # 8000 INSIDE the monitoring network but has NO host port mapping
        # (intentional — streamlit talks to it via adminlm-ansible-runner:8000
        # on the docker network, no host exposure needed). We probe it from
        # the host via `docker exec python3 -c "urllib..."` since the runner
        # image is minimal (no curl/wget; just python:3.12-slim + tini +
        # fastapi/uvicorn/docker/httpx). The runner's /health returns 200
        # iff the adminlm-ansible container is reachable via the docker
        # socket — catching both runner-down AND ansible-container-down.
        local runner_code
        runner_code=$(sg docker -c "docker exec adminlm-ansible-runner python3 -c 'import urllib.request,urllib.error,sys
try:
    r=urllib.request.urlopen(\"http://127.0.0.1:8000/health\",timeout=5)
    sys.stdout.write(str(r.status))
except urllib.error.HTTPError as e:
    sys.stdout.write(str(e.code))
except Exception:
    sys.exit(1)' 2>/dev/null" || echo "000")
        if [ "$runner_code" = "200" ]; then
            log_success "  ✓ Ansible Runner (Run Playbook backend): HTTP 200"
        elif [ "$runner_code" = "503" ]; then
            log_warn "  ✗ Ansible Runner: HTTP 503 (degraded — adminlm-ansible container not reachable via docker socket; check 'docker ps | grep adminlm-ansible')"
            errors=$((errors+1))
        else
            log_warn "  ✗ Ansible Runner: HTTP $runner_code (expected 200; check 'docker ps | grep adminlm-ansible-runner' and runner logs at /home/ansible/.hermes/logs/adminlm-ansible/runner.log)"
            errors=$((errors+1))
        fi
        # Hermes API server: 200 with key, 401 without. We pass the key from
        # the env (provision_api_server_key exported it earlier in main()).
        local api_code
        api_code=$(curl -s -o /dev/null --max-time 5 --connect-timeout 3 \
            -w '%{http_code}' \
            -H "Authorization: Bearer ${HERMES_API_KEY:-no-key-set}" \
            http://localhost:8642/v1/models 2>/dev/null)
        if [ "$api_code" = "200" ]; then
            log_success "  ✓ Hermes API server (Agent Chat): HTTP 200"
        else
            log_warn "  ✗ Hermes API server (Agent Chat): HTTP $api_code (expected 200; check API_SERVER_KEY in ~/.hermes/.env and api_server.host: 0.0.0.0 in ~/.hermes/config.yaml)"
            errors=$((errors+1))
        fi
        # Verify the streamlit container actually has HERMES_API_KEY (not
        # just that the gateway is up). Catches the case where bootstrap
        # ran but HERMES_API_KEY wasn't exported at docker compose up time.
        local streamlit_key
        streamlit_key=$(sg docker -c "docker exec streamlit-ui sh -c 'echo \"\${HERMES_API_KEY:-empty}\"'" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$streamlit_key" ] && [ "$streamlit_key" != "empty" ] && [ "${#streamlit_key}" -ge 16 ]; then
            log_success "  ✓ Streamlit HERMES_API_KEY: set (len=${#streamlit_key})"
        else
            log_warn "  ✗ Streamlit HERMES_API_KEY: ${streamlit_key:-empty} — Agent Chat will fail. Re-run: docker compose up -d streamlit-ui with HERMES_API_KEY in env."
            errors=$((errors+1))
        fi
        # BACKLOG #67 — Run Playbook "playbook not found" smoke check.
        # Verify the adminlm-ansible container can resolve the same playbook
        # paths that the streamlit picker would surface. Catches bind-mount
        # misconfigurations (where streamlit sees /ansible/playbooks/X but
        # adminlm-ansible sees a different tree) before the operator hits
        # "Confirm" in the UI.
        local playbook_smoke
        playbook_smoke=$(sg docker -c "docker exec adminlm-ansible ls /ansible/playbooks/generated/_adminlm_ping.yml" 2>/dev/null)
        if [ -n "$playbook_smoke" ] && [ "$(echo "$playbook_smoke" | tr -d '[:space:]')" = "/ansible/playbooks/generated/_adminlm_ping.yml" ]; then
            log_success "  ✓ Run Playbook smoke: /ansible/playbooks/generated/_adminlm_ping.yml visible to adminlm-ansible"
        else
            log_warn "  ✗ Run Playbook smoke: ping playbook not visible inside adminlm-ansible container (got: $playbook_smoke). Run Playbook will fail 'not found'."
            errors=$((errors+1))
        fi

        log_info "Listening ports (AdminLM services):"
        list_listening_ports || true
    else
        log_warn "Docker not running; skipping service health checks"
    fi

    # Hermes gateway is a systemd service, not an HTTP endpoint, so it
    # doesn't fit verify_service_health() (which curls a URL). Check its
    # systemd state directly. Without the gateway running, every Hermes
    # cron job (e.g. AdminLM Dashboard Backup) is inert — see
    # install_hermes_gateway_service for context. The check runs
    # independently of the docker block above: a healthy gateway matters
    # even on a host where docker is down.
    if command -v systemctl >/dev/null 2>&1 && sudo test -f /etc/systemd/system/hermes-gateway.service 2>/dev/null; then
        log_info "Checking hermes-gateway.service status..."
        # Tier 1 (BACKLOG #83 follow-on): port-bind probe with restart
        # fallback. Same helper used at install-time. One-shot helper
        # call here — does up to 3 attempts with systemctl restart
        # between failures. If the helper returns non-zero, surface as
        # a verify_installation failure (don't auto-fix silently —
        # operators want to know).
        if verify_gateway_port_bind "verify-time"; then
            log_success "  ✓ Hermes Gateway: active and :8642/:9119 bound"
        else
            log_error "  ✗ Hermes Gateway: installed but not healthy (unit not active OR ports not bound)"
            log_info "    Diagnose: sudo systemctl status hermes-gateway.service"
            log_info "    Logs:    sudo journalctl -u hermes-gateway.service -n 50"
            errors=$((errors+1))
        fi
    else
        log_warn "  ! Hermes Gateway: system service not installed (cron jobs will not run automatically)"
    fi

    if [ $errors -eq 0 ]; then
        log_success "All checks passed!"
    else
        log_warn "$errors check(s) failed"
    fi

    return $errors
}

# ============================================
# Main
# ============================================

main() {
    # Resolve provider/model (CLI or interactive)
    resolve_provider_model
    
    echo ""
    echo "============================================"
    echo "  Hermes Infrastructure Bootstrap v2.1"
    echo "============================================"
    echo ""
    echo "  Provider: $PROVIDER"
    echo "  Model: ${MODEL:-default}"
    echo "  Auto-deploy: $AUTO_DEPLOY"
    echo ""

    check_prerequisites
    install_docker
    install_docker_compose
    install_hermes

    # Clone the infrastructure repo once, upfront, before anything else needs it.
    # This guarantees $INFRA_DIR is set for every downstream function regardless
    # of the order they're called in. Functions below should use $INFRA_DIR
    # directly rather than re-calling clone_infra_repo().
    INFRA_DIR="$(clone_infra_repo)"
    export INFRA_DIR

    configure_hermes_api
    provision_api_server_key
    configure_skill_safety
    install_default_profile_soul
    install_it_admin_profile_soul
    build_dashboard_ui
    generate_dashboard_credentials
    install_hermes_dashboard_service
    start_hermes_dashboard

    # Install the gateway as a system service so the cron scheduler daemon
    # survives reboots. Must run before install_dashboard_backup_hermes_cron
    # below so the gateway is up when the AdminLM Dashboard Backup cron
    # entry is first registered and on every subsequent 01:00 tick. See
    # install_hermes_gateway_service for the full rationale.
    install_hermes_gateway_service

    if [ "$AUTO_DEPLOY" = true ]; then
        auto_deploy_stack
    else
        log_info "Skipping auto-deploy (--no-auto-deploy)"
        log_info "To deploy manually, run:"
        log_info "  cd ~/adminlm && docker compose up -d"
    fi

    # Post-install steps: skills install, MCP service account, MCP deploy.
    # deploy_observability_stack MUST run before create_grafana_mcp_service_account
    # so Grafana is reachable when the SA creation polls /api/health. Without
    # it, the SA-creation step skips with a warning and the grafana-mcp.env
    # file is never written — leaving grafana-mcp unstartable and the
    # final verify_installation step showing 'Grafana MCP: HTTP 000'.
    deploy_observability_stack
    install_grafana_skills
    create_grafana_mcp_service_account

    # Backup scripts depend on the Grafana SA token file existing, and the
    # dashboard backup cron depends on the script being installed. Wire them
    # in order right after create_grafana_mcp_service_account.
    install_backup_scripts
    # Cron skills live in the default profile tree (HERMES_HOME/skills/)
    # because the cron scheduler runs as the default profile. Install
    # them BEFORE registering the cron jobs so the skill references in
    # jobs.json resolve cleanly.
    install_default_profile_cron_skills
    install_dashboard_backup_hermes_cron

    # Inventory discovery cron: daily 02:00, profile=default, runs all 3
    # steps (discover + regenerate_blackbox + Prom reload) in one tick.
    # Wire after install_dashboard_backup_hermes_cron so the helper pattern
    # is consistent.
    install_inventory_discovery_hermes_cron

    deploy_mcp_stack
    deploy_inventory_stack

    # Wire inventory-mcp into both the customer's default Hermes profile and
    # the AdminLM it_admin specialist profile, then start nmap-discovery so a
    # customer can immediately ask Hermes to discover/inventory their network
    # without re-running register_inventory_mcp.sh by hand.
    register_inventory_mcp "default"
    register_inventory_mcp "it_admin"
    # Grafana MCP awareness for it_admin — registers grafana-mcp alongside
    # inventory-mcp in it_admin's profile config so both MCP server names
    # exist (are visible to the LLM in the prompt). Default profile gets
    # grafana-mcp too for symmetry with the inventory pattern; remove the
    # default line if you only want it_admin aware.
    register_grafana_mcp "default"
    register_grafana_mcp "it_admin"
    install_inventory_discovery_skill
    install_inventory_mcp_skill
    start_nmap_discovery

    # BACKLOG #30 K2: deploy the kb-mcp knowledge-base server and wire it
    # into both default and it_admin profiles. kb-mcp is the SQLite/FTS5
    # server on port 8002 (5 required tools + 2 bonus).
    deploy_kb_stack
    register_kb_mcp "default"
    register_kb_mcp "it_admin"
    install_kb_mcp_skill

    # BACKLOG #64, Card 7: customer-facing services. Both deploy functions
    # run unconditionally — these services ship with the main stack. Order
    # matters: adminlm-ansible (Card 2) MUST come up before streamlit-ui
    # (Card 3) so the Run Playbook page's HMAC-signed POSTs have a live
    # runner to talk to.
    deploy_adminlm_ansible_stack
    deploy_streamlit_ui_stack

    # Print customer-facing access summary (URLs, credentials, ports, hints)
    print_access_summary

    # Write VERSION sentinel so the next bootstrap run can detect installed-vs-shipped mismatch.
    # Only writes when this script was invoked from a checkout that carries a VERSION file
    # (SHIPPED_VERSION is non-empty, set in the top-of-file sentinel block).
    if [[ -n "$SHIPPED_VERSION" ]]; then
        echo "$SHIPPED_VERSION" > "$INSTALLED_VERSION_FILE"
        log_success "Wrote AdminLM $SHIPPED_VERSION to $INSTALLED_VERSION_FILE"
    fi

    # Customer-facing post-install print (Streamlit URL, creds reminder,
    # flow TL;DR, Loki labels). Called after print_access_summary so the
    # customer's terminal shows the main monitoring stack first, then the
    # customer-facing services.
    print_customer_facing_post_install

    # Run the kickoff inventory discovery so the customer sees devices in
    # their install summary and the blackbox + Prom chain runs end-to-end
    # before they start exploring. Non-fatal — cron will retry at 02:00.
    kickoff_inventory_discovery

    verify_installation
}

main "$@"