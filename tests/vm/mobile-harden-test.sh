#!/usr/bin/env bash
# jaaOS test: jaa-harden against a fake adb. Checks the posture scoring (hardened vs weak phone),
# that audit changes nothing, that apply only writes the safe settings and validates the DNS host.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/mobile/jaa-harden"
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
check() { if "${@:2}"; then ok "$1"; else no "$1"; fi; }

# Fake adb whose settings/getprop answers come from env (so one script models many postures).
cat > "$SBX/adb" <<'EOF'
#!/usr/bin/env bash
LOG="$FAKE_DIR/adb.log"
if [ "$1" = devices ]; then echo x; printf 'HARD0001\tdevice\n'; exit 0; fi
[ "$1" = -s ] && shift 2
[ "$1" = shell ] && shift
echo "$*" >> "$LOG"
case "$1 $2 $3" in
  "settings put global") echo "put global ${4:-} ${5:-}" >> "$FAKE_DIR/puts.log"; exit 0 ;;
  "settings put secure") echo "put secure ${4:-} ${5:-}" >> "$FAKE_DIR/puts.log"; exit 0 ;;
esac
case "$*" in
  "getprop ro.product.model") echo "Test Phone" ;;
  "getprop ro.product.device") echo testdev ;;
  "getprop ro.build.display.id") echo lineage-23.2 ;;
  "getprop ro.crypto.state") echo "${F_CRYPTO:-encrypted}" ;;
  "getenforce") echo "${F_SELINUX:-Enforcing}" ;;
  "getprop ro.build.version.security_patch") echo "${F_PATCH:-$(date -u +%F)}" ;;
  "getprop service.adb.tcp.port") echo "${F_ADBPORT:-}" ;;
  "settings get global package_verifier_enable") echo "${F_VERIFY:-1}" ;;
  "settings get global verifier_verify_adb_installs") echo "${F_ADBVERIFY:-1}" ;;
  "settings get global captive_portal_mode") echo "${F_CAPTIVE:-0}" ;;
  "settings get global private_dns_mode") echo "${F_DNSMODE:-hostname}" ;;
  "settings get global private_dns_specifier") echo "${F_DNS:-dns.quad9.net}" ;;
  "settings get global always_on_vpn_app") echo "${F_VPN:-}" ;;
  "settings get global always_on_vpn_lockdown") echo "${F_VPNLOCK:-0}" ;;
  "settings get global development_settings_enabled") echo "${F_DEV:-0}" ;;
  "settings get global adb_enabled") echo "${F_ADB:-1}" ;;
  "settings get secure lock_screen_allow_private_notifications") echo "${F_LSPRIV:-0}" ;;
  "settings get secure lockscreen_show_silent_notifications") echo "${F_LSSILENT:-0}" ;;
  "pm list packages") [ "${F_GMS:-0}" = 1 ] && echo "package:com.google.android.gms" ;;
esac
EOF
chmod +x "$SBX/adb"
export ADB="$SBX/adb" FAKE_DIR="$SBX" JAA_HARDEN_STATE="$SBX/state"
: > "$SBX/puts.log"

echo "== audit: a hardened phone scores clean =="
out="$(bash "$CLI" audit 2>&1)"
check "hardened phone has 0 FAIL" sh -c "echo \"\$0\" | grep -q 'score: .* 0 fail'" "$out"
check "encryption PASS" sh -c "echo \"\$0\" | grep -q 'PASS  storage is encrypted'" "$out"
check "DoT PASS" sh -c "echo \"\$0\" | grep -q 'encrypted DNS'" "$out"
check "audit writes nothing to the phone" sh -c "! grep -q 'put global' '$SBX/puts.log'"

echo "== audit: a weak phone is flagged =="
out="$(F_DNSMODE=off F_CAPTIVE=1 F_ADBPORT=5555 F_VERIFY=0 F_PATCH=2023-01-01 F_SELINUX=Permissive F_GMS=1 bash "$CLI" audit 2>&1)"; rc=$?
check "weak phone fails overall (rc!=0)" test $rc -ne 0
check "flags clear-text DNS" sh -c "echo \"\$0\" | grep -q 'encrypted DNS is not pinned'" "$out"
check "flags network ADB" sh -c "echo \"\$0\" | grep -q 'ADB over TCP is ON'" "$out"
check "flags no install verification" sh -c "echo \"\$0\" | grep -q 'app install verification is OFF'" "$out"
check "flags stale patch" sh -c "echo \"\$0\" | grep -q 'security patch is old'" "$out"
check "flags permissive SELinux" sh -c "echo \"\$0\" | grep -q 'SELinux not enforcing'" "$out"
check "notes Play Services present" sh -c "echo \"\$0\" | grep -q 'Google Play Services is installed'" "$out"

echo "== apply: only safe settings, confirmation required =="
: > "$SBX/puts.log"
echo nope | bash "$CLI" apply >/dev/null 2>&1
check "apply without typing APPLY changes nothing" sh -c "! grep -q 'put ' '$SBX/puts.log'"
: > "$SBX/puts.log"
echo APPLY | bash "$CLI" apply --dns dns.quad9.net >/dev/null 2>&1
check "sets DoT mode + specifier" sh -c "grep -q 'put global private_dns_mode hostname' '$SBX/puts.log' && grep -q 'put global private_dns_specifier dns.quad9.net' '$SBX/puts.log'"
check "disables captive portal" grep -q 'put global captive_portal_mode 0' "$SBX/puts.log"
check "hides lock-screen notification content" grep -q 'put secure lock_screen_allow_private_notifications 0' "$SBX/puts.log"
check "enables install verification (incl. adb)" sh -c "grep -q 'put global package_verifier_enable 1' '$SBX/puts.log' && grep -q 'put global verifier_verify_adb_installs 1' '$SBX/puts.log'"
check "apply touches nothing else (only 7 writes)" test "$(grep -c '^put ' "$SBX/puts.log")" = 7
echo APPLY | bash "$CLI" apply --dns 'evil;reboot' >/dev/null 2>&1; check "rejects a bad DNS host" test $? -ne 0
check "every run is audited" sh -c "grep -q audit '$SBX/state/audit.log' && grep -q apply '$SBX/state/audit.log'"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
