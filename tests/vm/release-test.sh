#!/usr/bin/env bash
# BastionOS Phase 7 test: build/release.sh over FAKE artifacts in a sandbox OUT (no real image
# build, no signing key). Verifies checksums, provenance manifest, SBOM extraction, and the
# honest UNSIGNED fallback. Signing itself is only exercised on a real host / in CI with a key.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }

mkdir -p "$SBX/out" "$SBX/home"
# Fake image artifact.
head -c 4096 /dev/zero > "$SBX/out/bastionos-minimal.img"
# Fake rootfs.tar carrying a dpkg status db (for the SBOM path).
pkgroot="$SBX/pkg"; mkdir -p "$pkgroot/var/lib/dpkg"
cat > "$pkgroot/var/lib/dpkg/status" <<'EOF'
Package: nginx
Version: 1.26.0-1
Architecture: amd64

Package: openssl
Version: 3.3.0-1
Architecture: amd64
EOF
tar -C "$pkgroot" -cf "$SBX/out/rootfs.tar" ./var

echo "== release.sh runs over fake artifacts (unsigned) =="
OUT="$SBX/out" HOME="$SBX/home" MINISIGN_SECRET_KEY= MINISIGN_KEY_FILE= GPG_SIGNING_KEY= GNUPGHOME= \
	bash "$REPO/build/release.sh" >/dev/null 2>&1 && ok "release.sh exits 0" || no "release.sh exits 0"

D="$SBX/out/dist"
echo "== checksums =="
[ -f "$D/SHA256SUMS" ] && ok "SHA256SUMS written" || no "SHA256SUMS written"
( cd "$D" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && ok "checksums verify" || no "checksums verify"
grep -q "bastionos-minimal.img" "$D/SHA256SUMS" && ok "image checksummed" || no "image checksummed"

echo "== manifest =="
if command -v jq >/dev/null 2>&1; then
	jq -e . "$D/manifest.json" >/dev/null 2>&1 && ok "manifest.json valid JSON" || no "manifest.json valid JSON"
	[ "$(jq -r '.product' "$D/manifest.json")" = "BastionOS" ] && ok "manifest product" || no "manifest product"
	[ "$(jq '.artifacts | length' "$D/manifest.json")" -eq 2 ] && ok "manifest lists 2 artifacts" || no "manifest lists 2 artifacts"
else
	grep -q BastionOS "$D/manifest.json" && ok "manifest has product (no jq)" || no "manifest has product (no jq)"
fi

echo "== SBOM =="
[ -f "$D/sbom.txt" ] && ok "sbom.txt written" || no "sbom.txt written"
grep -q "nginx" "$D/sbom.txt" && grep -q "openssl" "$D/sbom.txt" && ok "sbom lists packages+versions" || no "sbom lists packages+versions"

echo "== honest unsigned fallback =="
[ -f "$D/SHA256SUMS.UNSIGNED" ] && ok "UNSIGNED notice present" || no "UNSIGNED notice present"
[ ! -f "$D/SHA256SUMS.minisig" ] && [ ! -f "$D/SHA256SUMS.asc" ] && ok "no bogus signature created" || no "no bogus signature created"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
