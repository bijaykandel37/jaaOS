# installer/ — BastionOS installers (Phase 3)

Two paths, both documented in [`../docs/04-phase3-installer.md`](../docs/04-phase3-installer.md):

- **`tui/bastion-install`** — the complete TUI + unattended installer (the primary path). Runs
  from any Debian live/dev environment with the installer tools; partitions a target disk, sets
  up LUKS2 FDE + Btrfs + signed UKI, installs the chosen profile, creates the user, and wires the
  (declarable-only) dual-password home. See `../installer/answers.example.conf` for the
  unattended format.
- **`calamares/`** — the graphical path, wired from Calamares' built-in modules plus a
  `shellprocess` hook (no custom C++ module). Config-only until the live ISO is built in Phase 7.

Design note: the installer creates **only the declarable (decoy) environment**; hidden
environments are added later with `bastion-env add` to avoid install-time evidence. See the
Phase 3 doc §"Key decision".

Test: `sudo tests/vm/install-test.sh` runs the installer unattended against a loopback image.
