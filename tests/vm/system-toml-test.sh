#!/usr/bin/env bash
# jaaOS Phase 7 test: the declarative `jaa diff`/`apply` reconciler over the shipped
# system.toml, with drift forced deterministically (nothing installed/enabled) so the plan is
# predictable. No root, no apt, no systemctl changes.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/packages/jaa/bin/jaa"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

export JAA_SYSTEM_TOML="$REPO/config/rootfs/etc/jaa/system.toml"
export JAA_SYSTEM_PREFIX="$SBX"       # empty -> no ports open
export JAA_FAKE_INSTALLED=            # set-but-empty -> nothing installed
export JAA_FAKE_ENABLED="avahi-daemon"  # only avahi "enabled" -> it needs disabling

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }

echo "== diff parses every section of the shipped system.toml =="
d="$(bash "$CLI" diff 2>&1)"
printf '%s' "$d" | grep -q "profile: server" && ok "profile parsed" || no "profile parsed"
for p in git tmux jq; do printf '%s' "$d" | grep -q "+ $p (install)" && ok "package $p pending" || no "package $p pending"; done
for s in ssh nftables auditd; do printf '%s' "$d" | grep -q "+ $s (enable)" && ok "service $s enable" || no "service $s enable"; done
printf '%s' "$d" | grep -q "+ avahi-daemon (disable)" && ok "avahi disable detected" || no "avahi disable detected"
for port in 22 80 443; do printf '%s' "$d" | grep -q "+ $port (open)" && ok "port $port pending" || no "port $port pending"; done

echo "== apply --dry-run emits the reconciliation commands, executes nothing =="
a="$(bash "$CLI" apply --dry-run 2>&1)"
printf '%s' "$a" | grep -q "jaa install server" && ok "profile install planned" || no "profile install planned"
printf '%s' "$a" | grep -q "apt-get install -y git" && ok "package install planned" || no "package install planned"
printf '%s' "$a" | grep -q "systemctl enable --now ssh" && ok "service enable planned" || no "service enable planned"
printf '%s' "$a" | grep -q "systemctl disable --now avahi-daemon" && ok "service disable planned" || no "service disable planned"
printf '%s' "$a" | grep -q "jaa_tcp_open { 443 }" && ok "port open planned" || no "port open planned"
printf '%s' "$a" | grep -q "dry-run: nothing executed" && ok "states nothing executed" || no "states nothing executed"

echo "== satisfied items are not re-applied =="
# Mark everything as already installed/enabled and port 443 open -> plan should shrink.
echo 'add element inet filter jaa_tcp_open { 443 }' > "$SBX/etc_nft" 2>/dev/null || true
mkdir -p "$SBX/etc/nftables.d"; echo 'add element inet filter jaa_tcp_open { 22 }' > "$SBX/etc/nftables.d/jaa-host.nft"
a2="$(JAA_FAKE_INSTALLED='git tmux jq' JAA_FAKE_ENABLED='ssh nftables auditd' bash "$CLI" apply --dry-run 2>&1)"
printf '%s' "$a2" | grep -q "apt-get install -y git" && no "installed pkg should be skipped" || ok "installed pkg skipped"
printf '%s' "$a2" | grep -q "enable --now ssh" && no "enabled svc should be skipped" || ok "enabled svc skipped"
printf '%s' "$a2" | grep -q "{ 22 }" && no "already-open port 22 should be skipped" || ok "already-open port skipped"
printf '%s' "$a2" | grep -q "disable --now avahi-daemon" && no "avahi off now, skip disable" || ok "avahi disable skipped when off"

echo "== apply --dry-run succeeds with exit 0 (regression) =="
JAA_SYSTEM_TOML="$REPO/config/rootfs/etc/jaa/system.toml" bash "$CLI" apply --dry-run >/dev/null 2>&1 \
	&& ok "apply --dry-run exits 0" || no "apply --dry-run exits 0"

echo "== malicious system.toml tokens are rejected, not eval'd (regression) =="
mkdir -p "$SBX/t"
for tok in 'packages = ["git; touch PWNED"]' 'tcp = [80]
[s]
x = 1
[firewall2]' ; do :; done
printf 'packages = ["a; touch %s/PWNED"]\n' "$SBX/t" > "$SBX/inj.toml"
JAA_SYSTEM_TOML="$SBX/inj.toml" JAA_FAKE_INSTALLED= bash "$CLI" apply --dry-run >/dev/null 2>&1
{ [ ! -e "$SBX/t/PWNED" ]; } && ok "package-name injection refused" || no "package-name injection refused"
printf '[firewall]\ntcp = [99999]\n' > "$SBX/badport.toml"
JAA_SYSTEM_TOML="$SBX/badport.toml" bash "$CLI" apply --dry-run >/dev/null 2>&1 \
	&& no "out-of-range port should be refused" || ok "out-of-range port refused"

echo "== missing system.toml is refused =="
JAA_SYSTEM_TOML="$SBX/nope.toml" bash "$CLI" diff >/dev/null 2>&1 && no "missing toml should fail" || ok "missing toml refused"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
