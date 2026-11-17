# Security Policy

## Reporting Vulnerabilities

If you find a security vulnerability in this project, please report it responsibly. Do not open a public issue — instead, contact the maintainer directly.

---

## Security Best Practices

### Before Running the Bootstrap

1. **Review the script** — Always read `bootstrap.sh` before running it on your system:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/rylanddufour/adminlm/main/bootstrap.sh | less
   ```

2. **Understand what it does** — The script installs:
   - Docker and Docker Compose
   - Hermes Agent
   - MCP servers (optional)
   - Custom skills

3. **Run as non-root** — The script warns against running as root. Use a regular user with sudo access.

### Secrets and Credentials

AdminLM handles **two distinct kinds of secret**, stored differently on purpose.

|  | Customer IT secrets | AdminLM service credentials |
|---|---|---|
| **Examples** | Windows admin passwords, SSH keys, Active Directory service-account passwords, vendor API tokens | Grafana admin password, Loki S3 keys, MCP server tokens |
| **Where they live** | A self-hosted [Infisical](https://infisical.com) vault running on the AdminLM host | Protected files under `~/.hermes/secrets/` on the AdminLM host |
| **Who manages them** | You, through the **Secrets** page in the AdminLM dashboard | The install process |
| **Who reads them** | You — and the AdminLM agent, read-only and path-scoped | AdminLM services, at boot time |

**Customer IT secrets are never hardcoded in this repo.** They live only in the vault, and reach the agent at call time. The operator-facing guide is the *AdminLM Secrets* user guide, in your documentation vault alongside the *AdminLM Dashboard* guide.

#### Two credentials, one vault

- **Operator credential** — what the Secrets page uses. Read and write.
- **Agent credential** — what the agent's vault connector uses. **Read-only**, scoped to specific paths.

The agent credential can list and read secrets under the paths it has been granted, and nothing else. It cannot create, edit, delete, or rotate. There is no override, no confirmation queue, and no privileged mode — the restriction is enforced in the vault's role model, not by convention. A prompt-injection attack that fully controls the agent cannot turn it into a writer.

If the agent credential is ever suspected to be compromised, revoke it from the Secrets page and mint a new one. Operator access is unaffected.

#### Encryption at rest

Every secret in the vault is encrypted with AES-256 before it is written to disk. The encryption key is generated during install, stored in a protected file on the host, and never leaves the host in plaintext. The vault's web interface binds to `127.0.0.1` and is not reachable from your network.

#### Backups

The nightly backup captures the vault database **and** its encryption key, so a restored host comes back with every customer secret intact.

In v1.0 the encryption key inside the backup file is **plain text**. The backup archive is only as protected as wherever you store it — encrypt the backup target itself (rclone-crypt, restic, an encrypted NAS volume). A future release adds an opt-in second layer that encrypts the vault dump inside the archive.

> Treat backup archives as secrets. They contain the complete customer credential set.

#### Audit log

Vault access is recorded: which principal, which operation, which path, which secret key, success or failure. **Secret values are never written to the log.** The log answers *"who touched what"* — never *"what did they read"*.

#### Still true

- **Never hardcode secrets in this repo.**
- API tokens, passwords, and keys should be set via environment variables
- Use read-only tokens where possible (especially for GitHub MCP)

Example:
```bash
# Set environment variables before running
export GITHUB_PERSONAL_ACCESS_TOKEN=ghp_xxxx
export POSTGRES_MCP_DATABASE_URI=postgresql://user:***@host:5432/db
```

### MCP Servers

- MCP servers run inside Docker containers with limited permissions
- Only enable the MCP servers you need
- Review the docker-compose file and restrict network access as needed
- Do not expose MCP servers to the public internet without authentication

### Skill Self-Modification Protection

AdminLM hardens the Hermes agent against editing its own skill files. Out of the box, `~/.hermes/profiles/*/skills/*.md` is **not** in `file_tools._SENSITIVE_PATH_PREFIXES` (only `/etc/`, `/boot/`, `/usr/lib/systemd/`, etc. are), so a prompt-injected or misbehaving agent can rewrite its own instructions.

`bootstrap.sh` `configure_skill_safety()` (called from `main()` after `configure_hermes_api`) sets two flags in `~/.hermes/config.yaml`:

- `skills.write_approval: true` — agent skill writes are staged to `/skills pending` for human review via `tools/write_approval.py:253` instead of auto-applying.
- `skills.guard_agent_created: true` — agent-created skills are scanned by `tools/skills_guard.py` for exfiltration, prompt injection, destructive commands, and persistence patterns before install.

Both flags are off by default in upstream Hermes. AdminLM turns them on as a baseline. See the *Skill Safety Gates* design doc in your documentation vault for the full design and the reasoning behind each flag.

### SSH Access

- The bootstrap expects SSH key-based authentication
- Keep your private keys secure and never commit them to version control
- Use dedicated deploy keys or machine-specific keys

---

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | ✅ Current |

---

## Contact

For security concerns, please contact the repository maintainer directly. Do not post security issues in public issues or discussions.