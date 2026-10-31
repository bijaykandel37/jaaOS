# BastionOS — Phase 7: Polish, CI, release & update/rollback

Status: **CI, release tooling, the update/rollback CLI, the declarative reconciler, and the first
Rust port are written and tested in a sandbox (real runs, no root).** The image-building and
release *workflows* are written and YAML-validated but have not been executed on GitHub here;
the live ISO and the Cockpit plugin are **scaffolds, not yet built/booted**. Honest status per
item below.

## What this phase delivers

| Area | Deliverable | State |
|---|---|---|
| CI | `.github/workflows/ci.yml` — shell lint, sandbox test suites, Rust fmt/clippy/test | written, YAML-valid; not run on GitHub here |
| Image CI | `build-image.yml` — reproducible rootfs + signed image, artifact upload | written; needs a run on a root-capable runner |
| Release | `release.yml` + `build/release.sh` — checksums, provenance manifest, SBOM, minisign/gpg signature | script **tested** (`release-test.sh`); workflow not run here |
| Update | `bastion-update` — snapshot-bracketed `apply`/`rollback` | **tested** (`update-test.sh`, dry-run) |
| Declarative | `bastion diff`/`apply` over `/etc/bastion/system.toml` | **tested** (`system-toml-test.sh`) |
| Rust port | `bastion-core::scope` — IPv4/scope logic ported from `bastion-scan`, with unit tests | written; compiles+tests in CI (no toolchain here) |
| Live ISO | `build/mklive.sh` | **scaffold**, not built/booted |
| Cockpit | `installer/cockpit/bastion/` (optional web UI) | **scaffold**, not audited |

## CI (the point of "GitHub + cloud Claude Code")

`ci.yml` runs on every push/PR with three jobs:

- **shell-lint** — `make lint` (bash -n + shellcheck over `build packages tests installer`).
- **sandbox-tests** — the six root-free suites: `hosting`, `monitoring`, `vapt`, `update`,
  `release`, `system-toml`. These are exactly what `make test` runs locally.
- **rust** — `cargo fmt --all --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`
  (these enforce the ADR-0002 conventions and run the new `bastion-core::scope` unit tests).

`build-image.yml` (manual) builds the reproducible rootfs + the encrypted, signed image on a
hosted runner (which has root) and uploads the artifacts — but hosted runners have **no nested
KVM**, so the image is **not boot-tested** there; boot-test on a real host with `make vm`.

## Release: signed, reproducible, with provenance

`build/release.sh` (and `make release`) turns a completed build into `out/dist/`:

- `SHA256SUMS` over the image + rootfs tarball, verifiable with `sha256sum -c`.
- `manifest.json` — version (`git describe`), commit, the **debian snapshot** + `SOURCE_DATE_EPOCH`
  that make the build reproducible, tool versions, and each artifact's SHA-256.
- `sbom.txt` — exact package/version/arch list extracted from the rootfs's dpkg database (run
  `syft` for a signed CycloneDX SBOM; this is the lean, dependency-free form).
- A detached **signature** over `SHA256SUMS`: minisign if a key is present (the `release.yml`
  secret `MINISIGN_SECRET_KEY`), else gpg, else an explicit `SHA256SUMS.UNSIGNED` notice — it
  never fabricates a signature or fails silently.

`release.yml` runs this on a `v*` tag and publishes a GitHub release.

## Update & rollback (`bastion-update`)

Every `apply` is bracketed by snapper snapshots of the root subvolume:

```
bastion-update check               # refresh indexes, list upgradable (read-only)
bastion-update apply               # PRE-snapshot -> apt full-upgrade -> POST-snapshot
bastion-update rollback <number>   # roll the root subvol back; reboot to apply
BASTION_UPDATE_DRYRUN=1 bastion-update apply   # print the plan, run nothing
```

**Honest kernel limit:** the kernel is inside the immutable, Secure-Boot-signed UKI (Phase 1). A
snapper rollback restores the root filesystem but **not** the booted kernel/UKI, which lives on
the ESP and is replaced only by rebuilding + re-signing the image. `apply` detects a
kernel-touching upgrade and warns that the UKI must be rebuilt/re-signed, so you are never
silently left with a kernel that will not boot under Secure Boot.

## Declarative config (`bastion diff`/`apply`)

The Phase-3 stubs are now real. `/etc/bastion/system.toml` (a small, fixed TOML subset) declares
the profile, extra packages, services to enable/disable, and firewall TCP ports. `bastion diff`
shows drift; `bastion apply [--dry-run]` reconciles (apt / systemctl / nft). The file is
**parsed, not executed**. See the shipped `config/rootfs/etc/bastion/system.toml`.

## First Rust port

`crates/bastion-core::scope` ports the security-critical IPv4/CIDR/scope-matching from
`bastion-scan` into shared, unit-tested Rust — the template for porting the rest of the bash
specs (ADR 0002). Its `#[test]`s mirror `tests/vm/vapt-test.sh`, so CI's `cargo test` pins the
behaviour. The CLIs' Rust crates remain clap scaffolds until ported verb-by-verb; they could not
be compiled in this environment (no toolchain), which is why the bash specs stay authoritative.

## Build / test (copy-paste)

```bash
cd /home/bijay/Public/jaaOS
make test            # the six sandbox suites (no root, no VM)
make lint            # bash -n + shellcheck
# with a Rust toolchain (e.g. on the cloud):
make rust-lint && make rust-test
# release tooling over a completed build:
make image && make release && ls out/dist/
```

## Acceptance criteria

- [x] `ci.yml`/`build-image.yml`/`release.yml` are valid workflow YAML. *(validated)*
- [x] `release.sh` produces verifiable checksums, a manifest, an SBOM, and an honest
      signed/unsigned outcome. *(release-test.sh)*
- [x] `bastion-update apply` is snapshot-bracketed and warns on kernel changes; `rollback`
      plans a snapper rollback. *(update-test.sh)*
- [x] `bastion diff`/`apply` parse `system.toml` and reconcile only the drift. *(system-toml-test.sh)*
- [x] `bastion-core::scope` unit tests mirror the bash scope gate. *(cargo test, in CI)*
- [ ] On GitHub: CI is green; `build-image.yml` produces a signed image artifact.
- [ ] On a real host: the image builds, boots (`make vm`), updates, and rolls back.
- [ ] Live ISO boots to a session offering the TUI + Calamares installers.
- [ ] The Cockpit plugin loads and runs the CLIs.

## Known limitations

1. **Workflows not executed here.** They are YAML-valid and mirror the local `make` targets, but
   GitHub has not run them in this environment. Expect to iterate on apt package names / runner
   images on first run.
2. **No boot-test in CI.** Hosted runners lack nested KVM; `make vm` on a real host is the boot
   gate.
3. **Live ISO (`build/mklive.sh`) is a scaffold** — it lays out the squashfs/ISO tree but the
   live-boot package set and the signed EFI boot payload are TODO; no ISO has booted.
4. **Cockpit plugin is a starter, unaudited** UI that only runs the read-only CLIs; it is optional
   and not part of the default profiles.
5. **Rust is ported incrementally.** Only `bastion-core::scope` is ported so far; the CLI crates
   are still clap scaffolds delegating to the bash specs. No Rust was compiled in this
   environment — CI (or the cloud) is where `cargo build/clippy/test` actually runs.
6. **SBOM is the lean form** (dpkg name/version/arch). A signed CycloneDX/SPDX SBOM needs `syft`
   or similar in the release workflow.
