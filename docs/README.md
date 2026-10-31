# BastionOS documentation index

Read in order; each phase doc ends with acceptance criteria and known limitations.

| Doc | What it covers |
|-----|----------------|
| [00-architecture.md](00-architecture.md) | Base choice (Debian derivative), component diagram, boot/FDE/kernel/MAC decisions, profiles, top risks. |
| [01-threat-model.md](01-threat-model.md) | Assets, per-adversary verdicts (T1–T10), and the honest limits of the dual-env feature. |
| [02-phase1-minimal-image.md](02-phase1-minimal-image.md) | Bootable encrypted hardened image: LUKS2, Secure Boot (signed UKI), Btrfs+snapper. Build + test + acceptance. |
| [03-phase2-dual-env.md](03-phase2-dual-env.md) | Dual-password environments: storage evaluation, auth/PAM design, leakage analysis, forensic tests. |
| [04-phase3-installer.md](04-phase3-installer.md) | Installer (TUI + Calamares): real-disk FDE, profile selection, dual-env wiring, declarable-env-only install. |
| [05-phase4-hosting.md](05-phase4-hosting.md) | Hosting & load-balancing CLI (`bastion-host`): nginx/Caddy sites, HAProxy/Traefik LBs, keepalived HA, firewall + monitoring integration. |
| [06-phase5-monitoring.md](06-phase5-monitoring.md) | Self-monitoring stack: Prometheus/Alertmanager/Loki/Alloy/Grafana/Falco + `bastion-health`, lite/full modes, the monitoring deniability rules (R-MON). |
| [decisions/](decisions/) | ADRs: [0001 base distribution](decisions/0001-base-distribution.md), [0002 implementation language](decisions/0002-implementation-language.md). |

For a quick orientation and the project conventions, see [`../CLAUDE.md`](../CLAUDE.md).
Roadmap: phases 0–5 are written (code; phases 4–5 also have sandboxed tests that pass, nothing
built/booted yet); phases 6–7 are pending.
