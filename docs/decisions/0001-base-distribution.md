# ADR 0001 — Base distribution: Debian 13 stable derivative

- Status: **Accepted**
- Date: 2026-10-31
- Deciders: maintainer (solo)

## Context

BastionOS targets both workstations and servers, is maintained by one person, needs stability for
hosting workloads, freshness for security tooling, safe updates, and full reproducibility. The two
realistic bases are Debian stable and Arch.

## Decision

Build BastionOS as a **Debian 13 (trixie) stable derivative** — a thin overlay (signed APT repo,
meta-packages, config packages, installer preset, `bastion-*` tools), **not** a from-scratch
distribution and **not** a kernel fork.

## Rationale

- Solo maintenance makes inheriting Debian's security team and archive decisive; owning a rolling
  integration (Arch) or a from-scratch archive is not sustainable for one person.
- Debian is the proven base for hosting and for security derivatives (Kali, Parrot).
- `snapshot.debian.org` timestamp-pins every package → a bit-reproducible base, which Arch's
  rolling model cannot match as easily.
- The only real weakness — stale security tools — is solved precisely: VAPT tools in pinned
  containers, fast-moving Go tools as pinned binaries in the overlay, DevOps CLIs via `mise`.

## Consequences

- We do not control base package versions; we accept Debian's cadence for everything except the
  deliberately-overlaid fast-movers.
- We must run and maintain: an overlay repo + signing, CI ISO builds, and config/meta packages.
- aarch64 is deferred post-1.0 (needs an arm64 overlay component, per-board Secure Boot, and arm64
  tool images).

## Alternatives rejected

- **Arch:** freshest tools, but rolling breakage is hostile to unattended servers and to a solo
  maintainer, and reproducibility is harder.
- **From-scratch / LFS-style:** categorically unsustainable solo.
