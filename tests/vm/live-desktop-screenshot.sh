#!/usr/bin/env bash
# tests/vm/live-desktop-screenshot.sh — boot out/jaaos-desktop.iso in QEMU, wait for the
# system to finish booting, give the desktop time to start, then save the (virtual) screen as a PNG.
#
#   bash tests/vm/live-desktop-screenshot.sh            # -> out/desktop-screenshot.png
#
# Needs qemu-system-x86 (+ ovmf for MODE=uefi). Uses KVM when available; under plain emulation
# the desktop takes a few minutes to appear (SETTLE seconds after boot, default 150).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ISO="${ISO:-$ROOT/out/jaaos-desktop.iso}"
SHOT="${SHOT:-$ROOT/out/desktop-screenshot.png}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
SETTLE="${SETTLE:-150}"
MODE="${MODE:-bios}"

[ -f "$ISO" ] || { echo "no ISO at $ISO — run: sudo EDITION=desktop build/mklive.sh" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "missing qemu-system-x86_64" >&2; exit 1; }
ACCEL=(-accel tcg -cpu Haswell-noTSX)
[ -w /dev/kvm ] && ACCEL=(-accel kvm -cpu host)

tmp="$(mktemp -d)"
qpid=""
cleanup() { [ -n "$qpid" ] && kill "$qpid" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
FW=()
if [ "$MODE" = uefi ]; then
	cp /usr/share/OVMF/OVMF_VARS_4M.fd "$tmp/vars.fd"
	FW=(-drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd" -drive "if=pflash,format=raw,file=$tmp/vars.fd")
fi

qemu-system-x86_64 "${ACCEL[@]}" -m 4096 -smp 4 "${FW[@]}" -cdrom "$ISO" -boot d \
	-vga virtio -display none -serial "file:$tmp/serial.log" \
	-monitor "unix:$tmp/mon.sock,server=on,wait=off" -nic user,model=virtio-net-pci &
qpid=$!

# The kernel cmdline has `quiet`, so systemd prints no "Started …" lines: wait for the serial
# login prompt (end of boot), then give lightdm + the XFCE session time to come up.
echo "== waiting for boot to finish (timeout ${BOOT_TIMEOUT}s) =="
start=$SECONDS
until grep -qa 'login:' "$tmp/serial.log" 2>/dev/null; do
	kill -0 "$qpid" 2>/dev/null || { echo "FAIL: QEMU exited"; exit 1; }
	[ $((SECONDS - start)) -lt "$BOOT_TIMEOUT" ] || { echo "FAIL: did not finish booting"; tail -20 "$tmp/serial.log"; exit 1; }
	sleep 3
done
echo "booted after $((SECONDS - start))s; letting the desktop settle ${SETTLE}s"
sleep "$SETTLE"

python3 - "$tmp/mon.sock" "$tmp/shot.ppm" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.5)
s.sendall(f"screendump {sys.argv[2]}\n".encode()); time.sleep(3); s.close()
PY
[ -s "$tmp/shot.ppm" ] || { echo "FAIL: no screendump"; exit 1; }
python3 - "$tmp/shot.ppm" "$SHOT" <<'PY'
# PPM (P6) -> PNG with the standard library only.
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
parts, pos = [], 0
while len(parts) < 4:
    while data[pos:pos+1].isspace(): pos += 1
    if data[pos:pos+1] == b"#":
        pos = data.index(b"\n", pos) + 1; continue
    end = pos
    while not data[end:end+1].isspace(): end += 1
    parts.append(data[pos:end]); pos = end
pos += 1
w, h = int(parts[1]), int(parts[2])
px = data[pos:pos + w * h * 3]
raw = b"".join(b"\x00" + px[y*w*3:(y+1)*w*3] for y in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
print(f"PASS: wrote {sys.argv[2]} ({w}x{h})")
PY
if grep -qaE 'Failed to start' "$tmp/serial.log"; then
	echo "WARN: units failed during boot:"; grep -aoE 'Failed to start [^ ]+' "$tmp/serial.log" | sort -u
fi
