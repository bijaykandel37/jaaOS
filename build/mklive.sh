#!/usr/bin/env bash
# build/mklive.sh — build a jaaOS live ISO that boots from a DVD or a USB stick (write the .iso
# with dd) on both BIOS and UEFI machines. Two editions:
#   lite    — console only (default)                       -> out/jaaos-lite.iso
#   desktop — lite + XFCE desktop, Firefox, sound, auto-login -> out/jaaos-desktop.iso
#
#   sudo build/mklive.sh                 # -> out/jaaos-lite.iso  (no vendor firmware; VMs + most wired NICs)
#   sudo EDITION=desktop build/mklive.sh # -> out/jaaos-desktop.iso (build/profiles/desktop-xfce.packages)
#   sudo FIRMWARE=1 build/mklive.sh      # + WiFi/GPU firmware and CPU microcode for real laptops
#   sudo AIRGAP=1 build/mklive.sh        # + RKE2 images (~800 MB) so clusters start with no internet
#
# Every build includes Docker, the pinned RKE2 release (build/rke2.lock, disabled until a role is
# chosen), `jaa-cluster`, the `jaa-install` installer and the jaaOS shell shortcuts.
#
# Pipeline: mmdebstrap (build/profiles/lite.packages) -> the same rootfs config + hook as the
# full image (config/rootfs, build/hooks/10-customize.sh) -> live tweaks (build/hooks/20-live.sh)
# -> xz squashfs -> grub-mkrescue hybrid ISO.
#
# Limits (stated honestly):
#   - The ISO boots with grub-mkrescue's UNSIGNED GRUB, so on UEFI you must turn Secure Boot
#     off to boot it. The signed-UKI + LUKS2 Secure Boot chain is the full disk image
#     (build/mkimage.sh), not this ISO.
#   - It is a live system: changes are lost on reboot. Log in as `jaa` / `jaa`; you must
#     choose a new password at first login. SSH accepts public keys only (no keys are
#     installed), so it is unreachable until you add one.
#
# Env overrides:
#   FIRMWARE=1        add build/profiles/lite-firmware.packages (roughly doubles the size)
#   AIRGAP=1          bundle RKE2's core + canal images (otherwise nodes pull them on first start)
#   TRIM_MODULES=0    keep every kernel module (default drops InfiniBand, TV/webcam, staging,
#                     ISDN and sound drivers: a console OS does not use them)
#   COMP=zstd         faster build, larger ISO (default xz = smallest)
#   SNAPSHOT=...      snapshot.debian.org timestamp, pinned for reproducibility
#   MIRROR=... SECMIRROR=...   e.g. MIRROR=https://deb.debian.org/debian SECMIRROR=https://deb.debian.org/debian-security
#   EDITION=desktop   add the XFCE desktop (build/profiles/desktop-xfce.packages); keeps sound
#                     and webcam/TV drivers that the lite edition trims
#   ISO=path          output path (default out/jaaos-<edition>.iso)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
EDITION="${EDITION:-lite}"
case "$EDITION" in
	lite)    LABEL=JAAOS_LITE;    TITLE="jaaOS lite" ;;
	desktop) LABEL=JAAOS_DESKTOP; TITLE="jaaOS desktop" ;;
	*) echo "mklive: EDITION must be lite or desktop" >&2; exit 1 ;;
esac
WORK="$OUT/live-$EDITION"
ISO="${ISO:-$OUT/jaaos-$EDITION.iso}"

SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-amd64}"
SNAPSHOT="${SNAPSHOT:-20261001T000000Z}"
COMPONENTS="main contrib non-free-firmware"
MIRROR="${MIRROR:-https://snapshot.debian.org/archive/debian/${SNAPSHOT}}"
SECMIRROR="${SECMIRROR:-https://snapshot.debian.org/archive/debian-security/${SNAPSHOT}}"
FIRMWARE="${FIRMWARE:-0}"
AIRGAP="${AIRGAP:-0}"
TRIM_MODULES="${TRIM_MODULES:-1}"
COMP="${COMP:-xz}"

DATE_ISO="$(printf '%s' "$SNAPSHOT" | sed -E 's/^(....)(..)(..)T.*/\1-\2-\3/')"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date -u -d "$DATE_ISO" +%s)}"

[ "$(id -u)" -eq 0 ] || { echo "mklive: run as root (sudo $0) — the chroot must keep real file ownership" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "mklive: missing '$1' — sudo apt install $2" >&2; exit 1; }; }
need mmdebstrap mmdebstrap
need mksquashfs squashfs-tools
need xorriso xorriso
need grub-mkrescue grub-common
need mformat mtools
[ -d /usr/lib/grub/i386-pc ]    || { echo "mklive: missing BIOS GRUB — sudo apt install grub-pc-bin" >&2; exit 1; }
[ -d /usr/lib/grub/x86_64-efi ] || { echo "mklive: missing UEFI GRUB — sudo apt install grub-efi-amd64-bin" >&2; exit 1; }

# Debian archive keyring (same pinned + verified keyring as build/mkrootfs.sh), staged
# world-readable so apt's _apt sandbox can read it.
KEYRING="${KEYRING:-$ROOT/build/keyrings/debian-archive-keyring.gpg}"
[ -f "$KEYRING" ] || SNAPSHOT="$SNAPSHOT" "$ROOT/build/fetch-keyring.sh"
KR_STAGE="$(mktemp -p "${TMPDIR:-/tmp}" jaa-keyring.XXXXXX.gpg)"
cp "$KEYRING" "$KR_STAGE"
chmod 0644 "$KR_STAGE"
trap 'rm -f "$KR_STAGE"' EXIT

pkglist() { sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$@"; }
PROFILES=("$ROOT/build/profiles/lite.packages" "$ROOT/build/profiles/cluster.packages")
[ "$FIRMWARE" = 1 ] && PROFILES+=("$ROOT/build/profiles/lite-firmware.packages")
[ "$EDITION" = desktop ] && PROFILES+=("$ROOT/build/profiles/desktop-xfce.packages")
PKGS="$(pkglist "${PROFILES[@]}" | sort -u | paste -sd, -)"

# Size control: never unpack docs, man/info pages, translations or lintian data (copyright
# files are kept for license compliance); optionally skip driver families a console OS never uses.
DPKG_OPTS=(
	--dpkgopt='path-exclude=/usr/share/doc/*'
	--dpkgopt='path-include=/usr/share/doc/*/copyright'
	--dpkgopt='path-exclude=/usr/share/man/*'
	--dpkgopt='path-exclude=/usr/share/info/*'
	--dpkgopt='path-exclude=/usr/share/locale/*'
	--dpkgopt='path-include=/usr/share/locale/locale.alias'
	--dpkgopt='path-exclude=/usr/share/lintian/*'
)
if [ "$TRIM_MODULES" = 1 ]; then
	TRIM_DIRS=(drivers/infiniband drivers/staging drivers/isdn)
	# A desktop needs sound and webcams; the console edition does not.
	[ "$EDITION" = desktop ] || TRIM_DIRS+=(drivers/media sound)
	for d in "${TRIM_DIRS[@]}"; do
		DPKG_OPTS+=(--dpkgopt="path-exclude=/usr/lib/modules/*/kernel/$d/*")
	done
fi

echo "== $TITLE live ISO =="
echo "suite=$SUITE arch=$ARCH firmware=$FIRMWARE airgap=$AIRGAP trim_modules=$TRIM_MODULES comp=$COMP"

# Pinned, hash-verified RKE2 release (fetched before the long rootfs step so a bad pin fails fast).
RKE2_DIR="$(AIRGAP="$AIRGAP" "$ROOT/build/fetch-rke2.sh" | tail -1)"
[ -f "$RKE2_DIR/rke2.linux-amd64.tar.gz" ] || { echo "mklive: RKE2 download failed" >&2; exit 1; }
echo "mirror=$MIRROR"
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

rm -rf "$WORK"
mkdir -p "$WORK/iso/live" "$WORK/iso/boot/grub"
CHROOT="$WORK/chroot"

# 1) Root filesystem.
mmdebstrap \
	--mode=root \
	--variant=minbase \
	--architectures="$ARCH" \
	--components="$COMPONENTS" \
	--keyring="$KR_STAGE" \
	--include="$PKGS" \
	--aptopt='Acquire::Check-Valid-Until "false";' \
	"${DPKG_OPTS[@]}" \
	--customize-hook="sync-in '$ROOT/config/rootfs' /" \
	--customize-hook="copy-in '$ROOT/build/hooks/10-customize.sh' '$ROOT/build/hooks/20-live.sh' /tmp/" \
	--customize-hook="chroot \$1 bash /tmp/10-customize.sh" \
	--customize-hook="chroot \$1 env JAA_EDITION=$EDITION bash /tmp/20-live.sh" \
	--customize-hook="chroot \$1 rm -f /tmp/10-customize.sh /tmp/20-live.sh" \
	"$SUITE" \
	"$CHROOT" \
	"deb [signed-by=${KR_STAGE}] ${MIRROR} ${SUITE} ${COMPONENTS}" \
	"deb [signed-by=${KR_STAGE}] ${SECMIRROR} ${SUITE}-security ${COMPONENTS}"

# 2) jaaOS payload: RKE2 (disabled until a role is chosen), jaa-cluster, and the installer with
#    the data it needs (profiles, hooks, rootfs config, kernel cmdline, jaa-env tooling).
tar -C "$CHROOT/usr/local" -xzf "$RKE2_DIR/rke2.linux-amd64.tar.gz"
install -Dm0755 "$ROOT/packages/jaa-cluster/bin/jaa-cluster" "$CHROOT/usr/bin/jaa-cluster"
SHARE="$CHROOT/usr/share/jaaos"
rm -rf "$SHARE"; mkdir -p "$SHARE/build" "$SHARE/packages" "$SHARE/installer" "$SHARE/kernel"
cp -a "$ROOT/config" "$SHARE/"
cp -a "$ROOT/build/profiles" "$ROOT/build/hooks" "$ROOT/build/rke2.lock" "$ROOT/build/fetch-rke2.sh" "$SHARE/build/"
cp -a "$ROOT/kernel/cmdline" "$SHARE/kernel/"
cp -a "$ROOT/packages/jaa-env" "$ROOT/packages/jaa-cluster" "$SHARE/packages/"
cp -a "$ROOT/installer/tui" "$ROOT/installer/answers.example.conf" "$SHARE/installer/"
ln -sf /usr/share/jaaos/installer/tui/jaa-install "$CHROOT/usr/sbin/jaa-install"
if [ "$AIRGAP" = 1 ]; then
	install -d "$SHARE/rke2/images"
	cp "$RKE2_DIR"/rke2-images-*.tar.zst "$SHARE/rke2/images/"
fi
echo "RKE2 $(sed -n 's/^RKE2_VERSION=//p' "$ROOT/build/rke2.lock") installed (disabled until 'jaa-cluster setup')"

# 3) Kernel + initramfs go next to the squashfs; they are not needed again inside it.
KVER="$(find "$CHROOT/boot" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V | tail -1)"
[ -n "$KVER" ] || { echo "mklive: no kernel found in the chroot" >&2; exit 1; }
cp "$CHROOT/boot/vmlinuz-$KVER" "$WORK/iso/live/vmlinuz"
cp "$CHROOT/boot/initrd.img-$KVER" "$WORK/iso/live/initrd.img"

# 4) Squash the filesystem.
SQ_COMP=(-comp "$COMP")
[ "$COMP" = xz ] && SQ_COMP+=(-Xbcj x86 -b 1M)
mksquashfs "$CHROOT" "$WORK/iso/live/filesystem.squashfs" -noappend "${SQ_COMP[@]}" \
	-wildcards -e 'boot/*' 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*'

# 5) Boot menu. Same hardening flags as the disk image (kernel/cmdline), minus its disk root.
CMDLINE="$(sed -e 's/#.*//' "$ROOT/kernel/cmdline" | tr -s '[:space:]' ' ' \
	| sed -E -e 's/(^| )root=[^ ]*//g' -e 's/(^| )ro( |$)/ /g' -e 's/^ +| +$//g')"
cat > "$WORK/iso/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0
insmod all_video

menuentry "$TITLE (live)" {
	linux /live/vmlinuz boot=live $CMDLINE
	initrd /live/initrd.img
}
menuentry "$TITLE (live, copy to RAM — the USB stick can be removed)" {
	linux /live/vmlinuz boot=live toram $CMDLINE
	initrd /live/initrd.img
}
menuentry "$TITLE (live, safe graphics)" {
	linux /live/vmlinuz boot=live nomodeset $CMDLINE
	initrd /live/initrd.img
}
EOF

# 6) Hybrid ISO: BIOS (El Torito + MBR) and UEFI (EFI system image), dd-able to USB.
rm -f "$ISO"
grub-mkrescue -o "$ISO" "$WORK/iso" -- -volid "$LABEL" 2>&1 | grep -v '^xorriso : UPDATE' || true
[ -s "$ISO" ] || { echo "mklive: grub-mkrescue did not produce $ISO" >&2; exit 1; }
(cd "$(dirname "$ISO")" && sha256sum "$(basename "$ISO")" > "$(basename "$ISO").sha256")

echo
echo "Wrote $ISO ($(du -h "$ISO" | cut -f1)), kernel $KVER"
echo "  squashfs: $(du -h "$WORK/iso/live/filesystem.squashfs" | cut -f1)   checksum: $ISO.sha256"
echo "Write to a USB stick (replace sdX with the stick, NOT your system disk):"
echo "  sudo dd if=$ISO of=/dev/sdX bs=4M status=progress conv=fsync"
