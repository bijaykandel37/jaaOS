#!/usr/bin/env bash
# jaaOS Phase 2 FUNCTIONAL test for the luks2 provider.
#
# RUN ONLY IN A DISPOSABLE ROOT VM — it creates real LUKS2 containers (loopback-backed
# files) and a throwaway user. It exercises the provider the PAM helper relies on:
# init/add, correct env selection, wrong-password rejection, re-auth isolation, and
# constant-time behaviour. It does not drive the full PAM login stack (that needs a real
# display manager / sshd); see docs/03 for the manual end-to-end steps.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "root only" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PROV="$REPO/packages/jaa-env/providers/luks2"
TESTUSER=jaa-test
TMPROOT="$(mktemp -d)"
export JAA_USER="$TESTUSER"
export JAA_STORE="$TMPROOT/store"
export JAA_HOME="$TMPROOT/home"
export JAA_ENV_SIZE=256M
mkdir -p "$JAA_HOME"
id "$TESTUSER" >/dev/null 2>&1 || useradd -M "$TESTUSER"

cleanup() {
	for m in $(ls /dev/mapper/ | grep -E '^jaa_(home|fmt)_' 2>/dev/null); do
		cryptsetup close "$m" 2>/dev/null || true
	done
	mountpoint -q "$JAA_HOME" && umount "$JAA_HOME" 2>/dev/null || true
	rm -rf "$TMPROOT"
}
trap cleanup EXIT

PA='alpha-pw'; PB='bravo-pw'; PBAD='nope-pw'
pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
close_from() { set -- $1; [ -n "${2:-}" ] && "$PROV" unmount "$2" 2>/dev/null || true; }

echo "== init + add (this runs Argon2id; ~a few seconds each) =="
printf '%s' "$PA" | "$PROV" init && ok "init env.0" || no "init env.0"
printf '%s' "$PB" | "$PROV" add  && ok "add  env.1" || no "add  env.1"

echo "== correct password selects the correct environment =="
OA="$(printf '%s' "$PA" | "$PROV" try-unlock || true)"; echo "  pwA -> '$OA'"
case "$OA" in env.0\ *) ok "pwA opens env.0";; *) no "pwA opens env.0";; esac; close_from "$OA"
OB="$(printf '%s' "$PB" | "$PROV" try-unlock || true)"; echo "  pwB -> '$OB'"
case "$OB" in env.1\ *) ok "pwB opens env.1";; *) no "pwB opens env.1";; esac; close_from "$OB"

echo "== wrong password is rejected =="
if printf '%s' "$PBAD" | "$PROV" try-unlock >/dev/null 2>&1; then no "bad pw rejected"; else ok "bad pw rejected"; fi

echo "== re-auth (verify-active) only matches its own environment =="
if printf '%s' "$PA" | "$PROV" verify-active "$JAA_STORE/env.0"; then ok "pwA verifies against env.0"; else no "pwA verifies against env.0"; fi
if printf '%s' "$PB" | "$PROV" verify-active "$JAA_STORE/env.0" >/dev/null 2>&1; then no "pwB must NOT verify against env.0"; else ok "pwB rejected on env.0 (no hint env.1 exists)"; fi

echo "== mount / unmount round-trip =="
OA="$(printf '%s' "$PA" | "$PROV" try-unlock || true)"; set -- $OA
if [ -n "${2:-}" ] && "$PROV" mount "$2" && mountpoint -q "$JAA_HOME"; then ok "mount env.0 at home"; else no "mount env.0 at home"; fi
if "$PROV" unmount "${2:-none}" && ! mountpoint -q "$JAA_HOME"; then ok "unmount + close"; else no "unmount + close"; fi

echo "== timing: A / B / neither should be close (both KDFs always run) =="
timeit() { local p="$1" s e o; s="$(date +%s.%N)"; o="$(printf '%s' "$p" | "$PROV" try-unlock 2>/dev/null || true)"; e="$(date +%s.%N)"; close_from "$o"; awk -v a="$s" -v b="$e" 'BEGIN{printf "%.3f", b-a}'; }
TA="$(timeit "$PA")"; TB="$(timeit "$PB")"; TN="$(timeit "$PBAD")"
echo "  A=${TA}s  B=${TB}s  none=${TN}s"
awk -v a="$TA" -v b="$TB" -v n="$TN" 'BEGIN{m=(a>b?a:b); m=(m>n?m:n); lo=(a<b?a:b); lo=(lo<n?lo:n); d=m-lo; if (d<=0.5) exit 0; else exit 1}' \
	&& ok "timing spread <= 0.5s" || no "timing spread > 0.5s (investigate ordering)"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
