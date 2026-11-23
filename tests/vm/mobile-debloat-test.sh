#!/usr/bin/env bash
# jaaOS test: jaa-debloat against a FAKE adb (no phone, no root). Checks device selection, that
# plan changes nothing, that tiers are respected, that protected packages are never removed (even
# when a list names them), that hostile list entries cannot reach the phone's shell, and restore.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/mobile/debloat/jaa-debloat"
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
check() { if "${@:2}"; then ok "$1"; else no "$1"; fi; }

# --- fake adb: one Samsung phone; records every shell command ---
cat > "$SBX/adb" <<'EOF'
#!/usr/bin/env bash
LOG="$FAKE_DIR/adb.log"
if [ "$1" = devices ]; then
	echo "List of devices attached"
	case "${FAKE_DEVICES:-one}" in
		one)   printf 'R5CT00000AB\tdevice\n' ;;
		two)   printf 'R5CT00000AB\tdevice\nR5CT00000CD\tdevice\n' ;;
		unauth) printf 'R5CT00000AB\tunauthorized\n' ;;
		none)  ;;
	esac
	exit 0
fi
[ "$1" = -s ] && shift 2
[ "$1" = shell ] && shift
echo "$*" >> "$LOG"
case "$*" in
	"getprop ro.product.manufacturer") echo "${FAKE_MAKER:-samsung}" ;;
	"getprop ro.product.model") echo "${FAKE_MODEL:-SM-S921B}" ;;
	"getprop ro.product.device") echo "${FAKE_CODE:-e1s}" ;;
	"getprop ro.build.version.release") echo "${FAKE_ANDROID:-14}" ;;
	"getprop ro.lineage.version") echo "${FAKE_LINEAGE:-}" ;;
	"getprop sys.oem_unlock_allowed") echo "${FAKE_OEMUNLOCK:-0}" ;;
	"dumpsys account")
		[ "${FAKE_GACCT:-0}" = 1 ] && echo "    Account {name=me@gmail.com, type=com.google}"
		# Shape of a real A71 dump: 2 Google accounts, other account types, and the
		# authenticator list (which must not be counted as accounts).
		[ "${FAKE_GACCT:-0}" = real ] && printf '%s\n' \
			"User UserInfo{0:Owner:c13}:" "  Accounts: 4" \
			"    Account {name=a@gmail.com, type=com.google}" \
			"    Account {name=b@gmail.com, type=com.google}" \
			"    Account {name=+15550100, type=com.google.android.apps.tachyon}" \
			"    Account {name=me, type=com.whatsapp}" \
			"  RegisteredServicesCache: 3 services" \
			"    ServiceInfo: AuthenticatorDescription {type=com.google}, ComponentInfo{com.google.android.gms/x}, uid 10236" \
			"    ServiceInfo: AuthenticatorDescription {type=com.google.android.gm.pop3}, ComponentInfo{com.google.android.gm/y}, uid 10247" \
			"    ServiceInfo: AuthenticatorDescription {type=com.google.work}, ComponentInfo{com.google.android.gms/z}, uid 10236"
		;;
	"dumpsys battery") echo "  level: ${FAKE_BATTERY:-80}" ;;
	"getprop ro.boot.flash.locked") echo 1 ;;
	"pm list packages")
		for p in android com.android.systemui com.sec.android.app.camera com.google.android.webview \
			com.google.android.youtube com.google.android.gms com.android.vending com.android.chrome \
			com.facebook.appmanager com.samsung.android.bixby.agent com.samsung.android.app.spage \
			com.samsung.knox.securefolder; do echo "package:$p"; done ;;
	"pm uninstall -k --user 0 "*) echo Success ;;
	"cmd package install-existing --user 0 "*) echo "Package ${*##* } installed for user: 0" ;;
	"pm list users") echo "Users:"; echo "	UserInfo{0:Owner:c13} running" ;;
esac
EOF
chmod +x "$SBX/adb"
export ADB="$SBX/adb" FAKE_DIR="$SBX" JAA_DEBLOAT_STATE="$SBX/state"
LOG="$SBX/adb.log"
removes() { grep -c '^pm uninstall' "$LOG" 2>/dev/null || true; }

echo "== device selection =="
FAKE_DEVICES=none   bash "$CLI" check >/dev/null 2>"$SBX/e"; check "no phone -> refuses with USB-debugging help" grep -q 'USB debugging' "$SBX/e"
FAKE_DEVICES=unauth bash "$CLI" check >/dev/null 2>"$SBX/e"; check "unauthorised phone -> asks to tap Allow" grep -q "Allow" "$SBX/e"
FAKE_DEVICES=two    bash "$CLI" check >/dev/null 2>"$SBX/e"; check "two phones -> refuses" grep -q 'more than one device' "$SBX/e"
FAKE_MAKER=Xiaomi   bash "$CLI" check >/dev/null 2>"$SBX/e"; check "non-Samsung -> refuses" grep -q "Samsung" "$SBX/e"
out="$(bash "$CLI" check 2>&1)"
check "check reports model + locked bootloader" sh -c "echo \"\$0\" | grep -q 'SM-S921B' && echo \"\$0\" | grep -q 'bootloader:   locked'" "$out"
check "check says custom ROM not possible when OEM unlock is off" sh -c "echo \"\$0\" | grep -q 'custom ROM is NOT possible'" "$out"

echo "== plan changes nothing and respects tiers =="
: > "$LOG"
safe="$(bash "$CLI" plan --tier safe 2>/dev/null)"
check "plan runs no uninstall" test "$(removes)" = 0
check "safe tier includes Facebook updater" sh -c "echo \"\$0\" | grep -q com.facebook.appmanager" "$safe"
check "safe tier excludes YouTube (standard)" sh -c "! echo \"\$0\" | grep -q com.google.android.youtube" "$safe"
std="$(bash "$CLI" plan --tier standard 2>/dev/null)"
check "standard tier includes YouTube + Chrome" sh -c "echo \"\$0\" | grep -q com.google.android.youtube && echo \"\$0\" | grep -q com.android.chrome" "$std"
check "standard tier keeps Play Services" sh -c "! echo \"\$0\" | grep -q com.google.android.gms" "$std"
check "not-installed packages are not planned" sh -c "! echo \"\$0\" | grep -q com.google.android.apps.maps" "$std"
agg="$(bash "$CLI" plan --tier aggressive 2>/dev/null)"
check "aggressive tier includes Play Services + Store" sh -c "echo \"\$0\" | grep -q com.google.android.gms && echo \"\$0\" | grep -q com.android.vending" "$agg"
bash "$CLI" plan --tier everything >/dev/null 2>&1; check "unknown tier refused" test $? -ne 0

echo "== apply =="
: > "$LOG"
echo nope | bash "$CLI" apply --tier safe >/dev/null 2>&1
check "apply without typing REMOVE changes nothing" test "$(removes)" = 0
bash "$CLI" apply --tier standard --yes >/dev/null 2>&1
check "apply removes YouTube for user 0 (-k)" grep -qx 'pm uninstall -k --user 0 com.google.android.youtube' "$LOG"
check "apply never touches the camera" sh -c "! grep -q 'uninstall.*camera' '$LOG'"
check "apply never touches WebView" sh -c "! grep -q 'uninstall.*webview' '$LOG'"
check "apply never touches Secure Folder" sh -c "! grep -q 'uninstall.*securefolder' '$LOG'"
check "removals recorded for restore" grep -q com.google.android.youtube "$SBX/state/removed-R5CT00000AB.txt"

echo "== protected wins over a list, hostile entries are refused =="
mkdir -p "$SBX/lists"; cp "$REPO/mobile/debloat/lists/protected.txt" "$SBX/lists/"
cat > "$SBX/lists/google.txt" <<'EOF'
safe com.sec.android.app.camera          # listed by mistake: must stay protected
safe com.google.android.webview          # ditto
safe com.evil;reboot                     # shell injection attempt
safe com.ok.app$(touch /sdcard/pwned)    # command substitution attempt
EOF
: > "$LOG"
JAA_DEBLOAT_LISTS="$SBX/lists" bash "$CLI" apply --tier safe --yes >"$SBX/o" 2>&1
check "protected camera not removed though listed" sh -c "! grep -q 'uninstall.*camera' '$LOG'"
check "protected webview not removed though listed" sh -c "! grep -q 'uninstall.*webview' '$LOG'"
check "injection entries never reach adb" sh -c "! grep -qE 'reboot|pwned' '$LOG'"
check "invalid names reported" grep -q 'invalid package name' "$SBX/o"

echo "== restore =="
: > "$LOG"
bash "$CLI" restore --all >/dev/null 2>&1
check "restore --all reinstalls YouTube" grep -qx 'cmd package install-existing --user 0 com.google.android.youtube' "$LOG"
bash "$CLI" restore 'x;reboot' >/dev/null 2>&1
check "restore refuses invalid names" sh -c "! grep -q reboot '$LOG'"

echo "== workspace =="
out="$(bash "$CLI" workspace 2>&1)"
check "workspace reports Secure Folder available" sh -c "echo \"\$0\" | grep -q 'Secure Folder:  available'" "$out"

echo "== rom-check (Galaxy A71) =="
# JAA_DEVICE_OFFLINE=1 keeps rom-check off the network in CI (resolves a71 from supported.txt).
A71=(JAA_DEVICE_OFFLINE=1 FAKE_CODE=a71 FAKE_MODEL=SM-A715F FAKE_ANDROID=13 FAKE_OEMUNLOCK=1 FAKE_GACCT=0 FAKE_BATTERY=80)
: > "$LOG"
out="$(env "${A71[@]}" bash "$CLI" rom-check 2>&1)"; rc=$?
check "A71 ready: all checks pass" sh -c "[ $rc -eq 0 ] && echo \"\$0\" | grep -q READY" "$out"
check "A71: names LineageOS 23.2 and the guide" sh -c "echo \"\$0\" | grep -q '23.2' && echo \"\$0\" | grep -q 'mobile/devices/a71.md'" "$out"
check "A71: warns about VoLTE" sh -c "echo \"\$0\" | grep -q 'VoLTE'" "$out"
check "rom-check flashes/removes nothing" sh -c "! grep -qE 'uninstall|reboot|flash' '$LOG'"
out="$(env "${A71[@]}" FAKE_MODEL=SM-A715F/DS bash "$CLI" rom-check 2>&1)"; rc=$?
check "A71 dual-SIM model accepted" test $rc -eq 0
out="$(env "${A71[@]}" FAKE_ANDROID=12 bash "$CLI" rom-check 2>&1)"; rc=$?
check "wrong stock firmware fails" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q 'needs stock Android 13'" "$out"
out="$(env "${A71[@]}" FAKE_GACCT=1 bash "$CLI" rom-check 2>&1)"; rc=$?
check "Google account (FRP) fails" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q 'Google account'" "$out"
out="$(env "${A71[@]}" FAKE_GACCT=real bash "$CLI" rom-check 2>&1)"; rc=$?
check "counts Google accounts, not authenticators (regression)" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q 'FAIL  2 Google account'" "$out"
out="$(env "${A71[@]}" FAKE_OEMUNLOCK=0 bash "$CLI" rom-check 2>&1)"; rc=$?
check "OEM unlocking off fails" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q 'OEM unlocking is off'" "$out"
out="$(env "${A71[@]}" FAKE_MODEL=SM-A716B bash "$CLI" rom-check 2>&1)"; rc=$?
check "A71 5G model (SM-A716B) refused" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q 'do NOT flash'" "$out"
out="$(env "${A71[@]}" FAKE_BATTERY=20 bash "$CLI" rom-check 2>&1)"; rc=$?
check "low battery fails" test $rc -ne 0
out="$(JAA_DEVICE_OFFLINE=1 FAKE_CODE=notarealdevice99 bash "$CLI" rom-check 2>&1)"; rc=$?
check "phone with no LineageOS build -> stay on path A" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q 'path A'" "$out"

echo "== LineageOS: apply refuses =="
: > "$LOG"
FAKE_LINEAGE=23.2 bash "$CLI" apply --tier safe --yes >"$SBX/o" 2>&1; rc=$?
check "apply refuses on LineageOS" sh -c "[ $rc -ne 0 ] && grep -q 'runs LineageOS' '$SBX/o'"
check "nothing removed on LineageOS" test "$(removes)" = 0

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
