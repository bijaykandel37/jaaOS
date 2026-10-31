# ADR 0002 — Implementation language: Rust for runtime tools, shell for build glue

- Status: **Accepted**
- Date: 2026-10-31
- Deciders: maintainer (solo)

## Context

The prototype `bastion-*` tools and the dual-env auth path are currently bash (plus a C PAM
skeleton). For the real implementation we want "the fastest language, C or Rust." Two facts shape
the decision honestly:

1. **C and Rust are the same speed tier.** Neither is meaningfully faster than the other for this
   workload.
2. **These tools are not CPU-bound.** The expensive work happens in code we call, not code we
   write: Argon2id inside `cryptsetup`, and later `nmap`/`nginx`/`podman`/etc. Our binaries
   orchestrate. So raw language speed is almost irrelevant to wall-clock performance; what matters
   is **memory safety, robustness, and single-binary distribution** — and the auth/crypto path is
   precisely where a C memory bug becomes an auth bypass or root.

## Decision

- **Rust** for every runtime binary: `bastion-env`, `bastion-host`, `bastion-scan`,
  `bastion-health`, `bastion-audit`, `bastion` (system.toml), plus the PAM module
  `pam-bastion-env` (a `cdylib` via the `pamsm` crate). Rust gives C-equivalent speed with memory
  safety, static single binaries, good CLI ergonomics (`clap`), and real error handling
  (`anyhow`). They live in a Cargo workspace under `crates/`.
- **C** only if a PAM `.so` with zero non-libc runtime dependencies is specifically required; the
  existing `packages/bastion-env/pam_module/pam_bastion_env.c` stays as that fallback.
- **Shell** for build/orchestration only (`build/*.sh`, install hooks). These drive `mmdebstrap`,
  `cryptsetup`, `sgdisk`, `ukify`; porting them to C/Rust adds code without adding speed.
- **Never hand-roll crypto.** Use vetted libraries (RustCrypto/ring) or shell out to `cryptsetup`.

## Migration

The bash under `packages/bastion-env/` is the **behavioural spec**. Port it to Rust
component-by-component, preserving behaviour exactly — including the constant-time auth, the
`status`-reveals-nothing rule, and the PAM exit-code contract (`exit 0` only on affirmative auth).
Delete a bash tool only once its Rust replacement passes the same tests.

## Alternatives rejected

- **C everywhere:** same speed as Rust but no memory safety, in the one place (auth) where that
  is most dangerous. Kept only as the optional PAM fallback.
- **Go:** easy and fast to write, but a GC and larger static binaries are a poor fit for a PAM
  module / early-boot-adjacent tooling, and Go↔PAM FFI is awkward.
- **Keep bash/Python:** fine as the spec and as build glue, too slow/unsafe for the auth path and
  not what we want to ship as the product's tools.

## Consequences

- CI needs a Rust toolchain; Debian packaging uses `cargo-deb` or `dh-cargo`.
- The PAM module needs FFI (`pamsm`), a bit more scaffolding than the C version.
- `rust-toolchain.toml` pins the channel so builds are reproducible.
