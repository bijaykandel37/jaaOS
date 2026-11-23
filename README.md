# jaaOS

A hardened, DevOps-first Linux distribution for engineers and **authorized** security
testing. jaaOS is **not** a from-scratch distribution and **not** a kernel fork. It is
a **Debian 13 (trixie) stable derivative** — a thin, reproducible overlay (signed APT repo,
meta-packages, config packages, an installer preset, and a set of `jaa-*` tools) on top
of Debian's base and security-maintained kernel.

This structure is a deliberate consequence of the project being maintained by **one person**:
~95% of the security maintenance (CVE backports, kernel updates, the package archive) is
*inherited from Debian* rather than owned by us. See
[docs/00-architecture.md](docs/00-architecture.md) for the full rationale.

## Status

All seven phases are written. Phases 1–3 are **code, syntax-checked** (not yet built/booted — that
needs a Debian host and a root VM). Phases 4–7 add **sandboxed test suites that pass on real runs**
(no root, no VM): `make test` runs all six (hosting, monitoring, vapt, update, release, system-toml).
The lite live ISO (`make live`, ~310 MB, with Docker, RKE2 and the installer) is built and boots to a login prompt in QEMU (BIOS + UEFI). The installer asks whether a machine is a Kubernetes master, worker or neither ([docs/09-cluster.md](docs/09-cluster.md)). The full image build and the GitHub workflows still need a run on real infrastructure. New
here? Read [`CLAUDE.md`](CLAUDE.md) for a fast orientation and the [`docs/`](docs/README.md) index.

| Phase | Scope | State |
|------:|-------|-------|
| 0 | Architecture, threat model, repo layout | ✅ written |
| 1 | Minimal image: hardened kernel, LUKS2 FDE, Secure Boot (UKI), Btrfs+snapper | ✅ code, not yet built |
| 2 | Dual-password environments: design, prototype, leakage/forensic tests | ✅ code, not yet run |
| 3 | Installer with profiles (TUI + Calamares), real-disk FDE, dual-env wiring | ✅ code, not yet run |
| 4 | Hosting & load-balancing CLI (`jaa-host`) | ✅ code + tests pass |
| 5 | Self-monitoring stack (Prometheus/Loki/Grafana/Falco + `jaa-health`) | ✅ code + tests pass |
| 6 | VAPT toolkit (containerized, scope-enforced `jaa-scan`) | ✅ code + tests pass |
| 7 | CI, release signing, update/rollback, declarative config, first Rust port | ✅ code + tests pass (lite live ISO boots in QEMU; Cockpit scaffolded) |

## Quick start (Debian/Ubuntu host)

```bash
make deps      # install build/test dependencies
make lint      # bash -n + shellcheck all scripts
make image     # build out/jaaos-minimal.img (image step needs root)
make vm        # boot it in QEMU (OVMF + swtpm)
make live      # build the ~310 MB lite live ISO out/jaaos-lite.iso (root)
make live-test # boot the ISO in QEMU (BIOS + UEFI) and wait for the login prompt
make live-desktop # build the ~530 MB XFCE desktop live ISO out/jaaos-desktop.iso (root)
make help      # list every entry point
```

## Honesty notice (read this before trusting the security model)

jaaOS includes a **dual-password / dual-home** feature: one username, two passwords, each
unlocking a separate encrypted home, with the goal of hiding the second environment's
*existence*. You must understand what this does and does not do before relying on it:

- It protects the **contents** of both homes well when the machine is **powered off** (LUKS2 +
  Argon2id full-disk encryption). This is strong.
- It does **not** reliably hide the second environment's *existence* from a competent forensic
  examiner, because the very presence of jaaOS and its tooling signals that a hidden
  environment *may* exist.
- It does **not** protect the second environment from malware or a rootkit that gained
  persistence while the first environment was unlocked — the system directories are **shared**,
  so a root-level compromise in one environment can wait for and read the other.
- It is **not** a defense against legal compulsion to disclose a password.

The full, itemized analysis is in [docs/01-threat-model.md](docs/01-threat-model.md). The
feature defends against a **lost/stolen powered-off laptop**, **shoulder-surfing**, and an
**opportunistic or non-technical** adversary. It does not defend against a **targeted, informed,
or forensic** adversary. We ship this analysis prominently and on-device rather than overselling
the feature.

## Intended use

Hosting, container, monitoring, and DevOps workloads, plus **authorized** vulnerability
assessment and penetration testing. The bundled VAPT toolkit refuses to run without an
engagement file declaring authorized scope and an authorization reference, and logs every run
for audit. jaaOS is for testing systems you own or are explicitly contracted to test.

## Repository layout

| Path | Purpose |
|------|---------|
| `docs/` | Architecture, threat model, and Architecture Decision Records (`docs/decisions/`). |
| `build/` | ISO build configuration (mkosi) and per-profile package lists (`build/profiles/`). |
| `kernel/` | Hardened kernel command line, sysctl, and module/boot config fragments. No kernel source. |
| `overlay-repo/` | Signed APT overlay repository config (reprepro) and signing-key policy. |
| `packages/` | Source for the `jaa-*` Debian packages, including the PAM module, and meta-packages. |
| `config/etc/` | The `/etc` skeleton shipped by config packages: nftables, AppArmor, auditd, sshd, systemd units. |
| `installer/` | Calamares (graphical) and TUI installer integration. |
| `ci/` | Reproducible build, sign, and test pipelines. |
| `tests/` | VM boot/integration harness (`tests/vm/`) and forensic deniability tests (`tests/forensic/`). |

## Build phases

Each phase stops for review; full detail (goals, files, build/test, acceptance, limitations)
lives in the matching `docs/0N-*.md`.

0. ✅ **Architecture** — base, diagram, threat model, layout, risks.
1. ✅ **Minimal image** — hardened kernel config, FDE, Secure Boot (UKI), Btrfs snapshots.
2. ✅ **Dual-password environments** — design, VM prototype, leakage and forensic tests.
3. ✅ **Installer** — graphical + TUI, profile selection.
4. ✅ **Hosting / load balancing** — `jaa-host`.
5. ✅ **Monitoring** — local Prometheus/Loki/Grafana/Falco stack + `jaa-health`.
6. ✅ **VAPT toolkit** — containerized, scope-enforced, audited `jaa-scan` (assessment only).
7. ✅ **Polish/release** — CI (lint/test/rust), signed reproducible releases, `jaa-update`
   (snapshot rollback), declarative `jaa diff`/`apply`, first Rust port; live ISO + Cockpit scaffolded.

## License

jaaOS is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).
Bundled third-party components (the Debian base, and the VAPT tools in a later phase) keep their
own licenses; the overlay repo records each component's license before redistribution.
