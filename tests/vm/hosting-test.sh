#!/usr/bin/env bash
# BastionOS Phase 4 test: exercise bastion-host config GENERATION into a sandbox prefix (no
# root, no live services). It asserts the right files/content are produced and the firewall +
# monitoring side-effects are recorded. Live validation/reload happens on a real host via the
# command pipeline (see docs/05-phase4-hosting.md).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/packages/bastion-host/bin/bastion-host"
SBX="$(mktemp -d)"
export BASTION_HOST_PREFIX="$SBX"
trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
has() { grep -qF "$2" "$1" 2>/dev/null; }

echo "== site create (nginx, proxy) =="
bash "$CLI" site create demo.local --proxy http://127.0.0.1:3000 >/dev/null
f="$SBX/etc/nginx/sites-available/demo.local.conf"
[ -f "$f" ] && ok "nginx site file written" || no "nginx site file written"
has "$f" "proxy_pass http://127.0.0.1:3000" && ok "proxy_pass present" || no "proxy_pass present"
has "$f" "server_name demo.local" && ok "server_name present" || no "server_name present"

echo "== site create (nginx, php) =="
bash "$CLI" site create php.local --php 8.3 >/dev/null
f="$SBX/etc/nginx/sites-available/php.local.conf"
has "$f" "php8.3-fpm.sock" && ok "php-fpm socket wired" || no "php-fpm socket wired"

echo "== site create (caddy) =="
bash "$CLI" site create caddy.local --engine caddy --proxy http://127.0.0.1:9000 >/dev/null
f="$SBX/etc/caddy/bastion.d/caddy.local.caddy"
has "$f" "reverse_proxy http://127.0.0.1:9000" && ok "caddy reverse_proxy present" || no "caddy reverse_proxy present"

echo "== lb create (haproxy, leastconn, health) =="
bash "$CLI" lb create app-lb --backend 10.0.0.11:80 --backend 10.0.0.12:80 --algo leastconn --health /healthz --port 8080 >/dev/null
f="$SBX/etc/haproxy/conf.d/app-lb.cfg"
has "$f" "balance leastconn" && ok "haproxy balance leastconn" || no "haproxy balance leastconn"
has "$f" "server app-lb1 10.0.0.11:80 check" && ok "backend 1 present" || no "backend 1 present"
has "$f" "server app-lb2 10.0.0.12:80 check" && ok "backend 2 present" || no "backend 2 present"
has "$f" "option httpchk GET /healthz" && ok "health check present" || no "health check present"

echo "== lb create (traefik) =="
bash "$CLI" lb create tr-lb --backend 10.0.0.21:80 --engine traefik >/dev/null
f="$SBX/etc/traefik/dynamic/tr-lb.yml"
has "$f" "url: \"http://10.0.0.21:80\"" && ok "traefik backend url present" || no "traefik backend url present"

echo "== ha create (keepalived) =="
bash "$CLI" ha create vip0 --vip 10.0.0.10/24 --interface eth0 --priority 150 --state MASTER >/dev/null
f="$SBX/etc/keepalived/conf.d/vip0.conf"
has "$f" "virtual_ipaddress" && has "$f" "10.0.0.10/24" && ok "keepalived VIP present" || no "keepalived VIP present"
has "$f" "state MASTER" && ok "keepalived state MASTER" || no "keepalived state MASTER"

echo "== firewall + monitoring side-effects =="
has "$SBX/etc/nftables.d/bastion-host.nft" "bastion_tcp_open { 80 }" && ok "port 80 opened" || no "port 80 opened"
has "$SBX/etc/nftables.d/bastion-host.nft" "bastion_tcp_open { 8080 }" && ok "lb port 8080 opened" || no "lb port 8080 opened"
[ -f "$SBX/etc/bastion/monitoring/targets.d/site-demo.local.json" ] && ok "monitoring target for site" || no "monitoring target for site"
has "$SBX/etc/bastion/monitoring/targets.d/lb-app-lb.json" '"__metrics_path__":"/healthz"' && ok "lb monitoring target + health path" || no "lb monitoring target + health path"

echo "== list =="
bash "$CLI" site list | grep -q demo.local && ok "site list shows demo.local" || no "site list shows demo.local"
bash "$CLI" lb list | grep -q app-lb && ok "lb list shows app-lb" || no "lb list shows app-lb"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
