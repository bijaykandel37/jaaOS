# jaaOS — Phase 5: Self-monitoring stack

Status: **written; config validated and the `jaa-health` CLI exercised in a sandbox (real
run, no root — `tests/vm/monitoring-test.sh`, 27/27).** Not yet run against live
Prometheus/Grafana/Loki/Falco on a booted host (needs the packages installed — see Test plan).
The bash `jaa-health` is the behavioural spec; the Rust port target is
`crates/jaa-health` (ADR 0002).

## Goal

Ship a **local-first** monitoring and runtime-security stack that works on day one, over an SSH
tunnel, without exposing a single port to the network — and that **adds no new way to detect the
dual-password feature**. Built from proven upstream components (CLAUDE.md policy); jaaOS
contributes configuration, a textfile collector, the `jaa-health` CLI, and the deniability
guard — not a fork of any of these tools.

## Components

| Layer | Tool | Source | Mode |
|---|---|---|---|
| Metrics | Prometheus | Debian main | lite + full |
| Host metrics | prometheus-node-exporter | Debian main | lite + full |
| Alerting | Alertmanager | Debian main | full |
| Integrity | AIDE + auditd (already in Phase 1) → textfile metrics | Debian main | lite + full |
| Logs | Loki + Grafana Alloy | grafana.com apt repo | full |
| Dashboards | Grafana | grafana.com apt repo | full |
| Runtime security | Falco (**modern_ebpf** driver) | falcosecurity apt repo | full |
| CLI | `jaa-health`, `jaa-security-metrics` | this repo | lite + full |

### Two modes (the brief's "lightweight mode")

- **`lite`** (default — workstations, small VMs): node_exporter + a short-retention Prometheus
  only. You still get CPU/mem/disk/load, failed-unit detection, the security textfile metrics
  (auditd/AIDE/AppArmor/Falco-count), and locally-evaluated alert rules. Tiny footprint.
- **`full`** (servers): adds Alertmanager, Loki + Alloy (logs), Grafana (dashboards), and Falco
  (syscall-level runtime security).

Switch with `jaa-health enable --mode lite|full`. The mode is recorded in
`/etc/jaa/monitoring/mode` and also sets Prometheus retention (lite 7d, full 30d).

## How it fits the other phases

- **Consumes Phase 4.** Every `jaa-host site|lb|ha` command drops a Prometheus **file_sd**
  target in `/etc/jaa/monitoring/targets.d/*.json`; `prometheus.yml` discovers them with no
  reload, and `jaa-health targets` lists them. The test proves this end-to-end: it runs
  `jaa-host site create` and then sees the target in `jaa-health targets`.
- **Surfaces Phase 1 hardening.** auditd and AIDE (shipped in Phase 1) become metrics via
  `jaa-security-metrics`, which writes the node_exporter textfile collector; alerts fire if
  auditd stops or AIDE sees drift.
- **Respects Phase 1 firewall.** Nothing here opens a port. Prometheus (9090), Alertmanager
  (9093), node_exporter (9100), Grafana (3000) and Loki (3100) all bind to `127.0.0.1`. Reach
  them over `ssh -L`. This is deliberate: a monitoring UI is a juicy target.

## Deniability (non-negotiable — read this)

The dual-password feature's honesty rules (CLAUDE.md; `docs/01-threat-model.md`) apply here too.
A monitoring stack is a classic place to **accidentally leak the second environment**. Our rules:

1. **No environment concept anywhere.** No metric, label, scrape target, alert, or dashboard
   references environments, homes, or a count of either. `jaa-health` has **no** `list` or
   `environments` command and reveals nothing about other environments — exactly like
   `jaa-env status`. (The test greps the output and the configs to enforce this.)
2. **The auth path is dropped before it can persist.** Phase 2 already makes `jaa-env` /
   `jaa-env-pam` / the PAM module log nothing env-identifying. As defence in depth, the Alloy
   pipeline **drops** those journal identifiers outright, so even a future stray log line never
   reaches Loki, where opportunistic inspection could read it.
3. **Honest about what this does NOT buy you.** Prometheus TSDB, Loki chunks and Grafana state
   live in `/var/lib/*` — **shared system directories**. They persist across environment
   switches and record *activity timing* for whichever environment was active. This is **not**
   protected and gives **no** deniability; it falls squarely under the existing limit "system
   dirs are shared; no defence against root or forensics." Shorter retention in `lite` mode
   reduces how much of this history sits on disk — a mitigation, not a guarantee. See residual
   **R-MON** in the threat model.

In short: the stack monitors the **active system**, never "the environments," and the one real
new persistence risk (timing history in shared dirs) is documented, not hidden.

## Falco on a locked-down kernel (important)

jaaOS boots Secure Boot + `lockdown=confidentiality` + `module.sig_enforce=1`. That kernel
**refuses to load Falco's out-of-tree kernel module** (unsigned), so the legacy `kmod` driver
cannot work. We configure Falco's **`modern_ebpf`** driver (CO-RE eBPF, in-tree BPF path, no
out-of-tree module), which is the only Falco driver compatible with our boot policy. This is set
in `config/rootfs/etc/falco/config.d/jaa.yaml` — do not switch it back to `kmod`.

## `jaa-health` commands

```
jaa-health status            # one-screen health; works even if Prometheus is down
jaa-health targets           # static + jaa-host file_sd targets
jaa-health check             # exit non-zero if a threshold is crossed (cron/CI)
jaa-health alerts            # currently firing alerts (Alertmanager, else Prometheus)
jaa-health enable --mode lite|full   # set mode + enable the matching units (root)
```

`status`/`check` read `/proc`, `df`, `systemctl` and `ss` directly, so they work when the stack
itself is down — which is exactly when you need them. Prometheus/Alertmanager only *enrich*.

## Files in this phase

| File | Purpose |
|---|---|
| `config/rootfs/etc/prometheus/prometheus.yml` | Scrape config; consumes the Phase-4 file_sd targets. |
| `config/rootfs/etc/prometheus/rules/jaa-alerts.yml` | Availability / capacity / security alerts. |
| `config/rootfs/etc/alertmanager/alertmanager.yml` | Routing; **no** external receiver wired by default (honest). |
| `config/rootfs/etc/alloy/config.alloy` | Journal → Loki; **drops the dual-env auth path**. |
| `config/rootfs/etc/loki/config.yml` | Single-binary Loki, localhost, 7-day retention. |
| `config/rootfs/etc/grafana/provisioning/{datasources,dashboards}/jaa.yml` | Auto-wire datasources + dashboards. |
| `config/rootfs/etc/grafana/dashboards/jaa-{overview,security}.json` | Host + security dashboards. |
| `config/rootfs/etc/falco/config.d/jaa.yaml` | Falco engine (**modern_ebpf**) + outputs. |
| `config/rootfs/etc/falco/rules.d/jaa.yaml` | High-signal custom rules. |
| `config/rootfs/etc/default/prometheus`, `.../prometheus-node-exporter` | Localhost bind, retention, textfile + systemd collectors. |
| `config/rootfs/etc/jaa/monitoring/mode` | `lite`/`full` selector read by `jaa-health`. |
| `config/rootfs/etc/systemd/system/jaa-security-metrics.{service,timer}` | 5-min textfile collector run. |
| `packages/jaa-health/bin/jaa-health` | The CLI (bash prototype / spec). |
| `packages/jaa-health/bin/jaa-security-metrics` | auditd/AIDE/AppArmor/Falco → node_exporter textfile. |
| `crates/jaa-health/` | Rust port scaffold (clap tree). |
| `tests/vm/monitoring-test.sh` | Sandbox validation + end-to-end file_sd handoff. |

## Build / test (copy-paste)

```bash
cd /home/bijay/Public/jaaOS
bash -n packages/jaa-health/bin/jaa-health
bash tests/vm/monitoring-test.sh          # config validation + CLI + handoff (no root, no services)

# On a host/VM with the stack installed:
sudo apt install -y prometheus prometheus-node-exporter prometheus-alertmanager aide auditd
# full mode also needs the vendor repos for grafana / loki / alloy / falco (see §Components)
sudo install -m0755 packages/jaa-health/bin/jaa-health /usr/local/sbin/
sudo install -m0755 packages/jaa-health/bin/jaa-security-metrics /usr/local/sbin/
sudo jaa-health enable --mode lite     # or full on a server
jaa-health status
ssh -L 9090:127.0.0.1:9090 -L 3000:127.0.0.1:3000 <host>   # reach Prometheus/Grafana locally
```

## Acceptance criteria

- [x] Every shipped config parses (YAML via a parser, dashboards as valid JSON). *(test)*
- [x] `prometheus.yml` discovers the Phase-4 `targets.d/*.json`; a `jaa-host`-created site
      shows up in `jaa-health targets`. *(test, end-to-end)*
- [x] `jaa-security-metrics` emits valid Prometheus text with the expected series. *(test)*
- [x] The Alloy pipeline drops the dual-env auth identifiers; no env-enumerating metric/label
      exists in any config. *(test)*
- [x] `jaa-health status` renders and reveals nothing about environments. *(test)*
- [ ] On a booted host: Prometheus scrapes node_exporter + targets, alert rules load
      (`promtool check rules`), Grafana shows both dashboards, Falco starts on `modern_ebpf`.
- [ ] `jaa-health alerts` shows a rule firing when a target is stopped.

## Known limitations

1. **Not yet run against the live stack.** Configs are parser-validated and the CLI is
   exercised in a sandbox, but no booted host has scraped/alerted/graphed yet. `promtool`,
   `amtool`, and `alloy validate` aren't available in this environment; run them on a real host.
2. **bash prototype**, pending the Rust port (`crates/jaa-health`).
3. **Grafana/Loki/Alloy/Falco are not in Debian main** — they come from the vendors' signed APT
   repos via the jaaOS overlay. `lite` mode needs none of them (Debian-only).
4. **Alertmanager ships with no notification channel.** You must configure one receiver; by
   default alerts are visible only in the UI/API and via `jaa-health alerts`.
5. **Monitoring data persists in shared `/var/lib`** and records activity timing — covered by
   the existing "shared system dirs / no forensic defence" limit (residual **R-MON**). It adds
   no deniability and must not be treated as private to an environment.
6. **Falco needs eBPF/CO-RE support** in the running kernel; verify on first boot. The legacy
   kernel-module driver is intentionally unusable here (signed, locked-down kernel).
