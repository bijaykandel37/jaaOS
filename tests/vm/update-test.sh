#!/usr/bin/env bash
# jaaOS Phase 7 test: jaa-update plan ordering + safety, all in dry-run (no root, no apt,
# no snapper). Verifies the snapshot bracket is ordered correctly and that nothing executes.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/packages/jaa-update/bin/jaa-update"
export JAA_UPDATE_DRYRUN=1

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }

echo "== apply plan is snapshot-bracketed and ordered =="
plan="$(bash "$CLI" apply 2>&1)"
pre=$(printf '%s\n' "$plan"  | grep -n 'PRE-snapshot'     | head -1 | cut -d: -f1)
up=$(printf '%s\n'  "$plan"  | grep -n 'full-upgrade'     | head -1 | cut -d: -f1)
post=$(printf '%s\n' "$plan" | grep -n 'POST-snapshot'    | head -1 | cut -d: -f1)
{ [ -n "$pre" ] && [ -n "$up" ] && [ -n "$post" ] && [ "$pre" -lt "$up" ] && [ "$up" -lt "$post" ]; } \
	&& ok "pre -> upgrade -> post order" || no "pre -> upgrade -> post order"
printf '%s' "$plan" | grep -q "dry-run: nothing executed" && ok "apply executes nothing in dry-run" || no "apply executes nothing in dry-run"
printf '%s' "$plan" | grep -qi "signed UKI must be rebuilt" && ok "warns about immutable-UKI kernel" || no "warns about immutable-UKI kernel"

echo "== check is read-only (update + list, no upgrade) =="
chk="$(bash "$CLI" check 2>&1)"
printf '%s' "$chk" | grep -q "apt-get update" && ok "check refreshes indexes" || no "check refreshes indexes"
printf '%s' "$chk" | grep -qiE "full-upgrade|dist-upgrade" && no "check must not upgrade" || ok "check must not upgrade"

echo "== rollback (no arg) lists and explains, runs nothing destructive =="
rb="$(bash "$CLI" rollback 2>&1)"
printf '%s' "$rb" | grep -q "snapper -c 'root' list" && ok "rollback lists snapshots" || no "rollback lists snapshots"
printf '%s' "$rb" | grep -q "rollback <snapshot-number>" && ok "rollback explains usage" || no "rollback explains usage"

echo "== rollback <n> plans a snapper rollback + warns on kernel =="
rb2="$(bash "$CLI" rollback 42 2>&1)"
printf '%s' "$rb2" | grep -q "snapper -c 'root' rollback '42'" && ok "rollback targets the snapshot" || no "rollback targets the snapshot"
printf '%s' "$rb2" | grep -qi "Kernel/UKI is NOT rolled back" && ok "rollback warns about kernel/UKI" || no "rollback warns about kernel/UKI"

echo "== status runs without crashing =="
bash "$CLI" status >/dev/null 2>&1 && ok "status ok" || no "status ok"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
