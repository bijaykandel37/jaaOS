#!/usr/bin/env bash
# One-command Phase 1 build: Secure Boot keys -> reproducible rootfs -> disk image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== [1/3] Secure Boot keys =="
"$ROOT/build/secureboot.sh"

echo "== [2/3] Reproducible rootfs =="
"$ROOT/build/mkrootfs.sh"

echo "== [3/3] Disk image (root required) =="
if [ "$(id -u)" -ne 0 ]; then
	sudo CMDLINE="${CMDLINE:-}" IMG_SIZE="${IMG_SIZE:-}" LUKS_PASSPHRASE="${LUKS_PASSPHRASE:-}" \
		"$ROOT/build/mkimage.sh"
else
	"$ROOT/build/mkimage.sh"
fi

echo
echo "Build complete: $ROOT/out/bastionos-minimal.img"
echo "Boot it with:   tests/vm/run-qemu.sh"
