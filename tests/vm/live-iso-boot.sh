#!/usr/bin/env bash
# tests/vm/live-iso-boot.sh — boot out/jaaos-lite.iso in QEMU and wait for the login prompt on
# the serial console. Checks both firmware paths of the hybrid ISO.
#
#   bash tests/vm/live-iso-boot.sh            # BIOS + UEFI
#   bash tests/vm/live-iso-boot.sh uefi       # one mode only (bios | uefi)
#
# Needs qemu-system-x86 (+ ovmf for UEFI). Uses KVM when /dev/kvm exists, otherwise plain
# emulation (slower; BOOT_TIMEOUT defaults to 600 s). No root needed; nothing is written to disk.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ISO="${ISO:-$ROOT/out/jaaos-lite.iso}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
MODES=("${@:-bios}")
[ $# -eq 0 ] && MODES=(bios uefi)

[ -f "$ISO" ] || { echo "no ISO at $ISO — run: sudo build/mklive.sh" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "missing qemu-system-x86_64 — sudo apt install qemu-system-x86 ovmf" >&2; exit 1; }

ACCEL=(-accel tcg)
[ -w /dev/kvm ] && ACCEL=(-accel kvm -cpu host)

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
for mode in "${MODES[@]}"; do
	FW=()
	if [ "$mode" = uefi ]; then
		code=/usr/share/OVMF/OVMF_CODE_4M.fd; vars=/usr/share/OVMF/OVMF_VARS_4M.fd
		[ -f "$code" ] || { code=/usr/share/OVMF/OVMF_CODE.fd; vars=/usr/share/OVMF/OVMF_VARS.fd; }
		[ -f "$code" ] || { echo "missing OVMF — sudo apt install ovmf" >&2; exit 1; }
		cp "$vars" "$tmp/vars.fd"
		FW=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$tmp/vars.fd")
	fi
	log="$tmp/serial-$mode.log"
	echo "== $mode: booting $(basename "$ISO") (timeout ${BOOT_TIMEOUT}s) =="
	start=$SECONDS
	timeout "$BOOT_TIMEOUT" qemu-system-x86_64 "${ACCEL[@]}" -m 2048 -smp 2 "${FW[@]}" \
		-cdrom "$ISO" -boot d -display none -serial "file:$log" -monitor none -nic user,model=virtio-net-pci &
	qpid=$!
	ok=0
	while kill -0 "$qpid" 2>/dev/null; do
		if grep -q 'login:' "$log" 2>/dev/null; then ok=1; break; fi
		sleep 2
	done
	kill "$qpid" 2>/dev/null || true; wait "$qpid" 2>/dev/null || true
	failed_units="$(grep -aoE 'Failed to start [^ ]+ ?[^ ]*' "$log" | sed 's/\x1b\[[0-9;]*m//g' | sort -u || true)"
	if [ "$ok" = 1 ] && [ -n "$failed_units" ]; then
		echo "FAIL $mode: reached login, but units failed during boot:"
		printf '  %s\n' "$failed_units"
		fail=1
	elif [ "$ok" = 1 ]; then
		echo "PASS $mode: login prompt after $((SECONDS - start))s, no failed units"
		grep -aE 'Debian GNU/Linux|jaa login' "$log" | tail -2 || true
	else
		echo "FAIL $mode: no login prompt; last serial lines:"
		tail -30 "$log" || true
		fail=1
	fi
	cp "$log" "$ROOT/out/live-boot-$mode.log" 2>/dev/null || true
done
exit "$fail"
