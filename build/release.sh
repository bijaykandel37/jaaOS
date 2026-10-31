#!/usr/bin/env bash
# Produce release artifacts from a completed build: SHA256SUMS, a provenance manifest, an SBOM
# (from the rootfs's dpkg database), and a detached signature over the checksums.
#
# Signing preference: minisign (if MINISIGN_SECRET_KEY or a key file is present) -> gpg -> none.
# With no key, artifacts are published UNSIGNED and this script SAYS SO rather than failing, so an
# unsigned pre-release is possible on purpose. Everything lands in out/dist/.
#
# Override the output tree with OUT=... (the sandbox test does this). Build glue, not a runtime
# tool (ADR 0002): shell is correct here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/out}"
DIST="$OUT/dist"
IMG="$OUT/jaaos-minimal.img"
ROOTFS_TAR="$OUT/rootfs.tar"
SNAPSHOT="${SNAPSHOT:-20261001T000000Z}"

have() { command -v "$1" >/dev/null 2>&1; }
log()  { echo "release: $*"; }

mkdir -p "$DIST"

# ---- collect the artifacts we actually built (hardlink into dist; fall back to copy) ----
artifacts=()
for f in "$IMG" "$ROOTFS_TAR"; do
	if [ -f "$f" ]; then
		ln -f "$f" "$DIST/$(basename "$f")" 2>/dev/null || cp "$f" "$DIST/"
		artifacts+=("$(basename "$f")")
	fi
done
[ "${#artifacts[@]}" -gt 0 ] || { echo "release: no artifacts in $OUT (build first)" >&2; exit 1; }

cd "$DIST"

# ---- checksums ----
sha256sum "${artifacts[@]}" > SHA256SUMS
log "wrote SHA256SUMS over ${#artifacts[@]} artifact(s)"

# ---- SBOM (exact package versions from the rootfs dpkg status) ----
if [ -f "$ROOTFS_TAR" ]; then
	{
		echo "# jaaOS SBOM — package<TAB>version<TAB>arch, from the rootfs dpkg database."
		echo "# For a signed CycloneDX/SPDX SBOM, run syft on the rootfs in CI; this is the lean form."
		tar -xOf "$ROOTFS_TAR" --wildcards '*var/lib/dpkg/status' 2>/dev/null \
			| awk '/^Package:/{p=$2} /^Version:/{v=$2} /^Architecture:/{a=$2}
			       /^$/{if(p!="")print p"\t"v"\t"a; p=v=a=""}
			       END{if(p!="")print p"\t"v"\t"a}' \
			| sort
	} > sbom.txt
	log "wrote sbom.txt ($(($(wc -l < sbom.txt) - 2)) packages)"
else
	log "no rootfs.tar — skipping SBOM"
fi

# ---- provenance manifest ----
version="$(cd "$ROOT" && git describe --tags --always --dirty 2>/dev/null || echo unknown)"
commit="$(cd "$ROOT" && git rev-parse HEAD 2>/dev/null || echo unknown)"
sde="${SOURCE_DATE_EPOCH:-$(date -u -d "$(printf '%s' "$SNAPSHOT" | sed -E 's/^(....)(..)(..)T.*/\1-\2-\3/')" +%s 2>/dev/null || echo 0)}"
{
	echo "{"
	echo "  \"product\": \"jaaOS\","
	echo "  \"version\": \"$version\","
	echo "  \"git_commit\": \"$commit\","
	echo "  \"debian_snapshot\": \"$SNAPSHOT\","
	echo "  \"source_date_epoch\": $sde,"
	echo "  \"built_utc\": \"$(date -u +%FT%TZ)\","
	echo "  \"tools\": {"
	echo "    \"mmdebstrap\": \"$(have mmdebstrap && mmdebstrap --version 2>/dev/null | head -1 || echo absent)\","
	echo "    \"cryptsetup\": \"$(have cryptsetup && cryptsetup --version 2>/dev/null | head -1 || echo absent)\""
	echo "  },"
	printf '  "artifacts": ['
	first=1
	for a in "${artifacts[@]}"; do
		[ "$first" -eq 1 ] || printf ','
		printf '\n    {"name": "%s", "sha256": "%s"}' "$a" "$(sha256sum "$a" | cut -d' ' -f1)"
		first=0
	done
	echo ""
	echo "  ]"
	echo "}"
} > manifest.json
log "wrote manifest.json (version $version)"

# ---- signing ----
sign_minisign() {
	local keyfile="" tmp=""
	if [ -n "${MINISIGN_SECRET_KEY:-}" ]; then
		tmp="$(mktemp)"; printf '%s\n' "$MINISIGN_SECRET_KEY" > "$tmp"; keyfile="$tmp"
	elif [ -f "${MINISIGN_KEY_FILE:-}" ]; then
		keyfile="$MINISIGN_KEY_FILE"
	elif [ -f "$HOME/.minisign/minisign.key" ]; then
		keyfile="$HOME/.minisign/minisign.key"
	fi
	[ -n "$keyfile" ] || return 1
	printf '%s\n' "${MINISIGN_KEY_PASSWORD:-}" | minisign -S -s "$keyfile" -m SHA256SUMS >/dev/null 2>&1
	local rc=$?
	[ -n "$tmp" ] && rm -f "$tmp"
	return "$rc"
}

if have minisign && sign_minisign; then
	log "signed SHA256SUMS -> SHA256SUMS.minisig (minisign)"
elif have gpg && [ -n "${GPG_SIGNING_KEY:-}${GNUPGHOME:-}" ] && gpg --batch --yes --detach-sign --armor SHA256SUMS 2>/dev/null; then
	log "signed SHA256SUMS -> SHA256SUMS.asc (gpg)"
else
	log "WARNING: no signing key available — artifacts are UNSIGNED."
	echo "UNSIGNED: no minisign/gpg key was available at build time." > SHA256SUMS.UNSIGNED
fi

echo
log "release tree:"
ls -la "$DIST" | sed 's/^/  /'
