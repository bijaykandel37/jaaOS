# jaaOS — guide for Claude Code

Repo folder: `jaaOS`. Product name: **jaaOS**. Read this file first; it is meant to save
you from re-exploring the tree. For design detail, open the one relevant `docs/0N-*.md` rather
than scanning everything.

## What this is
A **Debian 13 (trixie) stable derivative** — a thin overlay (signed APT repo, meta-packages,
config packages, `jaa-*` tools, installer preset, hardening defaults) for DevOps and
**authorized** security testing. It is **not** a from-scratch distro and **not** a kernel fork.
Maintained by **one person**; that constraint drives everything — inherit Debian's security
maintenance, prefer proven upstream components, write custom code only where nothing fits.

## Non-negotiable: be honest about security limits
The headline feature is dual-password "deniable" home environments. **Never oversell it.** In
any doc, code comment, or user-facing string, keep this framing:
- Protects both homes' **contents** at rest (powered-off). Strong.
- Hides the second environment only from **opportunistic** inspection.
- Does **not** hide its existence from a forensic examiner or anyone who knows the machine runs
  jaaOS; does **not** survive root-level malware (system dirs are shared); is **no** defense
  against legal compulsion.
Source of truth: `docs/01-threat-model.md`, `docs/03-phase2-dual-env.md` §2 and §9.
Likewise: the VAPT toolkit (`jaa-scan`, Phase 6) is authorized-testing-only, scope-enforced,
audited, and assessment-only — it ships **no** exploits/DoS/evasion/mass-targeting, and refuses
to run without an engagement file declaring `AUTHORIZATION_REF` + scope. Keep that framing.

## Implementation language (ADR: `docs/decisions/0002`)
Runtime tools are **Rust**; build glue stays **shell**. Why: C and Rust are the same speed tier,
and these tools are I/O/subprocess-bound anyway (the real cost is Argon2id in cryptsetup, nmap,
nginx…), so "fastest" is decided by **safety**, not nanoseconds — and the auth/crypto path is
exactly where a C memory bug would be an auth bypass. Therefore:
- **Rust** (`crates/`): every `jaa-*` binary and the PAM module (`pam-jaa-env`, cdylib via
  `pamsm`). Use `clap` CLIs, `anyhow` errors, single static binaries. **Never hand-roll crypto** —
  use RustCrypto/ring or shell out to `cryptsetup`.
- **C**: only for a zero-non-libc-dep PAM `.so` if specifically needed (the existing
  `packages/jaa-env/pam_module/` C skeleton is that fallback).
- **Shell**: build/orchestration only (`build/*.sh`, install hooks). **Do not** rewrite these in
  C/Rust — they just drive mmdebstrap/cryptsetup/sgdisk/ukify; it would be more code, not faster.
- The bash under `packages/jaa-env/` is the **behavioural spec** — port it to Rust in
  `crates/` one verb at a time, keeping behaviour identical (constant-time auth, `status` reveals
  nothing, the PAM exit-code contract). Build with `make rust` / `cargo build --release`.

## Repo map
- `docs/` — `00` architecture, `01` threat model, `02` phase-1 image, `03` phase-2 dual-env, `decisions/` ADRs. **Read before changing design; update when you change behaviour.**
- `crates/` — Rust workspace: `jaa-core` (shared; `scope` = first real port, IPv4/scope logic with unit tests), `jaa-env` + `jaa-host` + `jaa-health` + `jaa-scan` + `jaa-update` (CLIs, port in progress), `pam-jaa-env` (cdylib scaffold). The real product tooling lands here. Bash specs live in `packages/*/bin/`.
- `build/` — `build.sh` (orchestrator) → `secureboot.sh` (SB keys) + `mkrootfs.sh` (reproducible Debian rootfs) + `mkimage.sh` (LUKS2+Btrfs+signed-UKI image); `release.sh` (checksums/manifest/SBOM/signature), `mklive.sh` (live-ISO scaffold). `profiles/*.packages`, `hooks/`.
- `.github/workflows/` — CI (lint + sandbox tests + rust), `build-image.yml`, `release.yml` (Phase 7).
- `kernel/` — `cmdline` (baked into the UKI; VM-safe), `cmdline.hardened` (opt-in aggressive; can brick boot — never bake by default).
- `config/rootfs/` — the `/etc`+`/usr` tree synced into the image (sysctl, nftables, sshd, zram, apparmor, `jaa-env/`, and the Phase-5 monitoring configs: `prometheus/`, `alertmanager/`, `alloy/`, `loki/`, `grafana/`, `falco/`, `jaa/monitoring/`).
- `packages/jaa-env/` — dual-env: `providers/{luks2,shufflecake}`, `bin/{jaa-env,jaa-env-pam}`, `pam/jaa-env.pamd`, `pam_module/` (native C **skeleton, unaudited**).
- `tests/vm/` — root/VM suites: `run-qemu.sh`, `checks.sh` (phase-1), `dual-env-test.sh` (phase-2), `install-test.sh` (loopback). Sandbox suites (no root, run via `make test`): `hosting`, `monitoring`, `vapt`, `update`, `release`, `system-toml`. `tests/forensic/` — deniability characterization.
- `packages/` — bash specs: `jaa` (install + declarative diff/apply), `jaa-env`, `jaa-host`, `jaa-health`, `jaa-scan`, `jaa-update`.
- `installer/` — TUI + Calamares (Phase 3), `cockpit/jaa/` (optional web UI **scaffold**). `overlay-repo/`, `ci/` — scaffolded.

## Status / roadmap
- ✅ **0** architecture · ✅ **1** minimal image · ✅ **2** dual-env · ✅ **3** installer (TUI+Calamares, real-disk FDE, profiles, dual-env wiring) · ✅ **4** hosting CLI (`jaa-host`) · ✅ **5** monitoring (Prometheus/Alertmanager/Loki/Alloy/Grafana/Falco configs + `jaa-health` + `jaa-security-metrics`) · ✅ **6** VAPT (`jaa-scan`: scope-enforced, audited, containerized, assessment-only) · ✅ **7** polish/release: GitHub Actions CI (`.github/workflows/`), signed reproducible release (`build/release.sh`), `jaa-update` (snapper-bracketed update/rollback), declarative `jaa diff`/`apply` over `/etc/jaa/system.toml`, and the first Rust port (`jaa-core::scope`). Phases 1–3 are code + syntax-checked (not yet built/booted); Phases 4–7 add sandbox suites `tests/vm/{hosting,monitoring,vapt,update,release,system-toml}-test.sh` that **pass (real runs, no root)** — run all via `make test`. Phase 6's test exercises guardrails only, never a live scan. Live ISO (`build/mklive.sh`) and the Cockpit plugin are **scaffolds, not built/booted**; the CI/image workflows have not been run on GitHub here.
- Each phase's goals + acceptance criteria + known limitations live in its `docs/0N-*.md`.

## Build / test (Debian/Ubuntu host) — `make help` lists all targets
- `make deps` — install host build/test deps
- `make image` — keys → rootfs → encrypted signed `out/jaaos-minimal.img` (image step needs root)
- `make vm` — boot it (OVMF + swtpm); `make lint` — `bash -n` + shellcheck
- `make pam` — build the native PAM skeleton (needs `libpam0g-dev`)
- VM-only: `sudo bash tests/vm/checks.sh` (phase 1), `sudo bash tests/vm/dual-env-test.sh` (phase 2). **Forensic/VM tests create real LUKS containers — run them only in a disposable root VM, never a workstation.**

## Conventions
- Rust: `clap` + `anyhow`, must pass `cargo clippy -- -D warnings` and `cargo fmt --all --check` (`make rust-lint`); keep crates in the workspace; pin new deps to a minor version.
- Shell (build glue only): `#!/usr/bin/env bash`, `set -euo pipefail` (flow-managing helpers use `set -uo pipefail` — see `jaa-env-pam`), **tabs** for indent, must pass `shellcheck`.
- Every command in docs is copy-paste ready — no placeholders.
- Security-critical code (PAM, crypto, boot) keeps a "prototype / unaudited — review before use" banner until actually reviewed; don't strip banners without a real review.
- State verification status honestly: if something was only `bash -n`'d, say so — don't call it "tested" or "booted".

## Don'ts (hard-won)
- Don't bake aggressive kernel flags (`iommu=force`, `nosmt`, …) into the signed UKI `cmdline` — immutable + wrong flag = unbootable. They go in `cmdline.hardened` (opt-in).
- Don't disable user namespaces in sysctl — rootless Podman needs them.
- Don't make the dual-env PAM helper `exit 0` for non-managed users — `pam_exec` maps exit 0 to auth success (that would be a bypass). See the `decline()` logic in `jaa-env-pam`.
- Don't add a `jaa-env list`/count command — it would break deniability (`status` must reveal nothing about other environments).
- Don't add any env-aware metric, label, dashboard, or a `jaa-health environments`/`list` command — same deniability rule as `jaa-env status`. Keep the Alloy drop of the `jaa-env*` auth-path journal identifiers (defence in depth so a stray log line never persists in Loki). See `docs/06-phase5-monitoring.md §Deniability`.
- Don't switch Falco to the `kmod`/legacy-`ebpf` driver — the signed, lockdown + `module.sig_enforce` kernel refuses the out-of-tree module. Use `modern_ebpf` only.
- Don't weaken `jaa-scan`'s gates: it must refuse without an engagement + `AUTHORIZATION_REF` + scope, keep exclusions/hard-deny winning over scope, abort a whole run on one out-of-scope target, and audit every run. Don't add an exploit/DoS/fuzz/evasion profile to the default `ALLOW_PROFILES`, and don't source the engagement file (parse it — it's data). See `docs/07-phase6-vapt.md`.
