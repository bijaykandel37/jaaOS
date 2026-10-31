#!/usr/bin/env bash
# jaaOS Phase 2 FORENSIC / deniability characterization.
#
# Points an "examiner's eye" at a powered-off backing image or device and reports what is
# detectable. It is deliberately honest: in luks2 mode it WILL find the container headers,
# proving that encrypted environments exist. That is the whole point of running it — to
# show exactly where the deniability story holds and where it does not.
#
#   tests/forensic/forensic-scan.sh <image-file-or-device>
set -uo pipefail
IMG="${1:?usage: forensic-scan.sh <image-or-device>}"
[ -e "$IMG" ] || { echo "no such path: $IMG" >&2; exit 1; }

echo "=== jaaOS deniability scan: $IMG ==="
sz="$(blockdev --getsize64 "$IMG" 2>/dev/null || stat -c%s "$IMG" 2>/dev/null || echo 0)"
echo "size: $sz bytes"
echo

echo "--- 1. LUKS header detection ---"
# LUKS1/LUKS2 primary header magic is the 6 bytes: 'L' 'U' 'K' 'S' 0xba 0xbe
hits="$(grep -a -o -b $'LUKS\xba\xbe' "$IMG" 2>/dev/null | wc -l)"
echo "LUKS magic occurrences: ${hits:-0}"
if [ "${hits:-0}" -ge 1 ]; then
	echo ">> At least ${hits} LUKS container(s) detected. In luks2 mode this is EXPECTED and"
	echo ">> means the existence of encrypted environment(s) is PROVEN (deniability: failed)."
fi
if command -v cryptsetup >/dev/null 2>&1; then
	if cryptsetup isLuks "$IMG" 2>/dev/null; then
		echo ">> cryptsetup confirms a LUKS2 header at offset 0:"
		cryptsetup luksDump "$IMG" 2>/dev/null | sed -n '1,12p' | sed 's/^/     /'
	else
		echo ">> No LUKS header at offset 0 (detached-header, or a shufflecake/random device)."
	fi
fi
echo

echo "--- 2. Whole-device entropy (shufflecake should look uniformly random) ---"
if command -v ent >/dev/null 2>&1; then
	ent "$IMG" | sed -n '1,2p' | sed 's/^/     /'
else
	# Fallback: compare compressed size of a sample to its raw size (random ~= incompressible).
	smp="$(mktemp)"; dd if="$IMG" of="$smp" bs=1M count=16 status=none 2>/dev/null || true
	raw="$(stat -c%s "$smp" 2>/dev/null || echo 0)"
	comp="$(gzip -c "$smp" 2>/dev/null | wc -c)"
	rm -f "$smp"
	echo "     16MiB sample: raw=$raw gzip=$comp (ratio ~1.0 => high entropy / random-filled)"
	echo "     (install 'ent' for a proper entropy figure)"
fi
echo

cat <<'NOTE'
--- Interpretation ---
 luks2 provider      : >=1 LUKS magic + readable luksDump => encrypted environments are
                       PROVABLY present. Confidentiality holds (contents unreadable), but
                       deniability of EXISTENCE has failed. Use this mode only when the
                       threat model accepts that.
 shufflecake provider: no LUKS magic, uniformly high entropy everywhere, number of hidden
                       volumes NOT revealed. Existence is only INFERABLE (random whole disk
                       + presence of shufflecake tooling on the system), never proven by the
                       image alone. This is best-effort deniability, not a guarantee.

 In BOTH modes, a forensic examiner who knows the machine runs jaaOS has strong reason
 to suspect a hidden environment. See docs/01-threat-model.md (T5, T8) and docs/03 §9.
NOTE
