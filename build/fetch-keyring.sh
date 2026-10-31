#!/usr/bin/env bash
# Fetch the Debian archive keyring from the SAME pinned snapshot the rootfs is built from, and
# verify it contains the trixie (Debian 13) signing keys. Output: build/keyrings/debian-archive-keyring.gpg
#
# Why this exists: mmdebstrap needs the Debian archive keyring to verify the snapshot archive's
# signatures. Non-Debian hosts (e.g. Ubuntu) either lack `debian-archive-keyring` or ship a copy
# too old to contain the Debian 13 keys — which fails the build with "NO_PUBKEY / not signed".
# Pulling the keyring from the pinned snapshot makes `make image` work on any host, deterministically.
#
# Trust: the download is over HTTPS and we PIN the trixie key IDs that must be present (below),
# refusing anything that does not carry them. Verify these against Debian's published keys:
#   https://ftp-master.debian.org/keys.html
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="$ROOT/build/keyrings"
DEST="$OUTDIR/debian-archive-keyring.gpg"
SNAPSHOT="${SNAPSHOT:-20261001T000000Z}"
MIRROR="https://snapshot.debian.org/archive/debian/${SNAPSHOT}"
POOL="$MIRROR/pool/main/d/debian-archive-keyring/"

# Trixie keys that MUST be present (the signing subkeys apt uses for trixie + trixie-security,
# plus the stable release key). The build fails cleanly if a fetched keyring lacks any of them.
REQUIRED_KEYS=(78DBA3BC47EF2265 8E9F831205B4BA95 762F67A0B2C39DE4)

have() { command -v "$1" >/dev/null 2>&1; }
have curl    || { echo "need curl" >&2; exit 1; }
have dpkg-deb || { echo "need dpkg-deb (dpkg)" >&2; exit 1; }
have gpg     || { echo "need gpg (gnupg)" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$OUTDIR"

echo "Fetching Debian archive keyring from snapshot $SNAPSHOT"
# Newest keyring .deb in the pool (2025.1 for trixie), ignoring URL-encoded duplicates.
deb="$(curl -sfL "$POOL" | grep -oE 'debian-archive-keyring_[0-9][^"]*_all\.deb' \
	| grep -v '%2B' | sort -V | uniq | tail -1)"
[ -n "$deb" ] || { echo "could not locate a keyring .deb under $POOL" >&2; exit 1; }
echo "  package: $deb"
curl -sfL -o "$tmp/k.deb" "${POOL}${deb}" || { echo "download failed" >&2; exit 1; }

# Extract the real keyring file (2025.1 ships debian-archive-keyring.pgp with a .gpg symlink).
dpkg-deb --fsys-tarfile "$tmp/k.deb" \
	| tar -x -C "$tmp" --wildcards './usr/share/keyrings/debian-archive-keyring.*' 2>/dev/null || true
src=""
for cand in "$tmp/usr/share/keyrings/debian-archive-keyring.pgp" \
            "$tmp/usr/share/keyrings/debian-archive-keyring.gpg"; do
	[ -f "$cand" ] && [ -s "$cand" ] && { src="$cand"; break; }
done
[ -n "$src" ] || { echo "keyring file not found inside $deb" >&2; exit 1; }

# Verify the pinned trixie keys are present before trusting it.
for id in "${REQUIRED_KEYS[@]}"; do
	gpg --no-default-keyring --keyring "$src" --list-keys "$id" >/dev/null 2>&1 \
		|| { echo "fetched keyring is missing required trixie key $id — refusing" >&2; exit 1; }
done

install -m 0644 "$src" "$DEST"
echo "Wrote $DEST (verified: trixie archive + security + release keys present)."
