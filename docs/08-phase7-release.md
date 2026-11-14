# jaaOS — Phase 7: Polish, CI, release & update/rollback

Status: **CI, release tooling, the update/rollback CLI, the declarative reconciler, and the first
Rust port are written and tested in a sandbox (real runs, no root).** The image-building and
release *workflows* are written and YAML-validated but have not been executed on GitHub here;
the Cockpit plugin is a **scaffold**. The **lite live ISO is built and boot-tested in QEMU**
(BIOS + UEFI, see below). Honest status per item below.

## What this phase delivers

| Area | Deliverable | State |
|---|---|---|
| CI | `.github/workflows/ci.yml` — shell lint, sandbox test suites, Rust fmt/clippy/test | written, YAML-valid; not run on GitHub here |
| Image CI | `build-image.yml` — reproducible rootfs + signed image, artifact upload | written; needs a run on a root-capable runner |
| Release | `release.yml` + `build/release.sh` — checksums, provenance manifest, SBOM, minisign/gpg signature | script **tested** (`release-test.sh`); workflow not run here |
| Update | `jaa-update` — snapshot-bracketed `apply`/`rollback` | **tested** (`update-test.sh`, dry-run) |
| Declarative | `jaa diff`/`apply` over `/etc/jaa/system.toml` | **tested** (`system-toml-test.sh`) |
| Rust port | `jaa-core::scope` — IPv4/scope logic ported from `jaa-scan`, with unit tests | written; compiles+tests in CI (no toolchain here) |
| Live ISO | `build/mklive.sh` + `build/profiles/{lite,cluster}.packages` — ~310 MB hybrid BIOS/UEFI ISO with Docker, RKE2 and the `jaa-install` installer | **built + booted to login in QEMU** (`tests/vm/live-iso-boot.sh`); not yet on real hardware |
| Cockpit | `installer/cockpit/jaa/` (optional web UI) | **scaffold**, not audited |

## CI (the point of "GitHub + cloud Claude Code")

`ci.yml` runs on every push/PR with three jobs:

- **shell-lint** — `make lint` (bash -n + shellcheck over `build packages tests installer`).
- **sandbox-tests** — the six root-free suites: `hosting`, `monitoring`, `vapt`, `update`,
  `release`, `system-toml`. These are exactly what `make test` runs locally.
- **rust** — `cargo fmt --all --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`
  (these enforce the ADR-0002 conventions and run the new `jaa-core::scope` unit tests).

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

## Update & rollback (`jaa-update`)

Every `apply` is bracketed by snapper snapshots of the root subvolume:

```
jaa-update check               # refresh indexes, list upgradable (read-only)
jaa-update apply               # PRE-snapshot -> apt full-upgrade -> POST-snapshot
jaa-update rollback <number>   # roll the root subvol back; reboot to apply
JAA_UPDATE_DRYRUN=1 jaa-update apply   # print the plan, run nothing
```

**Honest kernel limit:** the kernel is inside the immutable, Secure-Boot-signed UKI (Phase 1). A
snapper rollback restores the root filesystem but **not** the booted kernel/UKI, which lives on
the ESP and is replaced only by rebuilding + re-signing the image. `apply` detects a
kernel-touching upgrade and warns that the UKI must be rebuilt/re-signed, so you are never
silently left with a kernel that will not boot under Secure Boot.

## Declarative config (`jaa diff`/`apply`)

The Phase-3 stubs are now real. `/etc/jaa/system.toml` (a small, fixed TOML subset) declares
the profile, extra packages, services to enable/disable, and firewall TCP ports. `jaa diff`
shows drift; `jaa apply [--dry-run]` reconciles (apt / systemctl / nft). The file is
**parsed, not executed**. See the shipped `config/rootfs/etc/jaa/system.toml`.

## First Rust port

`crates/jaa-core::scope` ports the security-critical IPv4/CIDR/scope-matching from
`jaa-scan` into shared, unit-tested Rust — the template for porting the rest of the bash
specs (ADR 0002). Its `#[test]`s mirror `tests/vm/vapt-test.sh`, so CI's `cargo test` pins the
behaviour. The CLIs' Rust crates remain clap scaffolds until ported verb-by-verb; they could not
be compiled in this environment (no toolchain), which is why the bash specs stay authoritative.

## Lite live ISO (`make live`)

The full disk image is a fixed-size raw file (`IMG_SIZE`, now 4G by default; it was 12G) and
pulls in vendor firmware, microcode, the UKI tool chain (`systemd-ukify` brings Python),
snapper, BlueZ and the AppArmor utilities. The **lite** profile leaves those out to make a small,
console-first live system that boots from a DVD or USB stick:

| | Full disk image (`make image`) | Lite live ISO (`make live`) |
|---|---|---|
| Size | 4G raw file (was 12G) | **~310 MB** ISO (~190 MB base + ~120 MB Docker/RKE2/installer) |
| Boot | signed UKI, Secure Boot, LUKS2 + Btrfs | GRUB hybrid ISO, BIOS + UEFI, **Secure Boot off** |
| Firmware | WiFi/GPU/NIC firmware + microcode | none by default; `FIRMWARE=1` adds them |
| Persistence | yes | no (live; changes lost on reboot) |

Same base as the image: `config/rootfs` and `build/hooks/10-customize.sh`, so the same sysctl,
nftables, sshd and AppArmor defaults. Live-only changes are in `build/hooks/20-live.sh`: an
empty machine-id, SSH host keys generated at each boot (never shipped in the ISO), and a working
apt source.

Size controls in `build/mklive.sh`: docs, man/info pages and translations are never unpacked
(copyright files are kept). Driver families a console OS does not use are skipped: InfiniBand,
TV/webcam media, staging, ISDN and sound (`TRIM_MODULES=0` keeps them). The squashfs is xz
with the x86 BCJ filter.

Log in as `jaa` / `jaa`; you must choose a new password at first login. Root is locked; use
`sudo`. SSH accepts public keys only and none are installed, so it is closed until you add one.

Built into every ISO (and every installed system):
- **Docker** (Debian `docker.io` + compose), socket-activated, and the **pinned RKE2** release,
  disabled until a role is chosen. See [09-cluster.md](09-cluster.md).
- **`sudo jaa-install`**, which installs to a disk and asks for the Kubernetes role
  (master / worker / none).
- **Shell shortcuts** (`config/rootfs/etc/jaa/shell/`): bash's own Ctrl+A/E/U/K/W/R and Tab
  still work, plus case-insensitive one-Tab completion, Shift+Tab to cycle matches, Up/Down
  history search by prefix, Ctrl+←/→ word jumps, Alt+S to put `sudo` in front, Alt+K for
  `kubectl`, fzf (Ctrl+R fuzzy history, Ctrl+T file picker, Alt+C cd), kubectl/docker
  completion, `k`/`kgp`/`dps`… aliases, and a `[master]`/`[worker]` prompt tag. Run `jaa-keys`
  for the cheat sheet. Each `~/.bashrc` sources it as its last line; delete that line to opt out.

## Build / test (copy-paste)

```bash
cd /home/bijay/Public/jaaOS
make test            # the six sandbox suites (no root, no VM)
make lint            # bash -n + shellcheck
# with a Rust toolchain (e.g. on the cloud):
make rust-lint && make rust-test
# release tooling over a completed build:
make image && make release && ls out/dist/
# lite live ISO (needs root + network to the Debian mirrors), then boot-test it in QEMU:
make live && make live-test && ls -lh out/jaaos-lite.iso
# same, with WiFi/GPU firmware + microcode for real laptops:
make live FIRMWARE=1
```

## Acceptance criteria

- [x] `ci.yml`/`build-image.yml`/`release.yml` are valid workflow YAML. *(validated)*
- [x] `release.sh` produces verifiable checksums, a manifest, an SBOM, and an honest
      signed/unsigned outcome. *(release-test.sh)*
- [x] `jaa-update apply` is snapshot-bracketed and warns on kernel changes; `rollback`
      plans a snapper rollback. *(update-test.sh)*
- [x] `jaa diff`/`apply` parse `system.toml` and reconcile only the drift. *(system-toml-test.sh)*
- [x] `jaa-core::scope` unit tests mirror the bash scope gate. *(cargo test, in CI)*
- [ ] On GitHub: CI is green; `build-image.yml` produces a signed image artifact.
- [ ] On a real host: the image builds, boots (`make vm`), updates, and rolls back.
- [x] Lite live ISO boots to a login prompt on BIOS and UEFI with no failed units. *(live-iso-boot.sh, QEMU)*
- [ ] Live ISO boots to a session offering the TUI + Calamares installers.
- [ ] The Cockpit plugin loads and runs the CLIs.

## Known limitations

1. **Workflows not executed here.** They are YAML-valid and mirror the local `make` targets, but
   GitHub has not run them in this environment. Expect to iterate on apt package names / runner
   images on first run.
2. **No boot-test in CI.** Hosted runners lack nested KVM; `make vm` on a real host is the boot
   gate.
3. **The lite live ISO is unsigned for Secure Boot.** It boots with grub-mkrescue's unsigned
   GRUB, so Secure Boot must be off. Debian's signed shim + GRUB would fix that. It ships the
   TUI installer (`jaa-install`), but not Calamares. It has booted in QEMU only, not on real
   hardware. Without `FIRMWARE=1` most WiFi chips will not work.
   The installer itself (real-disk FDE + signed UKI) has still not been run end to end.
4. **Cockpit plugin is a starter, unaudited** UI that only runs the read-only CLIs; it is optional
   and not part of the default profiles.
5. **Rust is ported incrementally.** Only `jaa-core::scope` is ported so far; the CLI crates
   are still clap scaffolds delegating to the bash specs. No Rust was compiled in this
   environment — CI (or the cloud) is where `cargo build/clippy/test` actually runs.
6. **SBOM is the lean form** (dpkg name/version/arch). A signed CycloneDX/SPDX SBOM needs `syft`
   or similar in the release workflow.
