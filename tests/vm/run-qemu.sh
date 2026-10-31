#!/usr/bin/env bash
# Boot the jaaOS image in QEMU under UEFI (OVMF) with an emulated TPM2 (swtpm).
# If python-virt-firmware is present, our Secure Boot keys are enrolled into the VM's
# OVMF variables so Secure Boot is actually ENFORCED; otherwise it boots UEFI without
# enforcement and says so (the on-disk binaries are signed either way).
#
#   tests/vm/run-qemu.sh [path-to-image]
#
# Serial console is on stdio; log in as user "jaa" (password "jaa" for the demo
# image) or ssh to localhost:2222. LUKS passphrase at boot is the demo "jaa".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMG="${1:-$ROOT/out/jaaos-minimal.img}"
KEYS="$ROOT/build/secureboot/keys"
WORK="$ROOT/out/vm"; mkdir -p "$WORK"

[ -f "$IMG" ] || { echo "Image not found: $IMG (run build/build.sh)" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "Install: sudo apt install qemu-system-x86 ovmf swtpm" >&2; exit 1; }

OVMF_CODE="$(ls /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd 2>/dev/null | head -n1 || true)"
OVMF_VARS_SRC="$(ls /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd 2>/dev/null | head -n1 || true)"
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || { echo "OVMF not found. Install: sudo apt install ovmf" >&2; exit 1; }
cp -f "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"

SB_NOTE="Secure Boot: NOT enforced (UEFI only)."
if command -v virt-fw-vars >/dev/null 2>&1 && [ -f "$KEYS/db.esl" ]; then
	GUID="$(cat "$KEYS/guid")"
	if virt-fw-vars -i "$WORK/OVMF_VARS.fd" -o "$WORK/OVMF_VARS.fd" \
		--set-pk  "$GUID" "$KEYS/PK.esl" \
		--add-kek "$GUID" "$KEYS/KEK.esl" \
		--add-db  "$GUID" "$KEYS/db.esl" \
		--secure-boot >/dev/null 2>&1; then
		SB_NOTE="Secure Boot: ENFORCED (jaaOS keys enrolled)."
	else
		SB_NOTE="Secure Boot: enrollment failed; booting UEFI only."
	fi
else
	echo "NOTE: virt-fw-vars or .esl files missing — Secure Boot will not be enforced."
	echo "      Enable with: pipx install virt-firmware  (and run build/secureboot.sh with efitools)"
fi
echo "$SB_NOTE"

# Emulated TPM2
TPMDIR="$WORK/tpm"; mkdir -p "$TPMDIR"
if command -v swtpm >/dev/null 2>&1; then
	swtpm socket --tpmstate dir="$TPMDIR" --ctrl type=unixio,path="$WORK/tpm-sock" --tpm2 -d
	TPM_ARGS=(-chardev "socket,id=chrtpm,path=$WORK/tpm-sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0)
	trap 'pkill -f "swtpm.*$WORK/tpm-sock" 2>/dev/null || true' EXIT
else
	echo "NOTE: swtpm not installed — booting without a TPM (passphrase unlock still works)."
	TPM_ARGS=()
fi

ACCEL="tcg"; [ -w /dev/kvm ] && ACCEL="kvm:tcg"

echo "Booting $IMG  (Ctrl-A X to quit the serial console)"
exec qemu-system-x86_64 \
	-machine q35,smm=on,accel="$ACCEL" -cpu max -m 4096 -smp 2 \
	-global driver=cfi.pflash01,property=secure,value=on \
	-drive if=pflash,format=raw,unit=0,file="$OVMF_CODE",readonly=on \
	-drive if=pflash,format=raw,unit=1,file="$WORK/OVMF_VARS.fd" \
	"${TPM_ARGS[@]}" \
	-drive file="$IMG",format=raw,if=virtio,cache=none \
	-netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
	-nographic -serial mon:stdio
