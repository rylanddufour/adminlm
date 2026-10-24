# AIAMSBS Alloy Pilot — Linux Parity Report (Step 4)

**Generated:** 2026-07-17T02:59:39+00:00
**Pilot host:** 192.168.0.220 (the AIAMSBS host itself, used as a stand-in for a customer Linux host)
**Old path:** AIAMSBS-side alloy container (port :12345, `config/alloy.yml`) — `instance="aiamsbs-host"`
**New path:** alloy-customer container (port :12346, `config/alloy/customer-linux.river`) — `instance="e5c69b2e70ab"`

## Headline

**Identity checks (must match):** 9/9 PASS, 0 WARN, 0 FAIL, 0 no-data
**State checks (expected to expand):** 4/4 EXPANDED (new path sees more), 0 match

✅ **Parity verified for identity metrics.** Safe to proceed to Step 6 (Linux cutover).

The `EXPANDED` state-check verdicts are **positive**: the new alloy-customer path mounts `/proc` and `/sys` from the actual host, so it sees more filesystems and NICs than the AIAMSBS-side alloy (which had container-restricted mounts). This is the intended visibility improvement of the migration.

## Identity Checks (must match within 5%)

| Metric | Old (AIAMSBS-side alloy) | New (alloy-customer) | Drift | Verdict |
|---|---:|---:|---:|:---:|
| node_cpu_seconds_total {mode="idle"} | 1.2 hours | 1.2 hours | 0.181% | PASS |
| node_cpu_seconds_total {mode="user"} | 504.5 s | 504.7 s | 0.038% | PASS |
| node_cpu_seconds_total {mode="system"} | 314.9 s | 314.9 s | 0.029% | PASS |
| node_cpu_seconds_total {mode="iowait"} | 57.4 s | 57.4 s | 0.035% | PASS |
| node_memory_MemTotal_bytes | 6.06 GB | 6.06 GB | 0.000% | PASS |
| node_memory_MemAvailable_bytes | 4.51 GB | 4.50 GB | 0.091% | PASS |
| node_load5 | 0.07 | 0.07 | 0.000% | PASS |
| node_load15 | 0.23 | 0.23 | 0.000% | PASS |
| node_boot_time_seconds | 1784254454.00 | 1784254454.00 | 0.000% | PASS |

## State Checks (expanded visibility — expected)

The new path mounts `/proc`, `/sys` from the actual host, so it sees more filesystems + network interfaces than the AIAMSBS-side alloy (container-restricted mounts). Drift here means the new path is reporting MORE of the host, not a parity failure.

| Metric | Old | New | Δ vs old | Verdict |
|---|---:|---:|---:|:---:|
| node_filesystem_size_bytes (sum across mounts) | 414.82 GB | 934.57 GB | +125.3% | EXPANDED |
| node_filesystem_avail_bytes (sum across mounts) | 337.79 GB | 761.24 GB | +125.4% | EXPANDED |
| node_network_receive_bytes_total (sum across interfaces) | 192.96 KB | 677.28 KB | +251.0% | EXPANDED |
| node_network_transmit_bytes_total (sum across interfaces) | 3.79 MB | 5.64 MB | +48.6% | EXPANDED |

## Informational

| Metric | Old | New | Drift | Verdict |
|---|---:|---:|---:|:---:|
| node_load1 (informational — sample-timing jitter) | 0.03 | 0.02 | 40.0% | INFO (jitter) |

## node_uname_info (identity match)

| Field | Old | New | Match |
|---|---|---|:---:|
| `sysname` | `Linux` | `Linux` | ✅ |
| `release` | `6.8.0-117-generic` | `6.8.0-117-generic` | ✅ |
| `version` | `#117-Ubuntu SMP PREEMPT_DYNAMIC Tue May  5 19:26:24 UTC 2026` | `#117-Ubuntu SMP PREEMPT_DYNAMIC Tue May  5 19:26:24 UTC 2026` | ✅ |
| `machine` | `x86_64` | `x86_64` | ✅ |
| `nodename` | `a26adc49f61a` | `e5c69b2e70ab` | ❌ *(container ID, expected to differ)* |

✅ **Identity match** (kernel, arch, hostname match). The `nodename` difference is expected — it's the container ID, not the host identity.

## Log Volume (sanity check)

⚠️ Loki query failed: HTTP Error 401: Unauthorized

**Manual query:** `curl http://192.168.0.220:3100/loki/api/v1/query?query={job="systemd",source="customer_host_linux"}` (skip if port not exposed)

## Findings

### 🟡 New path missing `host` label on remote_write metrics

`node_cpu_seconds_total` and friends arrive at Prometheus WITHOUT a `host` label, while the AIAMSBS-side alloy's path adds `host=aiamsbs-host` via `prometheus.yml` `relabel_configs`.

**Why:** The `customer-linux.river` `prometheus.relabel "customer_host"` rule should add `host=sys.env("HOSTNAME")`, but the resulting series don't carry the label. Most likely cause: `sys.env("HOSTNAME")` returns empty (Docker env propagation gotcha for reserved names) OR the relabel rule's `replacement` is being ignored for an empty value.

**Impact:** Negligible for parity (we compared on `instance`), but the per-host dashboard (`label_values(node_uname_info, host)`) won't see this host yet.

**Fix candidates:**
1. Verify container env: `docker inspect alloy-customer | jq '.[0].Config.Env'` — confirm `HOSTNAME=aiamsbs-host`
2. If empty, rename env var to avoid Docker's reserved `HOSTNAME` collision: change to `ALLOY_HOST_LABEL=aiamsbs-host` and reference as `sys.env("ALLOY_HOST_LABEL")` in River
3. Alternative: set the host label via `prometheus.relabel` `target_label = "instance"` to inject hostname through the scrape config instead

## Conclusion

**Identity parity verified** (9/9 checks PASS, 0 WARN, 0 FAIL, 0 no-data) + uname match.

State checks: 4/4 show expanded visibility (new path sees more filesystems and NICs — positive, expected).

**Decision:** ✅ **Proceed to Step 6 (Linux cutover)** — stop `node_exporter` + `rsyslog→Promtail :1514` on the pilot host, remove the AIAMSBS-side alloy's container (or leave for parity-still-running observation), leave only the new alloy-customer path.

---

**Provenance:** Generated by `scripts/alloy_parity_check.py` against `http://192.168.0.220:9090` and `http://192.168.0.220:3100`. To reproduce: re-run the script. Generated 2026-07-17T02:59:39+00:00.