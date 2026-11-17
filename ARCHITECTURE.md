# AdminLM Architecture Reference

## Secrets

Customer IT credentials — Windows admin passwords, SSH keys, Active Directory service-account passwords, vendor API tokens — live in a self-hosted [Infisical](https://infisical.com) OSS vault that runs on the AdminLM host alongside the rest of the stack. One vault, two surfaces:

```
Operator ──► AdminLM dashboard (Secrets page) ──► Infisical ◄── IT_ADMIN agent
   operator credential                              read-only, path-scoped
   (read / write)                                  credential
```

- **Operator surface** — the Secrets page in the dashboard. Lists, reveals, adds, edits, and deletes secrets. Uses the operator credential, which has read/write access to the vault.
- **Agent surface** — `infisical-mcp`, a read-only MCP server registered in the `it_admin` profile only. It exposes exactly three tools: `get_secret`, `list_paths`, `list_systems`. Its credential is a separate machine identity with the viewer role, scoped to read-only on specific paths. It cannot write, and there is no override, no confirmation queue, no privileged mode.

The vault's web interface binds to `127.0.0.1:8090` and is never exposed to the customer network. The customer never opens the Infisical UI — the dashboard is the only operator-facing surface.

AdminLM's **own** service credentials are not in the vault. They stay in `~/.hermes/secrets/<service>.env` and are read at boot time by the service that needs them. Migrating them is explicitly out of scope.

### Data at rest and backup

Secret values are encrypted with AES-256 before they touch disk; the encryption key is generated at install time, stored in a protected file on the host, and never leaves it in plaintext. The nightly backup captures both the vault database and its key, so a restored host rebuilds every customer secret exactly — the restore replays the database before the application starts, rather than letting the application migrate an empty one.

In v1.0 the key inside the backup archive is plain text, so protection comes from the backup target's own encryption-at-rest. A future release adds an opt-in second layer that encrypts the vault dump inside the archive.

### Audit trail

Vault access is written to the service log with the principal, operation, path, secret key, and outcome — and **never** the secret value. The log answers "who touched what", never "what did they read".

The full design — path taxonomy, token principals, agent call-time pattern, anti-leak boundaries, restore story — is in the *AdminLM Secrets architecture* doc. The operator-facing guide is the *AdminLM Secrets* user guide. Both live in your documentation vault.

## Alloy Configuration Details

The Alloy container uses these components:

```alloy
// Container metrics (replaces cAdvisor)
prometheus.exporter.cadvisor "containers" {
  docker_host = "unix:///var/run/docker.sock"
  storage_duration = "5m"
}

// Host metrics (replaces node-exporter)
prometheus.exporter.unix "host" {
  rootfs_path = "/"
}

// Scrape both and send to Prometheus
prometheus.scrape "cadvisor" { ... }
prometheus.scrape "node" { ... }
prometheus.remote_write "default" { ... }

// Container logs
loki.source.docker "containers" { ... }

// Systemd journal logs
loki.source.journal "systemd" { ... }

loki.write "default" { ... }
```

## Volume Mounts Required

Alloy requires these mounts for full observability:

| Mount | Purpose |
|-------|---------|
| `/var/run/docker.sock` | Docker API access (cAdvisor) |
| `/` (rootfs) | Host filesystem (node_exporter) |
| `/sys` | System info (cgroups) |
| `/var/lib/docker/` | Docker metadata |
| `/var/log/journal` | Systemd logs |
| `/dev/disk/` | Disk I/O metrics |

## Why Alloy as Container?

1. **No host installation** - Everything in docker-compose
2. **Unified config** - Single config file for all collectors
3. **Easier updates** - Just update container image tag
4. **Privileged mode required** - For full host access (same as running as host service)

## Verified Working Metrics

### Host Metrics (via prometheus.exporter.unix)
- `node_cpu_seconds_total`
- `node_memory_MemTotal_bytes`
- `node_disk_*`
- `node_network_*`
- `node_filesystem_*`

### Container Metrics (via prometheus.exporter.cadvisor)
- `container_cpu_usage_seconds_total`
- `container_memory_usage_bytes`
- `container_blkio_device_usage_total`
- `container_network_receive_bytes_total`
- `container_network_transmit_bytes_total`

### Logs
- Docker container stdout/stderr (via loki.source.docker)
- Systemd journal (via loki.source.journal)

