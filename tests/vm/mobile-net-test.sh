#!/usr/bin/env bash
# jaaOS test: jaa-net (LAN visibility) with a canned nmap XML + ARP table (no radio, no scan).
# Checks the authorization/scope gate, device discovery + change detection, that `block` is the
# router-admin path (never ARP-spoof), that there is no attack surface, and that the dashboard
# files are self-contained. The live browser render is a manual check (docs/13-mobile-netadmin.md).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/mobile/net/jaa-net"
PARSE="$REPO/mobile/net/jaa-net-scan.py"
DASH="$REPO/mobile/net/dashboard"
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
check() { if "${@:2}"; then ok "$1"; else no "$1"; fi; }

cat > "$SBX/scan.xml" <<'EOF'
<?xml version="1.0"?><nmaprun>
<host><status state="up"/><address addr="192.168.1.1" addrtype="ipv4"/><address addr="a4:2b:b0:11:22:33" addrtype="mac" vendor="TP-Link"/><hostnames><hostname name="router.lan"/></hostnames><ports><port protocol="tcp" portid="80"><state state="open"/><service name="http" product="lighttpd"/></port></ports></host>
<host><status state="up"/><address addr="192.168.1.50" addrtype="ipv4"/><address addr="de:ad:be:ef:00:50" addrtype="mac"/><hostnames><hostname name="jaa-phone"/></hostnames></host>
<host><status state="up"/><address addr="192.168.1.20" addrtype="ipv4"/><address addr="3c:5a:b4:aa:bb:cc" addrtype="mac" vendor="Google"/><ports><port protocol="tcp" portid="8008"><state state="open"/><service name="http"/></port></ports></host>
</nmaprun>
EOF
cat > "$SBX/neigh.txt" <<'EOF'
192.168.1.1 dev wlan0 lladdr a4:2b:b0:11:22:33 REACHABLE
192.168.1.20 dev wlan0 lladdr 3c:5a:b4:aa:bb:cc STALE
EOF
printf 'A42BB0 TP-Link\n3C5AB4 Google\n' > "$SBX/oui.txt"
cat > "$SBX/eng.conf" <<'EOF'
NAME=home
AUTHORIZATION_REF=I own this network
OPERATOR=tester
SCOPE_SSIDS="MyHomeWiFi"
SCOPE_BSSIDS=
SCOPE_SUBNETS=
EXCLUDE_SSIDS=
EXCLUDE_BSSIDS=
EOF
# NET_CIDR is the host's own CIDR (.50/24), as a real phone derives it — NOT the network address
# users put in SCOPE_SUBNETS (.0/24). This exercises proper subnet containment.
base_env=(JAA_WIFI_ENGAGEMENT="$SBX/eng.conf" JAA_NET_STATE="$SBX/state" JAA_NET_AUDIT="$SBX/audit.log"
	JAA_NET_IP=192.168.1.50 JAA_NET_GW=192.168.1.1 JAA_NET_CIDR=192.168.1.50/24
	JAA_NET_SCAN="$SBX/scan.xml" JAA_NET_NEIGH="$SBX/neigh.txt" JAA_NET_OUI="$SBX/oui.txt")
run() { env "${base_env[@]}" JAA_NET_SSID="$1" bash "$CLI" "${@:2}" 2>&1; }

echo "== parser: discovery, vendors, change detection =="
j="$(python3 -I "$PARSE" --xml "$SBX/scan.xml" --neigh "$SBX/neigh.txt" --oui "$SBX/oui.txt" --self 192.168.1.50 --gateway 192.168.1.1 --ssid MyHomeWiFi)"
check "finds all 3 devices" sh -c "echo '$j' | jq -e '.counts.total==3' >/dev/null"
check "flags the gateway" sh -c "echo '$j' | jq -e '.devices[]|select(.ip==\"192.168.1.1\")|.is_gateway' >/dev/null"
check "flags this phone" sh -c "echo '$j' | jq -e '.devices[]|select(.ip==\"192.168.1.50\")|.is_self' >/dev/null"
check "resolves vendor from OUI + nmap" sh -c "echo '$j' | jq -e '[.devices[].vendor]|index(\"Google\") and index(\"TP-Link\")' >/dev/null"
check "captures open ports + product" sh -c "echo '$j' | jq -e '.devices[]|select(.ip==\"192.168.1.1\")|.open_ports[0].product==\"lighttpd\"' >/dev/null"
echo "$j" > "$SBX/state/baseline.json" 2>/dev/null || { mkdir -p "$SBX/state"; echo "$j" > "$SBX/state/baseline.json"; }
# second scan: .20 gone, .99 new
cat > "$SBX/scan2.xml" <<'EOF'
<?xml version="1.0"?><nmaprun>
<host><status state="up"/><address addr="192.168.1.1" addrtype="ipv4"/><address addr="a4:2b:b0:11:22:33" addrtype="mac"/></host>
<host><status state="up"/><address addr="192.168.1.50" addrtype="ipv4"/><address addr="de:ad:be:ef:00:50" addrtype="mac"/></host>
<host><status state="up"/><address addr="192.168.1.99" addrtype="ipv4"/><address addr="aa:00:11:22:33:44" addrtype="mac"/></host>
</nmaprun>
EOF
j2="$(python3 -I "$PARSE" --xml "$SBX/scan2.xml" --self 192.168.1.50 --gateway 192.168.1.1 --ssid MyHomeWiFi --baseline "$SBX/state/baseline.json")"
check "detects a new device (.99 marked new)" sh -c "echo '$j2' | jq -e '.devices[]|select(.ip==\"192.168.1.99\")|.status==\"new\"' >/dev/null"
check "detects a device that left (.20)" sh -c "echo '$j2' | jq -e '[.left[].ip]|index(\"192.168.1.20\")' >/dev/null"
check "keeps first_seen for a known device" sh -c "echo '$j2' | jq -e '.devices[]|select(.ip==\"192.168.1.1\")|.status==\"known\"' >/dev/null"

echo "== change detection: a device seen by MAC then only by IP is NOT a false left+joined =="
printf '<?xml version="1.0"?><nmaprun><host><status state="up"/><address addr="10.0.0.9" addrtype="ipv4"/><address addr="11:22:33:44:55:66" addrtype="mac"/><ports><port protocol="tcp" portid="22"><state state="open"/><service name="ssh"/></port></ports></host></nmaprun>' > "$SBX/m1.xml"
printf '<?xml version="1.0"?><nmaprun><host><status state="up"/><address addr="10.0.0.9" addrtype="ipv4"/></host></nmaprun>' > "$SBX/m2.xml"
python3 -I "$PARSE" --xml "$SBX/m1.xml" --ssid W > "$SBX/m1.json"
m2="$(python3 -I "$PARSE" --xml "$SBX/m2.xml" --ssid W --baseline "$SBX/m1.json")"
check "mac-then-ip device stays known (not new)" sh -c "echo '$m2' | jq -e '.devices[]|select(.ip==\"10.0.0.9\")|.status==\"known\"' >/dev/null"
check "mac-then-ip device is NOT reported as left" sh -c "echo '$m2' | jq -e '.counts.left==0' >/dev/null"
check "open ports carry forward through a light refresh" sh -c "echo '$m2' | jq -e '.devices[]|select(.ip==\"10.0.0.9\")|.open_ports[0].port==22' >/dev/null"

echo "== authorization / scope gate (refuses like jaa-scan) =="
run NoEngagement map >/dev/null 2>&1 || true
JAA_WIFI_ENGAGEMENT="$SBX/none" env "${base_env[@]}" JAA_NET_SSID=x bash "$CLI" map >/dev/null 2>&1; check "no engagement -> refuses" test $? -ne 0
out="$(run CoffeeShop_Free map)"; rc=$?
check "connected to an out-of-scope network -> refuses to scan" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q 'not in your engagement scope'" "$out"
out="$(run MyHomeWiFi map)"
check "in-scope network -> maps it" sh -c "echo \"\$0\" | grep -q 'DEVICES ON MyHomeWiFi'" "$out"
check "table marks gateway + this phone" sh -c "echo \"\$0\" | grep -q '\\[GW\\] 192.168.1.1' && echo \"\$0\" | grep -q '\\[ME\\] 192.168.1.50'" "$out"
# scope by subnet (network address) while the phone's CIDR is the host form (.50/24) -> containment
printf 'NAME=h\nAUTHORIZATION_REF=mine\nOPERATOR=t\nSCOPE_SUBNETS=192.168.1.0/24\n' > "$SBX/sub.conf"
env "${base_env[@]}" JAA_WIFI_ENGAGEMENT="$SBX/sub.conf" JAA_NET_SSID=Unknown bash "$CLI" map >/dev/null 2>&1
check "authorizes by SCOPE_SUBNETS (network addr vs host CIDR)" test $? -eq 0
printf 'NAME=h\nAUTHORIZATION_REF=mine\nOPERATOR=t\nSCOPE_SUBNETS=10.0.0.0/8\n' > "$SBX/sub2.conf"
env "${base_env[@]}" JAA_WIFI_ENGAGEMENT="$SBX/sub2.conf" JAA_NET_SSID=Unknown bash "$CLI" map >/dev/null 2>&1
check "refuses when the subnet does not contain this host" test $? -ne 0

echo "== exclusions always win (EXCLUDE_BSSIDS / EXCLUDE_SUBNETS) =="
printf 'NAME=h\nAUTHORIZATION_REF=mine\nOPERATOR=t\nSCOPE_SSIDS="MyHomeWiFi"\nEXCLUDE_BSSIDS=aa:bb:cc:dd:ee:ff\n' > "$SBX/ex.conf"
out="$(env "${base_env[@]}" JAA_WIFI_ENGAGEMENT="$SBX/ex.conf" JAA_NET_SSID=MyHomeWiFi JAA_NET_BSSID=AA:BB:CC:DD:EE:FF bash "$CLI" map 2>&1)"; rc=$?
check "EXCLUDE_BSSIDS blocks an in-SSID-scope network" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q EXCLUDE_BSSIDS" "$out"
printf 'NAME=h\nAUTHORIZATION_REF=mine\nOPERATOR=t\nSCOPE_SUBNETS=192.168.1.0/24\nEXCLUDE_SUBNETS=192.168.1.0/24\n' > "$SBX/ex2.conf"
env "${base_env[@]}" JAA_WIFI_ENGAGEMENT="$SBX/ex2.conf" JAA_NET_SSID=Unknown bash "$CLI" map >/dev/null 2>&1
check "EXCLUDE_SUBNETS wins over SCOPE_SUBNETS" test $? -ne 0

echo "== serve --port validation =="
out="$(run MyHomeWiFi serve --port 99999 2>&1)"; check "rejects port > 65535" sh -c "echo \"\$0\" | grep -q '1-65535'" "$out"
out="$(run MyHomeWiFi serve --port abc 2>&1)"; check "rejects non-numeric port" sh -c "echo \"\$0\" | grep -q '1-65535'" "$out"

echo "== run_scan leaves no temp files on scanner failure =="
tdir="$SBX/tmp"; mkdir -p "$tdir"; before=$(find "$tdir" -type f | wc -l)
TMPDIR="$tdir" env "${base_env[@]}" JAA_WIFI_ENGAGEMENT="$SBX/eng.conf" JAA_NET_SSID=MyHomeWiFi JAA_NET_SCAN="$SBX/does-not-exist.xml" bash "$CLI" map >/dev/null 2>&1 || true
after=$(find "$tdir" -type f | wc -l)
check "no temp files leaked when the scan input is missing" test "$before" = "$after"

echo "== device scope =="
out="$(run MyHomeWiFi device 8.8.8.8)"; rc=$?
check "refuses a device off the authorized subnet" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q 'not on the authorized network'" "$out"
run MyHomeWiFi device 192.168.1.20 >/dev/null 2>&1; check "accepts a device on the authorized subnet" test $? -eq 0

echo "== block is the router-admin path, never an attack =="
out="$(run MyHomeWiFi block 192.168.1.20)"
check "block explains the router/admin method" sh -c "echo \"\$0\" | grep -q 'ADMINISTRATOR' && echo \"\$0\" | grep -q 'http://192.168.1.1'" "$out"
check "block explicitly refuses ARP-spoof/NetCut" sh -c "echo \"\$0\" | grep -qi 'does NOT ARP-spoof'" "$out"
check "block shows the MAC to filter" sh -c "echo \"\$0\" | grep -q '3c:5a:b4:aa:bb:cc'" "$out"
check "no attack binary is invoked in jaa-net" sh -c "! grep -qE '(^|[^a-z._-])(arpspoof|ettercap|bettercap|aireplay-ng|mdk[0-9]|mitmproxy|dsniff)([^a-z._-]|\$)' '$CLI'"

echo "== dashboard is self-contained (no external calls) =="
check "index.html present" test -f "$DASH/index.html"
check "only local assets referenced" sh -c "! grep -qE 'https?://[^\"]*(cdn|googleapis|unpkg|jsdelivr|http)' '$DASH/index.html' '$DASH/app.js'"
check "app.js escapes values before the DOM" grep -q 'function esc' "$DASH/app.js"
check "app.js only fetches local data.json" sh -c "grep -q 'fetch(\"data.json' '$DASH/app.js' && ! grep -qE 'fetch\\((\"|.)https?:' '$DASH/app.js'"
python3 -I -c "import html.parser,sys
class P(html.parser.HTMLParser):
    pass
P().feed(open('$DASH/index.html').read()); print('ok')" >/dev/null 2>&1 && ok "index.html parses" || no "index.html parses"

echo "== audit log =="
check "every map is audited with the authorization ref" sh -c "grep -q 'auth=I own this network' '$SBX/audit.log' && grep -q 'map ' '$SBX/audit.log'"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
