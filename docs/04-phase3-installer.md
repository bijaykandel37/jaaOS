# jaaOS — Phase 3: Installer with profiles

Status: **written and syntax-checked; not yet run** (a real install needs a live/dev environment
and a target disk in a VM — see Test plan). The installer reuses the Phase 1 image logic against
a real disk, adds profile selection, creates the user + the declarable environment, and wires
dual-env/PAM.

## Goal

Install jaaOS onto a target disk — interactively (TUI, server-friendly) or via Calamares
(graphical) — with a chosen profile, hardened FDE, Secure Boot (signed UKI), Btrfs+snapper, a
user, and (optionally) the dual-password home. Every profile component is a toggle and can be
added later with one command (`jaa install <component>`).

## Key decision: the installer creates ONLY the declarable environment

When dual-env is enabled, the installer sets up the system + **one** home environment (the
decoy / primary) whose password is the user's login password, writes `/etc/jaa-env/config`,
and wires PAM. It does **not** create any hidden environment. Hidden environments are added
afterwards with `jaa-env add`, run by the user when unobserved.

Why: creating a hidden environment *at install time* would leave exactly the evidence the feature
is meant to avoid — installer logs, the observable act of entering a second password, answer
files, timestamps. A fresh jaaOS install is therefore **indistinguishable** from one that
will only ever have one environment, which is the strongest honest posture. (It also keeps the
installer simple and avoids putting a second KDF/volume setup in a disk-writing tool.) This is a
deliberate trade of convenience for deniability; documented, not hidden.

## How the home relates to full-disk encryption (important)

Two unlock steps exist by design when dual-env is on:

1. **Boot FDE** — the main LUKS2 volume (system: `/`, `/var`, …) unlocks at boot via TPM2+PIN or
   passphrase. Same as Phase 1.
2. **Login** — `/home/<user>` is a **separate** jaa-env container unlocked by the *login
   password* via PAM (Phase 2), **not** the main volume's `@home` subvolume.

So the main volume holds the system; the home is its own encrypted container the PAM layer
mounts. When dual-env is off, `/home` is just the main volume's `@home` subvolume (Phase 1
behaviour) and there is only the boot unlock.

## Graphical vs TUI — and why no custom Calamares C++ module

- **TUI installer** (`installer/tui/jaa-install`): the primary, fully-controlled path, ideal
  for servers and for the deniable-FDE flow. Shell, because it is orchestration driving
  `sgdisk`/`cryptsetup`/`mmdebstrap`/`ukify` (consistent with ADR 0002 — rewriting it in Rust
  would add code, not speed). Supports an **unattended** answer file for CI.
- **Calamares** (`installer/calamares/`): the graphical path, wired from Calamares' *built-in*
  modules (partition, luks, users, `packagechooser` for profiles) plus `shellprocess`/
  `contextualprocess` hooks that call our scripts for profile install and dual-env setup. We
  deliberately avoid writing a custom C++ Calamares module (unmaintainable solo); the custom
  logic lives in our scripts that Calamares invokes. Calamares' LUKS module creates a standard
  container — which is exactly right, because the installer only makes the declarable volume.

## Profiles → packages

The installer always installs `build/profiles/minimal.packages`, then appends the chosen
profile's extras:

| Profile | Extra list | Notes |
|---|---|---|
| Minimal | — | Phase 1 base only. |
| Server | `server.packages` | Podman + node-exporter starter set; hosting (Phase 4) and monitoring (Phase 5) expand it. |
| Desktop | `desktop.packages` | GNOME (Wayland) + Flatpak. |
| Security Lab | `security-lab.packages` | Desktop + container runtime; the VAPT tools are containerized in Phase 6, not host packages. |

These become real APT meta-packages (`jaaos-profile-*`) once the overlay repo is built
(Phase 7); until then the installer consumes the lists directly.

## Files in this phase

| File | Purpose |
|---|---|
| `installer/tui/jaa-install` | Interactive + unattended TUI installer (the main deliverable). |
| `installer/answers.example.conf` | Example unattended answer file. |
| `installer/calamares/settings.conf` | Calamares module sequence. |
| `installer/calamares/modules/packagechooser.conf` | Profile selection in the GUI. |
| `installer/calamares/modules/shellprocess-jaa.conf` | Post-install hook: profile packages + dual-env setup. |
| `installer/calamares/branding/jaaos/branding.desc` | Minimal branding. |
| `build/profiles/server.packages` | Server profile extras. |
| `build/profiles/desktop.packages` | Desktop profile extras. |
| `build/profiles/security-lab.packages` | Security Lab profile extras. |
| `packages/jaa/bin/jaa` | `jaa install <component>` (+ `diff`/`apply` stubs for the Phase-7 declarative config). |
| `tests/vm/install-test.sh` | Unattended-install harness against a scratch disk in QEMU. |

## Build / test (copy-paste)

```bash
cd /home/bijay/Public/jaaOS
# Syntax check
bash -n installer/tui/jaa-install packages/jaa/bin/jaa tests/vm/install-test.sh

# End-to-end install test (needs a Debian/dev host with qemu + the Phase 1 tools):
#  1. Build the Phase 1 image (make image) to use as a live/dev environment, OR run the
#     installer from any Debian live system that has: mmdebstrap sgdisk cryptsetup btrfs-progs
#     dosfstools sbsigntool systemd-ukify whiptail tpm2-tools.
#  2. Create a blank target disk and drive the installer unattended:
bash tests/vm/install-test.sh
```

Interactive run (inside a live/dev VM, as root), against e.g. /dev/vdb:

```bash
sudo installer/tui/jaa-install
# or unattended:
sudo installer/tui/jaa-install --unattended installer/answers.example.conf
```

## Acceptance criteria

- [ ] Unattended install onto a blank VM disk completes without error and the result boots to a
      login (reusing `tests/vm/run-qemu.sh` against the installed disk).
- [ ] Profile selection installs the expected package set; `jaa install <component>` adds a
      component afterwards.
- [ ] With dual-env enabled, the login password unlocks `/home/<user>`, `/etc/jaa-env/config`
      has `MANAGED_USER` set, and PAM is wired; **no** hidden environment exists until
      `jaa-env add` is run.
- [ ] TPM2+PIN enrollment (when chosen) unlocks the boot volume on next boot; a wrong PIN falls
      back to the passphrase.
- [ ] The installer refuses to proceed without an explicit, typed disk-wipe confirmation.

## Known limitations

1. **Not yet run.** Syntax-checked only; a real install needs a VM with a target disk. Expect the
   same trixie package-name iteration noted in Phase 1.
2. **No live ISO yet.** The installer runs from any Debian live/dev environment with the listed
   tools; the bootable *live ISO* that ships it (and Calamares) is Phase 7.
3. **Calamares path is config-only here.** The provided configs wire Calamares to our scripts;
   they need the `calamares` package and a live ISO to exercise (Phase 7).
4. **mmdebstrap-over-network install.** The installer debootstraps from `snapshot.debian.org`; a
   squashfs-unpack install (faster, offline) is a Phase 7 optimization.
5. **Secure Boot key enrollment** into firmware still needs Setup Mode (the installer generates
   and signs with the machine's own keys and prints enrollment steps).
