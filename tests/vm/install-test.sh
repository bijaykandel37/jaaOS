#!/usr/bin/env bash
# BastionOS Phase 3 installer test: run the installer UNATTENDED against a loopback-backed
# image, producing a bootable disk image you can then start with tests/vm/run-qemu.sh.
#
# RUN AS ROOT ON A DISPOSABLE DEV HOST/VM — it uses loop devices, cryptsetup, and mounts, and
# it downloads a Debian base with mmdebstrap. Not for a workstation with data you care about.
#
# Needs the installer's host tools: mmdebstrap sgdisk cryptsetup btrfs-progs dosfstools
# sbsigntool systemd-ukify openssl (`make deps` covers them).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "root only" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/out"; mkdir -p "$OUT"
IMG="$OUT/install-target.img"
ANS="$OUT/install-answers.conf"

echo "==> Creating a 15G blank target image"
rm -f "$IMG"; truncate -s 15G "$IMG"
LOOP="$(losetup -fP --show "$IMG")"
cleanup() {
	set +e
	for m in $(ls /dev/mapper/ 2>/dev/null | grep -E '^bastion_root$'); do cryptsetup close "$m"; done
	losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

cat > "$ANS" <<EOF
CONFIRM_WIPE=yes
TARGET_DISK=$LOOP
PROFILE=${PROFILE:-minimal}
HOSTNAME=bastion-test
USERNAME=admin
USER_PW=login-pw-demo
FDE_PW=disk-pw-demo
DUAL_ENV=${DUAL_ENV:-yes}
TPM2=no
EOF

echo "==> Running installer unattended against $LOOP"
BASTION_ALLOW_NO_UEFI=1 SUITE="${SUITE:-trixie}" SNAPSHOT="${SNAPSHOT:-20261001T000000Z}" \
	"$REPO/installer/tui/bastion-install" --unattended "$ANS"

echo
echo "PASS: installer completed. Boot the result with:"
echo "    tests/vm/run-qemu.sh $IMG"
echo "(FDE passphrase: disk-pw-demo ; login/home password: login-pw-demo)"
