#!/usr/bin/env bash
# build/mklive.sh — build a LIVE ISO (try-before-install) from the reproducible rootfs.
#
# STATUS: Phase 7 SCAFFOLD — syntax-checked, NOT yet built or booted here. It documents the
# intended pipeline and wires the real tools; run it on a Debian host with the deps below and
# iterate. Do not describe its output as "tested" until an ISO has actually booted.
#
# Approach (no from-scratch live system — reuse what Phase 1 already builds):
#   1. reuse out/rootfs.tar (build/mkrootfs.sh) as the live filesystem,
#   2. add live-boot + a desktop/installer so it boots to a session with Calamares,
#   3. pack it to squashfs, assemble an EFI-bootable ISO with the SIGNED kernel/UKI path,
#   4. the live session offers `bastion-install` (TUI) and Calamares (GUI) from Phase 3.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
ROOTFS_TAR="$OUT/rootfs.tar"
WORK="$OUT/live"
ISO="$OUT/bastionos-live.iso"

need() { command -v "$1" >/dev/null 2>&1 || { echo "mklive: missing '$1' — sudo apt install $2" >&2; exit 1; }; }
echo "== BastionOS live ISO (Phase 7 scaffold) =="
need mksquashfs squashfs-tools
need xorriso xorriso
[ -f "$ROOTFS_TAR" ] || { echo "mklive: $ROOTFS_TAR not found — run 'make rootfs' first" >&2; exit 1; }

echo "NOTE: this is a scaffold. It assembles the squashfs + ISO layout but the live-boot package"
echo "      set, the signed EFI boot path, and a booted session are NOT yet validated. See"
echo "      docs/08-phase7-release.md for what remains."

rm -rf "$WORK"; mkdir -p "$WORK/chroot" "$WORK/iso/live" "$WORK/iso/EFI/BOOT"

# 1) Unpack the rootfs into a chroot we can augment with live-boot + the installer.
#    (mmdebstrap unshare keeps this rootless where supported.)
tar -C "$WORK/chroot" -xf "$ROOTFS_TAR"

# 2) Add the live/install payload. On a real build this installs live-boot, the chosen desktop,
#    and Calamares into the chroot (reuse build/profiles/desktop.packages + installer/calamares).
echo "TODO(real build): chroot $WORK/chroot apt-get install -y live-boot calamares <desktop>"

# 3) Squash the filesystem.
mksquashfs "$WORK/chroot" "$WORK/iso/live/filesystem.squashfs" -noappend -comp zstd

# 4) Assemble an EFI-bootable ISO. On a real build the EFI binary is the SIGNED UKI from
#    build/mkimage.sh so Secure Boot stays intact; here we only lay out the tree.
echo "TODO(real build): place the signed systemd-boot/UKI under $WORK/iso/EFI/BOOT/BOOTX64.EFI"
xorriso -as mkisofs -o "$ISO" \
	-V BASTIONOS_LIVE \
	-e EFI/BOOT/BOOTX64.EFI -no-emul-boot -isohybrid-gpt-basdat \
	"$WORK/iso" 2>/dev/null || {
		echo "mklive: ISO assembly needs the EFI boot payload (see TODO above) — scaffold stops here."
		exit 0
	}
echo "Wrote $ISO (scaffold)."
