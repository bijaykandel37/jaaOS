# jaaOS documentation index

Read in order; each phase doc ends with acceptance criteria and known limitations.

| Doc | What it covers |
|-----|----------------|
| [00-architecture.md](00-architecture.md) | Base choice (Debian derivative), component diagram, boot/FDE/kernel/MAC decisions, profiles, top risks. |
| [01-threat-model.md](01-threat-model.md) | Assets, per-adversary verdicts (T1–T10), and the honest limits of the dual-env feature. |
| [02-phase1-minimal-image.md](02-phase1-minimal-image.md) | Bootable encrypted hardened image: LUKS2, Secure Boot (signed UKI), Btrfs+snapper. Build + test + acceptance. |
| [03-phase2-dual-env.md](03-phase2-dual-env.md) | Dual-password environments: storage evaluation, auth/PAM design, leakage analysis, forensic tests. |
| [04-phase3-installer.md](04-phase3-installer.md) | Installer (TUI + Calamares): real-disk FDE, profile selection, dual-env wiring, declarable-env-only install. |
| [05-phase4-hosting.md](05-phase4-hosting.md) | Hosting & load-balancing CLI (`jaa-host`): nginx/Caddy sites, HAProxy/Traefik LBs, keepalived HA, firewall + monitoring integration. |
| [06-phase5-monitoring.md](06-phase5-monitoring.md) | Self-monitoring stack: Prometheus/Alertmanager/Loki/Alloy/Grafana/Falco + `jaa-health`, lite/full modes, the monitoring deniability rules (R-MON). |
| [07-phase6-vapt.md](07-phase6-vapt.md) | VAPT toolkit `jaa-scan`: engagement files, the scope gate, containerized assessment profiles, audit — authorized-testing-only. |
| [09-cluster.md](09-cluster.md) | Docker + RKE2 built in; master/worker/none at install; how masters and workers find and trust each other (mDNS + join code + CA fingerprint); cluster firewall. |
| [08-phase7-release.md](08-phase7-release.md) | CI, signed reproducible releases, `jaa-update` (snapshot rollback), declarative `jaa diff`/`apply`, first Rust port; lite live ISO (boots in QEMU) + Cockpit scaffold. |
| [decisions/](decisions/) | ADRs: [0001 base distribution](decisions/0001-base-distribution.md), [0002 implementation language](decisions/0002-implementation-language.md). |

For a quick orientation and the project conventions, see [`../CLAUDE.md`](../CLAUDE.md).
Roadmap: all seven phases are written. Phases 1–3 are code (not yet built/booted); phases 4–7 add
sandboxed tests that pass (`make test`). The lite live ISO is built and boots to login in
QEMU; the full image build and the GitHub workflows still need a run on real infrastructure.
