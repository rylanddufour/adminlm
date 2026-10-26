#!/bin/bash
# Standalone infisical-mcp registration. Mirrors the register_kb_mcp()
# helper in bootstrap.sh for users who want to wire infisical-mcp into a
# profile without re-running the full bootstrap. Idempotent.
#
# BACKLOG #94 Phase 5 — infisical-mcp first cut. Registers the MCP server
# in the it_admin Hermes profile so the agent can call the three read-only
# tools (get_secret, list_paths, list_systems).
#
# Default profile is NOT registered on purpose — infisical-mcp is an
# IT_OPERATOR concern (the operator model is the agent that acts on the
# customer's IT systems); the default customer-facing profile shouldn't
# have vault access by default. Operators can explicitly register it for
# additional profiles by passing the profile name as $1.
set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <profile_name> [profile_name ...]"
    echo "Example: $0 it_admin"
    echo "  (registers infisical-mcp in the it_admin profile; loopback-only)"
    exit 1
fi

PROFILES=("$@")

# BACKLOG #24: the default profile's config IS the global ~/.hermes/config.yaml.
# ~/.hermes/profiles/default/config.yaml is a dead location Hermes ignores.
config_path_for() {
    local profile="$1"
    if [ "$profile" = "default" ]; then
        echo "$HOME/.hermes/config.yaml"
    else
        echo "$HOME/.hermes/profiles/${profile}/config.yaml"
    fi
}

# register_for_profile <profile>
# Adds the infisical-mcp block to the profile's config.yaml. Idempotent —
# skips if already registered. Merges with existing mcp_servers block if
# one is present (it will be — inventory-mcp + kb-mcp + grafana-mcp are
# already there by the time Phase 5 ships).
register_for_profile() {
    local profile="$1"
    local config_path
    config_path=$(config_path_for "$profile")

    mkdir -p "$(dirname "$config_path")"
    [ -f "$config_path" ] || touch "$config_path"

    # Idempotent: skip if already registered (DICT format marker).
    if grep -q '^  infisical-mcp:' "$config_path" 2>/dev/null; then
        echo "infisical-mcp already registered in profile '$profile' ($config_path)"
        return 0
    fi

    # Append in DICT format (Hermes CLI's tools_config.py expects a dict).
    # If mcp_servers: already exists (it will), merge into that block —
    # otherwise append a fresh mcp_servers: block.
    if grep -q '^mcp_servers:' "$config_path" 2>/dev/null; then
        cp "$config_path" "${config_path}.bak"
        python3 - "$config_path" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

# Find mcp_servers: line, then find end of its block (first non-2-space-indented
# line after it that's not blank), insert infisical-mcp entry there.
insert_idx = None
for i, line in enumerate(lines):
    if line.rstrip() == 'mcp_servers:':
        for j in range(i + 1, len(lines)):
            stripped = lines[j].rstrip()
            if stripped == '' or not lines[j].startswith('  '):
                insert_idx = j
                break
        if insert_idx is None:
            insert_idx = len(lines)
        break

if insert_idx is None:
    # mcp_servers: not found despite the grep — shouldn't happen, but append safely.
    with open(path, 'a') as f:
        f.write(
            '\nmcp_servers:\n'
            '  infisical-mcp:\n'
            '    url: http://localhost:8003/mcp\n'
            '    transport: streamable-http\n'
        )
else:
    new_entry = [
        '  infisical-mcp:\n',
        '    url: http://localhost:8003/mcp\n',
        '    transport: streamable-http\n',
    ]
    out = lines[:insert_idx] + new_entry + lines[insert_idx:]
    with open(path, 'w') as f:
        f.writelines(out)
PYEOF
        chmod 600 "$config_path"
        echo "infisical-mcp registered in profile '$profile' (merged with existing mcp_servers block) [$config_path]"
    else
        cp "$config_path" "${config_path}.bak"
        cat >> "$config_path" << 'EOF'

mcp_servers:
  infisical-mcp:
    url: http://localhost:8003/mcp
    transport: streamable-http
EOF
        chmod 600 "$config_path"
        echo "infisical-mcp registered in profile '$profile' [$config_path]"
    fi
}

for p in "${PROFILES[@]}"; do
    register_for_profile "$p"
done
