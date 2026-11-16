#!/usr/bin/env bash
# Download the pinned RKE2 release (build/rke2.lock) and verify it before anything uses it.
#
#   build/fetch-rke2.sh                 # binary tarball only (~40 MB)
#   AIRGAP=1 build/fetch-rke2.sh        # + core and canal images (~800 MB) for offline clusters
#
# Output: build/cache/rke2/<version>/ — prints that directory on the last line of stdout.
# Trust: the release's sha256sum-amd64.txt must match the hash pinned in rke2.lock, and every
# asset must match its line in that file. Anything else aborts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/build/rke2.lock"
AIRGAP="${AIRGAP:-0}"

lock() { sed -n "s/^$1=//p" "$LOCK" | head -1; }
VERSION="$(lock RKE2_VERSION)"
SUMS_SHA="$(lock RKE2_SHA256SUMS_SHA256)"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+rke2r[0-9]+$ ]] || { echo "fetch-rke2: bad RKE2_VERSION in $LOCK" >&2; exit 1; }
[[ "$SUMS_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "fetch-rke2: bad RKE2_SHA256SUMS_SHA256 in $LOCK" >&2; exit 1; }

BASE="https://github.com/rancher/rke2/releases/download/${VERSION/+/%2B}"
DIR="$ROOT/build/cache/rke2/$VERSION"
mkdir -p "$DIR"

fetch() { # <asset>
	local f="$1"
	if [ -f "$DIR/$f" ] && (cd "$DIR" && grep -E "  $f\$" sha256sum-amd64.txt | sha256sum -c --status); then
		echo "fetch-rke2: $f (cached, verified)" >&2; return 0
	fi
	echo "fetch-rke2: downloading $f" >&2
	curl -sSfL --retry 3 -o "$DIR/$f.part" "$BASE/$f"
	mv "$DIR/$f.part" "$DIR/$f"
	(cd "$DIR" && grep -E "  $f\$" sha256sum-amd64.txt | sha256sum -c --status) \
		|| { rm -f "$DIR/$f"; echo "fetch-rke2: $f hash mismatch — refusing" >&2; exit 1; }
}

curl -sSfL --retry 3 -o "$DIR/sha256sum-amd64.txt.part" "$BASE/sha256sum-amd64.txt"
got="$(sha256sum "$DIR/sha256sum-amd64.txt.part" | cut -d' ' -f1)"
[ "$got" = "$SUMS_SHA" ] || {
	rm -f "$DIR/sha256sum-amd64.txt.part"
	echo "fetch-rke2: sha256sum-amd64.txt does not match the pin in $LOCK — refusing" >&2
	echo "  expected $SUMS_SHA" >&2; echo "  got      $got" >&2; exit 1
}
mv "$DIR/sha256sum-amd64.txt.part" "$DIR/sha256sum-amd64.txt"

fetch rke2.linux-amd64.tar.gz
if [ "$AIRGAP" = 1 ]; then
	fetch rke2-images-core.linux-amd64.tar.zst
	fetch rke2-images-canal.linux-amd64.tar.zst
fi
echo "$DIR"
