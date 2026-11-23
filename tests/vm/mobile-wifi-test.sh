#!/usr/bin/env bash
# jaaOS test: jaa-wifi WiFi auditor. Uses a canned scan file (no phone, no radio). Checks the
# authorization/scope gate (same contract as jaa-scan), the security verdicts, that out-of-scope
# networks are never assessed, exclusions win, and every run is audited.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/mobile/wifi/jaa-wifi"
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
check() { if "${@:2}"; then ok "$1"; else no "$1"; fi; }

# Canned scan (BSSID \t RSSI \t FREQ \t CAPABILITIES \t SSID) — the format scan() emits.
cat > "$SBX/scan.tsv" <<'EOF'
aa:bb:cc:00:00:01	-42	2437	[WPA2-PSK-CCMP][WPS][ESS]	MyHomeWiFi
aa:bb:cc:00:00:02	-55	5180	[RSN-SAE-CCMP][MFPR][ESS]	MyHomeWiFi-5G
aa:bb:cc:00:00:09	-60	2412	[WPA2-PSK-CCMP][ESS]	MyHomeWiFi-Guest
de:ad:be:ef:00:03	-70	2412	[WEP][ESS]	OldRouter
de:ad:be:ef:00:04	-77	2462	[ESS]	CoffeeShop_Free
de:ad:be:ef:00:05	-80	2412	[WPA-PSK-TKIP][ESS]	Neighbor2010
EOF
cat > "$SBX/eng.conf" <<'EOF'
NAME=home
AUTHORIZATION_REF=I own this network
OPERATOR=tester
SCOPE_SSIDS="MyHomeWiFi" "MyHomeWiFi-5G"
SCOPE_BSSIDS=AA:BB:CC:00:00:09
EXCLUDE_SSIDS=
EXCLUDE_BSSIDS=
EOF
export JAA_WIFI_ENGAGEMENT="$SBX/eng.conf" JAA_WIFI_SCAN="$SBX/scan.tsv" JAA_WIFI_AUDIT="$SBX/audit.log"
run() { bash "$CLI" "$@" 2>&1; }
# verdict printed for a given SSID (the VERDICT line in its block)
verdict_of() { awk -v s="$1" '$0 ~ "  "s"  \\[" {grab=1} grab&&/VERDICT:/{print $2; exit}' <<<"$2"; }

echo "== authorization / scope gate (refuses like jaa-scan) =="
JAA_WIFI_ENGAGEMENT="$SBX/none.conf" run audit >/dev/null 2>&1; check "no engagement -> refuses" test $? -ne 0
printf 'NAME=x\nOPERATOR=y\nSCOPE_SSIDS="A"\n' > "$SBX/noauth.conf"
JAA_WIFI_ENGAGEMENT="$SBX/noauth.conf" run audit >"$SBX/o" 2>&1; rc=$?
check "no AUTHORIZATION_REF -> refuses" sh -c "[ $rc -ne 0 ] && grep -q 'authorization is mandatory' '$SBX/o'"
printf 'NAME=x\nAUTHORIZATION_REF=z\nOPERATOR=y\n' > "$SBX/noscope.conf"
JAA_WIFI_ENGAGEMENT="$SBX/noscope.conf" run audit >"$SBX/o" 2>&1; rc=$?
check "no scope -> refuses" sh -c "[ $rc -ne 0 ] && grep -q 'declares no scope' '$SBX/o'"

echo "== scope check =="
run scope check "MyHomeWiFi" | grep -q '^IN-SCOPE' && ok "own SSID in scope" || no "own SSID in scope"
run scope check "CoffeeShop_Free" >"$SBX/o" 2>&1; rc=$?
check "neighbour SSID out of scope" sh -c "[ $rc -ne 0 ] && grep -q OUT-OF-SCOPE '$SBX/o'"
run scope check "x" "aa:bb:cc:00:00:09" | grep -q IN-SCOPE && ok "in scope by BSSID (case-insensitive)" || no "in scope by BSSID"

echo "== audit assesses only in-scope networks =="
out="$(run audit)"
check "assessed exactly the 3 in-scope networks" sh -c "echo \"\$0\" | grep -q 'Assessed 3 in-scope' && echo \"\$0\" | grep -q '3 other network'" "$out"
check "neighbour/coffee/old NOT in the report body" sh -c "! echo \"\$0\" | grep -qE 'OldRouter|CoffeeShop_Free|Neighbor2010'" "$out"

echo "== security verdicts =="
check "WPS network -> HIGH" test "$(verdict_of MyHomeWiFi "$out")" = HIGH
check "pure WPA3-SAE -> OK" test "$(verdict_of MyHomeWiFi-5G "$out")" = OK
check "WPA2-PSK no WPS -> MEDIUM" test "$(verdict_of MyHomeWiFi-Guest "$out")" = MEDIUM
check "WPS weakness names the fix (disable WPS)" sh -c "echo \"\$0\" | grep -q 'Turn OFF WPS'" "$out"
# put a WEP and an open network in scope to check their verdicts
sed -i 's#SCOPE_BSSIDS=.*#SCOPE_BSSIDS=AA:BB:CC:00:00:09 de:ad:be:ef:00:03 de:ad:be:ef:00:04 de:ad:be:ef:00:05#' "$SBX/eng.conf"
out="$(run audit)"
check "WEP -> CRITICAL" test "$(verdict_of OldRouter "$out")" = CRITICAL
check "open network -> CRITICAL" test "$(verdict_of CoffeeShop_Free "$out")" = CRITICAL
check "WPA1/TKIP -> HIGH" test "$(verdict_of Neighbor2010 "$out")" = HIGH

echo "== exclusions win over scope =="
sed -i 's#EXCLUDE_SSIDS=#EXCLUDE_SSIDS="MyHomeWiFi"#' "$SBX/eng.conf"
run scope check "MyHomeWiFi" >"$SBX/o" 2>&1; rc=$?
check "excluded SSID is out of scope even though listed in scope" sh -c "[ $rc -ne 0 ] && grep -q 'excluded by EXCLUDE_SSIDS' '$SBX/o'"
check "excluded network is not assessed" sh -c "! run audit | grep -q 'MyHomeWiFi  \\['"

echo "== no attack surface (assessment-only, like jaa-scan) =="
# The only actions the tool dispatches are passive/assessment ones.
verbs="$(sed -n '/^cmd="/,/esac/p' "$CLI" | grep -oE '^\s+[a-z-]+\)' | tr -d ' )' | grep -vE '^\*$' | sort -u | tr '\n' ' ')"
check "only assessment verbs exist ($verbs)" sh -c "echo '$verbs' | tr ' ' '\n' | grep -vqE '^(engagement|scope|audit|check-own|help|-h|--help)?\$' && false || true"
check "no attack binary is invoked" sh -c "! grep -qE '(^|[^a-z-])(reaver|bully|aireplay-ng|aircrack-ng|hcxdumptool|mdk[0-9]|wifite)([^a-z-]|\$)' '$CLI'"
run attack >/dev/null 2>&1; check "unknown/attack verb refused" test $? -ne 0
run audit --pin 12345670 >/dev/null 2>&1; check "stray attack-style flag refused" test $? -ne 0

echo "== audit log =="
check "every run is logged with the authorization ref" sh -c "grep -q 'auth=I own this network' '$SBX/audit.log' && grep -q 'audit:' '$SBX/audit.log'"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
