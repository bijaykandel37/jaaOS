# BastionOS — Phase 1: Bootable minimal hardened image

Status: **built in code, not yet executed end-to-end in this environment** (full image
assembly needs a Debian build host with root + loop devices + network; the scripts are
syntax-checked and the pipeline is coherent, but the first real run on your hardware may
need minor package-name tweaks — see Known limitations).

## Goal

A minimal, reproducible, **encrypted, Secure-Boot, hardened** BastionOS disk image that boots
in QEMU (UEFI + TPM2) to a login, with Btrfs + snapper snapshots. This is the installed-system
base every profile builds on. The graphical/live **installer ISO** is Phase 3 — see the note
below on why Phase 1 ships a disk image, not a live ISO.

### Why a disk image, not a live ISO (scope honesty)

The product's "minimal ISO" is a live installer, whose job is to *create* an encrypted system
on a target. You cannot meaningfully demonstrate FDE + Secure Boot + snapshots from a live ISO
(it is unencrypted and ephemeral). So Phase 1 produces the **thing the installer will later
write** — a bootable encrypted image — which is directly testable now. The installer that
wraps this logic is Phase 3.

## What this phase delivers

| Capability | How |
|---|---|
| Reproducible base | `mmdebstrap` pinned to `snapshot.debian.org` + `SOURCE_DATE_EPOCH` |
| Full-disk encryption | LUKS2, Argon2id (1 GiB mem, 4 lanes), aes-xts-plain64/512 |
| Secure Boot | Signed **UKI** (kernel+initrd+cmdline as one PE) + signed systemd-boot, own PK/KEK/db keys |
| Boot integrity | `editor no` in loader.conf; immutable signed cmdline |
| Kernel hardening | lockdown=confidentiality, `module.sig_enforce`, KSPP cmdline + sysctl, AppArmor LSM |
| MAC | AppArmor enforcing |
| Firewall | nftables default-deny inbound (SSH open) |
| SSH | key-only, no root, modern crypto |
| Swap | zram (RAM-only, ephemeral) — no plaintext pages on disk, no hibernation |
| /tmp, /var/tmp | tmpfs |
| Snapshots | Btrfs subvolumes + snapper `root` config + pre-apt snapshot hook |
| Audit | auditd + baseline ruleset |

## Files in this phase

| File | Purpose |
|---|---|
| `build/profiles/minimal.packages` | Minimal profile package set (trixie). |
| `kernel/cmdline` | Baked (VM-safe) hardened kernel command line. |
| `kernel/cmdline.hardened` | Opt-in aggressive variant (IOMMU/nosmt) — test before use. |
| `config/rootfs/etc/sysctl.d/99-bastion-hardening.conf` | KSPP/CIS sysctls (with the userns trade-off documented). |
| `config/rootfs/etc/modprobe.d/bastion-hardening.conf` | Blacklist of obscure modules. |
| `config/rootfs/etc/nftables.conf` | Default-deny firewall + managed open-port set. |
| `config/rootfs/etc/ssh/sshd_config.d/99-bastion.conf` | SSH hardening. |
| `config/rootfs/etc/systemd/zram-generator.conf` | zram swap. |
| `config/rootfs/etc/initramfs-tools/conf.d/resume` | Disable hibernation/resume. |
| `config/rootfs/etc/apt/apt.conf.d/80bastion-snapshot` | Pre-apt snapshot hook wiring. |
| `config/rootfs/usr/local/sbin/bastion-apt-snapshot` | The snapshot helper (safe no-op until snapper is configured). |
| `build/hooks/10-customize.sh` | In-chroot static config (locale, user, services, auditd, AppArmor). |
| `build/secureboot.sh` | Generate PK/KEK/db keys + enrollment ESLs (idempotent). |
| `build/mkrootfs.sh` | Reproducible rootfs tarball. |
| `build/mkimage.sh` | Assemble the encrypted, signed, bootable image. |
| `build/build.sh` | One-command orchestration of the three steps. |
| `tests/vm/run-qemu.sh` | Boot in QEMU with OVMF + swtpm (+ optional SB enrollment). |
| `tests/vm/checks.sh` | In-VM acceptance checks (PASS/FAIL). |

## Build (copy-paste)

```bash
# 1. Host build dependencies (Debian/Ubuntu build host)
sudo apt update
sudo apt install -y mmdebstrap uidmap gdisk cryptsetup-bin btrfs-progs dosfstools \
  sbsigntool efitools openssl uuid-runtime qemu-system-x86 qemu-utils ovmf swtpm

# 2. Build everything (keys -> rootfs -> encrypted signed image)
cd /home/bijay/Public/jaaOS
bash build/build.sh
# Output: out/bastionos-minimal.img  (demo FDE passphrase: "bastion")

# Optional: reproducibility check — two rootfs builds should match
bash build/mkrootfs.sh && sha256sum out/rootfs.tar | tee /tmp/a
bash build/mkrootfs.sh && sha256sum out/rootfs.tar | tee /tmp/b
diff /tmp/a /tmp/b && echo "rootfs reproducible"
```

## Test (copy-paste)

```bash
cd /home/bijay/Public/jaaOS
# Enable enforced Secure Boot in the VM (optional but recommended):
pipx install virt-firmware 2>/dev/null || sudo apt install -y python3-virt-firmware || true

# Boot. Enter the LUKS passphrase "bastion" at the prompt. Log in as bastion/bastion.
bash tests/vm/run-qemu.sh

# Inside the VM, run the acceptance checks:
#   sudo bash /path/to/checks.sh
# (scp it in via: scp -P 2222 tests/vm/checks.sh bastion@localhost: )
```

## Acceptance criteria

- [ ] Image boots in QEMU under UEFI; prompts for the LUKS passphrase; unlocks and reaches login.
- [ ] `tests/vm/checks.sh` reports **0 failed** (all hardening, crypto, snapshot, firewall, SSH checks pass).
- [ ] With keys enrolled, `bootctl status` shows `Secure Boot: enabled` and the UKI as the boot entry.
- [ ] `apt-get install <pkg>` creates a pre-change snapper snapshot automatically.
- [ ] Two `mkrootfs.sh` runs produce identical `rootfs.tar` checksums.
- [ ] Minimal idle footprint measured and recorded (target ~400–600 MB RAM, ~3–4 GB disk).

## Known limitations / honest caveats

1. **Not yet executed here.** I wrote and syntax-checked the scripts; I did not build the image
   in this session (no Debian build host/root/network). Expect to iterate on 1–2 trixie package
   names (e.g. `systemd-boot` vs a split `systemd-boot-efi`) on first run — each is a one-line
   fix in `minimal.packages`.
2. **TPM2 auto-unlock is deferred to first boot, by design.** You cannot seal a key to PCRs that
   don't exist at build time. Phase 1 ships passphrase unlock; a `bastion-tpm-enroll` helper
   (`systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes`) runs on the real machine. Only
   the **declarable** volume will ever get a TPM token — never Environment B (Phase 2 / threat
   model).
3. **Bootable snapshot menu entries are not in Phase 1.** A signed, immutable UKI command line
   can't be edited at boot to select a different Btrfs subvolume, so per-snapshot boot entries
   need per-snapshot UKIs (or an unsigned cmdline, which we refuse). Phase 1 delivers snapshot
   *creation* + `snapper rollback`; the boot-menu rollback UX is finalized in Phase 7, with the
   UKI-immutability trade-off documented.
4. **Reproducibility is of the rootfs, not the encrypted image.** LUKS salts/keys are random by
   definition, so `*.img` is not bit-identical across builds; the *rootfs contents* are.
5. **Demo credentials** (`bastion`/`bastion`, LUKS `bastion`) are for the throwaway VM only. The
   installer (Phase 3) sets real credentials; never ship the demo image.
6. **Secure Boot enforcement in the VM** depends on `virt-firmware` to enroll keys into OVMF; if
   absent, the VM boots UEFI without enforcement (the on-disk binaries are still signed, so this
   is a test-harness limitation, not an image defect).

## Next: Phase 2 — dual-password environments (design, VM prototype, leakage + forensic tests)
