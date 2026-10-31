#!/usr/bin/env bash
# Build a REPRODUCIBLE Debian 13 rootfs for the Minimal profile, pinned to a
# snapshot.debian.org timestamp. Output: out/rootfs.tar
#
# Runs rootless (mmdebstrap unshare mode) if `uidmap` is installed; no sudo needed.
# Override defaults via env, e.g.  SNAPSHOT=20261015T000000Z build/mkrootfs.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
mkdir -p "$OUT"

SUITE="${SUITE:-trixie}"
ARCH="${ARCH:-amd64}"
SNAPSHOT="${SNAPSHOT:-20261001T000000Z}"
COMPONENTS="main contrib non-free-firmware"
MIRROR="http://snapshot.debian.org/archive/debian/${SNAPSHOT}"
SECMIRROR="http://snapshot.debian.org/archive/debian-security/${SNAPSHOT}"

# Deterministic timestamps from the snapshot date (YYYYMMDD -> epoch).
DATE_ISO="$(printf '%s' "$SNAPSHOT" | sed -E 's/^(....)(..)(..)T.*/\1-\2-\3/')"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date -u -d "$DATE_ISO" +%s)}"

command -v mmdebstrap >/dev/null 2>&1 || {
	echo "mmdebstrap not found. Install: sudo apt install mmdebstrap uidmap" >&2
	exit 1
}

# Comma-separated include list from the profile file (strip comments/blank lines).
PKGS="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$ROOT/build/profiles/minimal.packages" \
	| tr -d '[:space:]' | paste -sd, -)"

echo "Building rootfs: suite=$SUITE arch=$ARCH snapshot=$SNAPSHOT"
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

rm -f "$OUT/rootfs.tar"
mmdebstrap \
	--variant=minbase \
	--architectures="$ARCH" \
	--components="$COMPONENTS" \
	--include="$PKGS" \
	--aptopt='Acquire::Check-Valid-Until "false";' \
	--dpkgopt='path-exclude=/usr/share/doc/*' \
	--dpkgopt='path-exclude=/usr/share/man/*' \
	--customize-hook="sync-in '$ROOT/config/rootfs' /" \
	--customize-hook="copy-in '$ROOT/build/hooks/10-customize.sh' /tmp/" \
	--customize-hook="chroot \$1 bash /tmp/10-customize.sh" \
	--customize-hook="chroot \$1 rm -f /tmp/10-customize.sh" \
	"$SUITE" \
	"$OUT/rootfs.tar" \
	"deb ${MIRROR} ${SUITE} ${COMPONENTS}" \
	"deb ${SECMIRROR} ${SUITE}-security ${COMPONENTS}"

echo "Wrote $OUT/rootfs.tar ($(du -h "$OUT/rootfs.tar" | cut -f1))"
