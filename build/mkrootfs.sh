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

# Debian archive keyring — needed to verify the (Debian) snapshot archive's signatures. It is
# NOT installed by default on non-Debian hosts (e.g. Ubuntu ships only ubuntu-archive-keyring),
# and even when present it is often TOO OLD to contain the Debian 13 (trixie) keys — both make
# mmdebstrap fail with "NO_PUBKEY / repository is not signed". We therefore default to a keyring
# pulled from the pinned snapshot by build/fetch-keyring.sh (known to carry the trixie keys), and
# pass it to mmdebstrap explicitly so verification is deterministic regardless of the host distro.
# Override with KEYRING=/path to use your own.
KEYRING="${KEYRING:-}"
if [ -z "$KEYRING" ]; then
	KEYRING="$ROOT/build/keyrings/debian-archive-keyring.gpg"
	if [ ! -f "$KEYRING" ]; then
		echo "Debian archive keyring not cached — fetching it from snapshot $SNAPSHOT…"
		SNAPSHOT="$SNAPSHOT" "$ROOT/build/fetch-keyring.sh"
	fi
fi
if [ ! -f "$KEYRING" ]; then
	echo "Debian archive keyring not found at: $KEYRING" >&2
	echo "Fetch it (also run by 'make keyring'):  SNAPSHOT=$SNAPSHOT build/fetch-keyring.sh" >&2
	exit 1
fi
echo "Using archive keyring: $KEYRING"

# apt's acquire sandbox (user _apt) cannot traverse a 0750 home directory, so it cannot read a
# keyring that lives under $HOME (the usual repo checkout). Stage a world-readable copy in /tmp
# for the duration of the build; apt then verifies the snapshot archive against it.
KR_STAGE="$(mktemp -p "${TMPDIR:-/tmp}" bastion-keyring.XXXXXX.gpg)"
cp "$KEYRING" "$KR_STAGE"
chmod 0644 "$KR_STAGE"
trap 'rm -f "$KR_STAGE"' EXIT

# Comma-separated include list from the profile file: drop comments, strip whitespace WITHIN each
# line (but keep line breaks), drop blank lines, then join with commas. (Using `tr -d` here would
# also delete the newlines and mash every package name into one invalid token.)
PKGS="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$ROOT/build/profiles/minimal.packages" \
	| paste -sd, -)"

echo "Building rootfs: suite=$SUITE arch=$ARCH snapshot=$SNAPSHOT"
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

rm -f "$OUT/rootfs.tar"
mmdebstrap \
	--variant=minbase \
	--architectures="$ARCH" \
	--components="$COMPONENTS" \
	--keyring="$KR_STAGE" \
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
	"deb [signed-by=${KR_STAGE}] ${MIRROR} ${SUITE} ${COMPONENTS}" \
	"deb [signed-by=${KR_STAGE}] ${SECMIRROR} ${SUITE}-security ${COMPONENTS}"

echo "Wrote $OUT/rootfs.tar ($(du -h "$OUT/rootfs.tar" | cut -f1))"
