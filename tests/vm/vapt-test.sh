#!/usr/bin/env bash
# BastionOS Phase 6 test: verify bastion-scan's GUARDRAILS without performing any scanning or
# network activity. Everything runs through `scope check` (a pure gate) and BASTION_SCAN_DRYRUN=1
# (resolve + audit, never launch a container). This is the safety-critical part: a VAPT wrapper
# is only trustworthy if it provably refuses out-of-scope / unauthorized / out-of-window work.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/packages/bastion-scan/bin/bastion-scan"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
export BASTION_SCAN_PREFIX="$SBX"       # audit/results land under the sandbox (no scan.conf -> defaults)
export BASTION_SCAN_DRYRUN=1            # never launch podman / touch the network

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
# run the CLI, capture combined output + exit code into $OUT / $RC
cli() { OUT="$("$@" 2>&1)"; RC=$?; }

mkeng() { # <file> — write a valid, in-window engagement using documentation ranges
	cat > "$1" <<EOF
NAME=test-eng
AUTHORIZATION_REF=SOW-TEST-1 (authorization on file)
OPERATOR=tester
WINDOW_START=2020-01-01T00:00:00Z
WINDOW_END=2099-12-31T23:59:59Z
SCOPE_CIDRS=203.0.113.0/24 198.51.100.10/32
SCOPE_HOSTS=app.example.com
SCOPE_DOMAINS=example.com
EXCLUDE=203.0.113.1
MAX_RATE_PPS=100
ALLOW_PROFILES=discovery tls web
EOF
}

echo "== refuses with no engagement file =="
export BASTION_SCAN_ENGAGEMENT="$SBX/none.conf"
cli bash "$CLI" run discovery 203.0.113.5
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "REFUSED"; } && ok "no engagement -> refused" || no "no engagement -> refused"

echo "== refuses engagement with no AUTHORIZATION_REF =="
export BASTION_SCAN_ENGAGEMENT="$SBX/noauth.conf"
printf 'NAME=x\nAUTHORIZATION_REF=\nSCOPE_CIDRS=203.0.113.0/24\nALLOW_PROFILES=discovery\n' > "$BASTION_SCAN_ENGAGEMENT"
cli bash "$CLI" engagement validate
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "authorization"; } && ok "missing auth ref -> refused" || no "missing auth ref -> refused"

echo "== refuses engagement with no scope =="
export BASTION_SCAN_ENGAGEMENT="$SBX/noscope.conf"
printf 'NAME=x\nAUTHORIZATION_REF=ref\nALLOW_PROFILES=discovery\n' > "$BASTION_SCAN_ENGAGEMENT"
cli bash "$CLI" engagement validate
[ "$RC" -ne 0 ] && ok "no scope -> refused" || no "no scope -> refused"

echo "== valid engagement validates =="
export BASTION_SCAN_ENGAGEMENT="$SBX/ok.conf"; mkeng "$BASTION_SCAN_ENGAGEMENT"
cli bash "$CLI" engagement validate
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "engagement OK"; } && ok "valid engagement OK" || no "valid engagement OK"

echo "== scope: CIDR + host + domain matching =="
cli bash "$CLI" scope check 203.0.113.5
printf '%s' "$OUT" | grep -q "IN-SCOPE" && ok "in-CIDR accepted" || no "in-CIDR accepted"
cli bash "$CLI" scope check 203.0.114.5
printf '%s' "$OUT" | grep -q "OUT-OF-SCOPE" && ok "out-of-CIDR refused" || no "out-of-CIDR refused"
cli bash "$CLI" scope check app.example.com
printf '%s' "$OUT" | grep -q "IN-SCOPE" && ok "exact host accepted" || no "exact host accepted"
cli bash "$CLI" scope check sub.example.com
printf '%s' "$OUT" | grep -q "IN-SCOPE" && ok "sub-domain accepted" || no "sub-domain accepted"
cli bash "$CLI" scope check evil.com
printf '%s' "$OUT" | grep -q "OUT-OF-SCOPE" && ok "foreign domain refused" || no "foreign domain refused"

echo "== scope: exclusions win over scope =="
cli bash "$CLI" scope check 203.0.113.1
printf '%s' "$OUT" | grep -q "OUT-OF-SCOPE.*EXCLUDE" && ok "excluded IP refused" || no "excluded IP refused"

echo "== scope: hard-denied ranges refused even if scoped =="
export BASTION_SCAN_ENGAGEMENT="$SBX/meta.conf"; mkeng "$BASTION_SCAN_ENGAGEMENT"
sed -i 's#^SCOPE_CIDRS=.*#SCOPE_CIDRS=169.254.0.0/16#' "$BASTION_SCAN_ENGAGEMENT"
cli bash "$CLI" scope check 169.254.169.254
printf '%s' "$OUT" | grep -q "OUT-OF-SCOPE.*hard-denied" && ok "cloud-metadata IP hard-denied" || no "cloud-metadata IP hard-denied"
export BASTION_SCAN_ENGAGEMENT="$SBX/ok.conf"

echo "== URL host is extracted for scope =="
cli bash "$CLI" scope check https://app.example.com/login?x=1
printf '%s' "$OUT" | grep -q "IN-SCOPE" && ok "URL host extracted + scoped" || no "URL host extracted + scoped"

echo "== window enforcement =="
export BASTION_SCAN_ENGAGEMENT="$SBX/expired.conf"; mkeng "$BASTION_SCAN_ENGAGEMENT"
sed -i 's#^WINDOW_END=.*#WINDOW_END=2000-01-01T00:00:00Z#' "$BASTION_SCAN_ENGAGEMENT"
cli bash "$CLI" run discovery 203.0.113.5
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi "window has ended"; } && ok "expired window -> refused" || no "expired window -> refused"
export BASTION_SCAN_ENGAGEMENT="$SBX/ok.conf"

echo "== profile must be allowed =="
cli bash "$CLI" run exploit 203.0.113.5
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "not in ALLOW_PROFILES"; } && ok "disallowed profile refused" || no "disallowed profile refused"

echo "== one out-of-scope target aborts the whole run =="
cli bash "$CLI" run discovery 203.0.113.5 203.0.114.9
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "refusing the entire run"; } && ok "mixed batch refused wholesale" || no "mixed batch refused wholesale"

echo "== dry-run of an in-scope target: safe container command + audit, no execution =="
mkdir -p "$SBX/var/log/bastion-scan"; : > "$SBX/var/log/bastion-scan/audit.log"
cli bash "$CLI" run discovery 203.0.113.5
[ "$RC" -eq 0 ] && ok "dry-run in-scope succeeds" || no "dry-run in-scope succeeds"
printf '%s' "$OUT" | grep -q -- "--cap-drop=ALL" && ok "container drops all caps" || no "container drops all caps"
printf '%s' "$OUT" | grep -q -- "no-new-privileges" && ok "no-new-privileges set" || no "no-new-privileges set"
printf '%s' "$OUT" | grep -q "bastionos/vapt:pinned" && ok "uses the pinned image" || no "uses the pinned image"
printf '%s' "$OUT" | grep -q -- "--max-rate 100" && ok "rate cap applied" || no "rate cap applied"
printf '%s' "$OUT" | grep -qiE -- "--privileged|--cap-add|--user[ =]root|-u 0" && no "no privileged flags" || ok "no privileged flags"
printf '%s' "$OUT" | grep -qi "DRY-RUN: nothing was executed" && ok "states nothing executed" || no "states nothing executed"

echo "== audit log recorded the run with authorization + dry_run=true =="
AL="$SBX/var/log/bastion-scan/audit.log"
if command -v jq >/dev/null 2>&1; then
	last="$(tail -1 "$AL" 2>/dev/null)"
	[ "$(printf '%s' "$last" | jq -r '.authorization_ref' 2>/dev/null)" = "SOW-TEST-1 (authorization on file)" ] \
		&& ok "audit records authorization_ref" || no "audit records authorization_ref"
	[ "$(printf '%s' "$last" | jq -r '.dry_run' 2>/dev/null)" = "true" ] \
		&& ok "audit marks dry_run" || no "audit marks dry_run"
	[ "$(printf '%s' "$last" | jq -r '.targets[0]' 2>/dev/null)" = "203.0.113.5" ] \
		&& ok "audit records target" || no "audit records target"
else
	grep -q "SOW-TEST-1" "$AL" && ok "audit records authorization_ref (text)" || no "audit records authorization_ref (text)"
fi

echo "== shipped example file parses (inline comments stripped) =="
export BASTION_SCAN_ENGAGEMENT="$REPO/packages/bastion-scan/engagement.example.conf"
cli bash "$CLI" engagement validate
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "engagement OK"; } && ok "example engagement validates" || no "example engagement validates"
cli bash "$CLI" scope check app.example.com
printf '%s' "$OUT" | grep -q "IN-SCOPE" && ok "example scope resolves (no comment pollution)" || no "example scope resolves (no comment pollution)"

echo "== init-generated file refuses until AUTHORIZATION_REF is filled =="
export BASTION_SCAN_ENGAGEMENT="$SBX/fresh.conf"
bash "$CLI" engagement init fresh-eng >/dev/null 2>&1
cli bash "$CLI" engagement validate
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "authorization"; } && ok "fresh engagement refused (blank auth)" || no "fresh engagement refused (blank auth)"
export BASTION_SCAN_ENGAGEMENT="$SBX/ok.conf"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
