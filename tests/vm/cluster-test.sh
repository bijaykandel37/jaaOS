#!/usr/bin/env bash
# jaaOS test: jaa-cluster config GENERATION into a sandbox prefix (no root, no network, no
# services). Asserts the RKE2 config, firewall drop-in, host tuning and recorded service actions
# for each role, and that hostile input is refused before it reaches YAML or nft.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/packages/jaa-cluster/bin/jaa-cluster"
SBX="$(mktemp -d)"
export JAA_CLUSTER_PREFIX="$SBX"
trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
check() { if "${@:2}"; then ok "$1"; else no "$1"; fi; }
refuses() { local name="$1"; shift; if bash "$CLI" "$@" >/dev/null 2>&1; then no "$name"; else ok "$name"; fi; }

CFG="$SBX/etc/rancher/rke2/config.yaml"
CONF="$SBX/etc/jaa/cluster.conf"
NFT="$SBX/etc/nftables.d/jaa-cluster.nft"
ACT="$SBX/.jaa-cluster-actions"
ZRAM="$SBX/etc/systemd/zram-generator.conf"
mkdir -p "$(dirname "$ZRAM")"
printf '[zram0]\nzram-size = ram / 2\n' > "$ZRAM"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tjaa\n' > "$SBX/hosts.tmp"; mkdir -p "$SBX/etc"; mv "$SBX/hosts.tmp" "$SBX/etc/hosts"

echo "== setup master =="
bash "$CLI" setup master --name jaa-master-ab12 --cidr 192.168.1.0/24 >/dev/null
check "config: node-name"            has "$CFG" 'node-name: "jaa-master-ab12"'
check "config: cni canal"            has "$CFG" 'cni: canal'
check "config: tls-san .local"       has "$CFG" '"jaa-master-ab12.local"'
check "config: kubeconfig 0600"      has "$CFG" 'write-kubeconfig-mode: "0600"'
check "config: no server line"       sh -c "! grep -q '^server:' '$CFG'"
check "config: generated token"      grep -qE '^token: "[0-9a-f]{40}"$' "$CFG"
check "config file mode 0600"        test "$(stat -c %a "$CFG")" = 600
check "role recorded as server"      has "$CONF" 'ROLE=server'
check "fw: control-plane ports LAN only" has "$NFT" 'ip saddr { 192.168.1.0/24 } tcp dport { 6443, 9345, 2379-2381, 10250 } accept'
check "fw: vxlan + mDNS LAN only"    has "$NFT" 'ip saddr { 192.168.1.0/24 } udp dport { 5353, 8472 } accept'
check "fw: pod interfaces forwarded" has "$NFT" 'add rule inet filter jaa_cluster_fwd iifname "cali*" accept'
check "fw: chains flushed first"     sh -c "head -4 '$NFT' | grep -q 'flush chain inet filter jaa_cluster_in'"
check "sysctl: ip_forward"           has "$SBX/etc/sysctl.d/90-jaa-cluster.conf" 'net.ipv4.ip_forward = 1'
check "modules: br_netfilter"        has "$SBX/etc/modules-load.d/jaa-cluster.conf" 'br_netfilter'
check "NM ignores CNI interfaces"    has "$SBX/etc/NetworkManager/conf.d/90-jaa-rke2.conf" 'interface-name:cali*'
check "zram (swap) disabled"         sh -c "! grep -q '^\[zram' '$ZRAM'"
check "zram original kept"           has "$ZRAM.jaa-orig" '[zram0]'
check "hostname set"                 has "$SBX/etc/hostname" 'jaa-master-ab12'
check "hosts 127.0.1.1 updated"      has "$SBX/etc/hosts" 'jaa-master-ab12'
check "rke2-server enabled"          has "$ACT" 'systemctl enable rke2-server.service'
check "rke2-agent disabled"          has "$ACT" 'systemctl disable rke2-agent.service'

CANAL="$SBX/var/lib/rancher/rke2/server/manifests/jaa-canal-iface.yaml"
check "canal pinned to the LAN NIC (master)" has "$CANAL" "regexIface: '^192\\.168\\.1\\.'"

echo "== flannel interface regex matches exactly the LAN =="
rx_of() { JAA_CLUSTER_PREFIX="$SBX/rx" bash "$CLI" setup master --name rx --cidr "$1" >/dev/null; sed -n "s/.*regexIface: '\(.*\)'/\1/p" "$SBX/rx/var/lib/rancher/rke2/server/manifests/jaa-canal-iface.yaml"; }
RX="$(rx_of 10.1.16.0/20,172.16.5.0/24)"
for ip in 10.1.16.1 10.1.31.254 172.16.5.9; do check "regex matches $ip" sh -c "echo $ip | grep -qE '$RX'"; done
for ip in 10.1.15.1 10.1.32.1 172.16.50.9 10.0.2.15; do check "regex rejects $ip" sh -c "! echo $ip | grep -qE '$RX'"; done
check "yaml quoting parses" python3 -c "import yaml,sys; d=yaml.safe_load(open('$SBX/rx/var/lib/rancher/rke2/server/manifests/jaa-canal-iface.yaml')); assert yaml.safe_load(d['spec']['valuesContent'])['flannel']['regexIface'].startswith('^10')"

echo "== re-running setup keeps the cluster secret =="
tok1="$(sed -n 's/^token: //p' "$CFG")"
bash "$CLI" setup master --name jaa-master-ab12 --cidr 192.168.1.0/24 >/dev/null
check "token unchanged"              test "$(sed -n 's/^token: //p' "$CFG")" = "$tok1"

echo "== join (worker) with a CA-pinned token =="
: > "$ACT"
H="$(printf 'ca' | sha256sum | cut -d' ' -f1)"
bash "$CLI" join 192.168.1.10 "K10${H}::abcdef.0123456789abcdef" --name jaa-worker-cd34 --cidr 192.168.1.0/24 >/dev/null
check "config: server url"           has "$CFG" 'server: "https://192.168.1.10:9345"'
check "config: pinned token"         has "$CFG" "token: \"K10${H}::abcdef.0123456789abcdef\""
check "config: no node-ip unless asked" sh -c "! grep -q node-ip '$CFG'"
check "no canal manifest on a worker" test ! -e "$SBX/var/lib/rancher/rke2/server/manifests/jaa-canal-iface.yaml"
check "config: no tls-san on worker" sh -c "! grep -q tls-san '$CFG'"
check "role recorded as agent"       has "$CONF" 'ROLE=agent'
check "master address recorded"      has "$CONF" 'SERVER=https://192.168.1.10:9345'
check "fw: worker opens kubelet only" has "$NFT" 'tcp dport { 10250 } accept'
check "fw: worker has no API port"   sh -c "! grep -q 6443 '$NFT'"
check "rke2-agent enabled"           has "$ACT" 'systemctl enable rke2-agent.service'
check "rke2-server disabled"         has "$ACT" 'systemctl disable rke2-server.service'

echo "== --node-ip for multi-NIC machines =="
bash "$CLI" setup master --name m2 --cidr 192.168.77.0/24 --node-ip 192.168.77.10 >/dev/null
check "config: node-ip"              has "$CFG" 'node-ip: "192.168.77.10"'
check "node-ip recorded for join-code" has "$CONF" 'NODE_IP=192.168.77.10'

echo "== hostile or malformed input is refused =="
refuses "bad --node-ip"               setup master --name n1 --cidr 10.0.0.0/8 --node-ip '1.2.3.4"x'

refuses "worker without token"        setup worker --server 192.168.1.10 --cidr 192.168.1.0/24
refuses "worker without server"       setup worker --token "K10${H}::abcdef.0123456789abcdef"
refuses "YAML injection in token"     setup worker --server 192.168.1.10 --token 'abc"\nserver: "https://evil'
refuses "short secret token"          setup master --token short --name n1 --cidr 10.0.0.0/8
refuses "nft injection in --cidr"     setup master --name n1 --cidr '10.0.0.0/8 } accept; flush ruleset; {'
refuses "prefix > 32"                 setup master --name n1 --cidr 10.0.0.0/33
refuses "octet > 255"                 setup master --name n1 --cidr 300.0.0.0/8
refuses "uppercase node name"         setup master --name Master1 --cidr 10.0.0.0/8
refuses "shell chars in server"       setup worker --server 'evil;reboot' --token "K10${H}::abcdef.0123456789abcdef" --cidr 10.0.0.0/8
refuses "malformed join code"         join 192.168.1.10 not-a-code
refuses "unknown role"                setup boss
refuses "bad ttl"                     join-code --ttl forever

echo "== setup none undoes the role =="
: > "$ACT"
bash "$CLI" setup none >/dev/null
check "role recorded as none"        has "$CONF" 'ROLE=none'
check "rke2 config removed"          test ! -e "$CFG"
check "zram restored"                has "$ZRAM" '[zram0]'
check "canal manifest removed"       test ! -e "$CANAL"
check "sysctl drop-in removed"       test ! -e "$SBX/etc/sysctl.d/90-jaa-cluster.conf"
check "fw: only flushes left"        sh -c "! grep -q 'add rule' '$NFT'"
check "both services disabled"       sh -c "grep -q 'disable rke2-server' '$ACT' && grep -q 'disable rke2-agent' '$ACT'"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
