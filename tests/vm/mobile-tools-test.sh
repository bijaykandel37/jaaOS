#!/usr/bin/env bash
# jaaOS test: jaa-mobile (fake adb) and the Termux toolkit (fake pkg/pip, real bash for the audit
# hook). No phone, no network, no root. The real-file checks (LineageOS signature, APK signers)
# are documented in docs/12-mobile-build.md §Test results.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/mobile/jaa-mobile"
TSETUP="$REPO/mobile/termux/jaa-devsec-setup.sh"
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
check() { if "${@:2}"; then ok "$1"; else no "$1"; fi; }

# ---------------------------------------------------------------- fake phone
cat > "$SBX/adb" <<'EOF'
#!/usr/bin/env bash
LOG="$FAKE_DIR/adb.log"
if [ "$1" = devices ]; then echo "List of devices attached"; printf 'RZ8N00A71\tdevice\n'; exit 0; fi
[ "$1" = -s ] && shift 2
echo "$*" >> "$LOG"
case "$1" in
	install) [ -f "${@: -1}" ] && echo "Performing Streamed Install" && echo Success || echo "Failure [no file]"; exit 0 ;;
	push) echo "1 file pushed"; exit 0 ;;
	shell) shift ;;
esac
case "$*" in
	"getprop ro.lineage.version") echo "${FAKE_LINEAGE-23.2-20261118-NIGHTLY-a71}" ;;
	"getprop ro.product.device") echo a71 ;;
	"getprop ro.product.model") echo SM-A715F ;;
	"getprop ro.build.version.release") echo 16 ;;
	"getprop ro.build.version.security_patch") echo 2026-11-01 ;;
	"cmd package list packages -U com.termux") echo "package:com.termux uid:10201" ;;
	"cmd package list packages -U io.heckel.ntfy") echo "package:io.heckel.ntfy uid:10202" ;;
	"cmd package list packages -U de.nulide.findmydevice") echo "package:de.nulide.findmydevice uid:10203" ;;
	"cmd package list packages -U org.connectbot") ;;
	"cmd netpolicy get restrict-background") echo "Restrict background status: enabled" ;;
	"pm list users") echo "Users:"; echo "	UserInfo{0:Owner:c13} running" ;;
	"pm get-max-users") echo "Maximum supported users: 4" ;;
esac
EOF
chmod +x "$SBX/adb"
export ADB="$SBX/adb" FAKE_DIR="$SBX" JAA_MOBILE_STATE="$SBX/state" JAA_MOBILE_APKS="$SBX/apks" JAA_MOBILE_HASH_ONLY=1
LOG="$SBX/adb.log"

# A lock with fake APKs (hash-only path; the signer path was tested against the real APKs).
mkdir -p "$SBX/apks"
mk() { printf 'fake apk %s\n' "$2" > "$SBX/apks/$2.apk"; printf '%s\t%s\t1.0\t1\thttps://f-droid.org/repo/%s.apk\t%s\tsigner\t%s\n' "$1" "$2" "$2" "$(sha256sum "$SBX/apks/$2.apk" | cut -d' ' -f1)" "$2"; }
{
	echo "# test lock"
	mk core org.fdroid.fdroid; mk core com.aurora.store; mk microg com.google.android.gms; mk microg com.android.vending
	mk devsec com.termux; mk security de.nulide.findmydevice; mk security io.heckel.ntfy
} > "$SBX/apps.lock"
export JAA_MOBILE_LOCK="$SBX/apps.lock"

echo "== setup (pure flavour = no Google code) =="
: > "$LOG"
out="$(bash "$CLI" setup 2>&1)"; rc=$?
check "setup succeeds on LineageOS A71" test $rc -eq 0
check "installs F-Droid + Aurora (Play Store apps)" sh -c "grep -q 'install -r .*org.fdroid.fdroid.apk' '$LOG' && grep -q 'install -r .*com.aurora.store.apk' '$LOG'"
check "pure flavour installs NO microG" sh -c "! grep -qE 'install .*(com.google.android.gms|com.android.vending)' '$LOG'"
check "installs Termux, FMD (remote wipe), ntfy (alerts)" sh -c "grep -q com.termux.apk '$LOG' && grep -q findmydevice '$LOG' && grep -q ntfy '$LOG'"
check "speed defaults: animations 0.5x" grep -q 'settings put global window_animation_scale 0.5' "$LOG"
check "toolkit script pushed to the phone" grep -q 'push .*jaa-devsec-setup.sh /sdcard/Download/' "$LOG"

echo "== setup (microg flavour) =="
: > "$LOG"
bash "$CLI" setup --flavor microg >/dev/null 2>&1
first="$(grep -m1 '^install' "$LOG")"
check "microG installed first (before Play apps)" sh -c "echo '$first' | grep -q com.google.android.gms"
check "microG Companion installed" grep -q 'install -r .*com.android.vending.apk' "$LOG"

echo "== refusals =="
: > "$LOG"
FAKE_LINEAGE='' bash "$CLI" setup >"$SBX/o" 2>&1; rc=$?
check "refuses on a phone not running LineageOS" sh -c "[ $rc -ne 0 ] && grep -q 'not running LineageOS' '$SBX/o'"
check "nothing installed on stock" sh -c "! grep -q '^install' '$LOG'"
echo tampered >> "$SBX/apks/com.aurora.store.apk"
bash "$CLI" setup >"$SBX/o" 2>&1; rc=$?
check "refuses a tampered APK (hash mismatch)" sh -c "[ $rc -ne 0 ] && grep -q 'com.aurora.store is missing or unverified' '$SBX/o'"
JAA_MOBILE_HASH_ONLY=0 APKSIGNER='' PATH="/usr/bin:/bin" bash "$CLI" fetch-apps >"$SBX/o" 2>&1; rc=$?
check "without apksigner, signer check is required unless opted out" sh -c "[ $rc -ne 0 ] && grep -q 'apksigner not found' '$SBX/o'"
bash "$CLI" setup --flavor gapps >/dev/null 2>&1; check "unknown flavour refused" test $? -ne 0
sed 's#https://f-droid.org/repo/org.fdroid.fdroid.apk#https://evil.example/fdroid.apk#' "$SBX/apps.lock" > "$SBX/evil.lock"
JAA_MOBILE_LOCK="$SBX/evil.lock" bash "$CLI" fetch-apps >"$SBX/o" 2>&1; rc=$?
check "lock URLs must be the official repos" sh -c "[ $rc -ne 0 ] && grep -q 'not an official repo' '$SBX/o'"

echo "== low-bandwidth mode =="
: > "$LOG"
bash "$CLI" lowbw on >"$SBX/o" 2>&1
check "Data Saver on" grep -qx 'shell cmd netpolicy set restrict-background true' "$LOG"
check "Termux (SSH) keeps background data" grep -qx 'shell cmd netpolicy add restrict-background-whitelist 10201' "$LOG"
check "ntfy (alerts) + FMD (wipe) keep background data" sh -c "grep -q 'whitelist 10202' '$LOG' && grep -q 'whitelist 10203' '$LOG'"
check "missing app is skipped, not fatal" grep -q 'org.connectbot not installed' "$SBX/o"
: > "$LOG"; bash "$CLI" lowbw off >/dev/null 2>&1
check "off removes the allowlist and Data Saver" sh -c "grep -q 'remove restrict-background-whitelist 10201' '$LOG' && grep -qx 'shell cmd netpolicy set restrict-background false' '$LOG'"

echo "== audit log of every adb command (this computer) =="
check "audit log written" test -s "$SBX/state/audit.log"
check "audit lists the install commands" grep -q 'adb install -r' "$SBX/state/audit.log"
out="$(bash "$CLI" audit verify 2>&1)"; check "audit chain verifies" sh -c "echo \"\$0\" | grep -q 'audit log intact'" "$out"
cp "$SBX/state/audit.log" "$SBX/audit.bak"
sed -i '3s/adb /adb  /' "$SBX/state/audit.log"
bash "$CLI" audit verify >"$SBX/o" 2>&1; rc=$?
check "edited audit line detected" sh -c "[ $rc -ne 0 ] && grep -q 'broken at line 3' '$SBX/o'"
cp "$SBX/audit.bak" "$SBX/state/audit.log"; sed -i '2d' "$SBX/state/audit.log"
bash "$CLI" audit verify >/dev/null 2>&1; check "deleted audit line detected" test $? -ne 0

echo "== workspace =="
out="$(bash "$CLI" workspace 2>&1)"
check "workspace shows max users + Private space" sh -c "echo \"\$0\" | grep -q 'Maximum users: 4' && echo \"\$0\" | grep -q 'Private space'" "$out"

# ---------------------------------------------------------------- Termux toolkit
echo "== Termux toolkit (fake pkg/pip) =="
T="$SBX/termux"; mkdir -p "$T/home" "$T/usr/bin" "$T/fakebin"
for c in pkg pip sv-enable; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls.log"\n' "$c" "$T" > "$T/fakebin/$c"; chmod +x "$T/fakebin/$c"; done
run_setup() { HOME="$T/home" PREFIX="$T/usr" PATH="$T/fakebin:$PATH" JAA_TERMUX_TEST=1 bash "$TSETUP" "$@"; }
run_setup >"$SBX/o" 2>&1; rc=$?
check "toolkit setup completes" test $rc -eq 0
check "installs DevOps tools (kubectl helm k9s gh git)" sh -c "grep '^pkg install' '$T/calls.log' | grep -q kubectl && grep '^pkg install' '$T/calls.log' | grep -wq k9s && grep '^pkg install' '$T/calls.log' | grep -wq gh"
check "installs security tools (nmap dnsutils radare2 termshark)" sh -c "grep '^pkg install' '$T/calls.log' | grep -wq nmap && grep '^pkg install' '$T/calls.log' | grep -wq termshark"
check "no exploit/brute-force tools" sh -c "! grep '^pkg install' '$T/calls.log' | grep -qwE 'metasploit|hydra|sqlmap|john|hashcat|aircrack-ng'"
check "pip: ansible-core + yamllint" grep -q 'pip install --upgrade ansible-core yamllint' "$T/calls.log"
check "sshd: no passwords" grep -qx 'PasswordAuthentication no' "$T/usr/etc/ssh/sshd_config"
check "jaa-audit, jaa-alert installed" sh -c "[ -x '$T/usr/bin/jaa-audit' ] && [ -x '$T/usr/bin/jaa-alert' ]"
check "no desktop without --desktop" test ! -e "$T/usr/bin/jaa-desktop"
run_setup --desktop >/dev/null 2>&1
check "--desktop installs xfce4 + tigervnc" sh -c "grep -q 'pkg install -y xfce4 tigervnc' '$T/calls.log' && [ -x '$T/usr/bin/jaa-desktop' ]"
check "desktop VNC is localhost-only" grep -q -- '-localhost yes' "$T/usr/bin/jaa-desktop"
run_setup >/dev/null 2>&1
check "re-run does not duplicate the .bashrc hook" test "$(grep -c 'jaa/audit.bash' "$T/home/.bashrc")" = 1

echo "== Termux audit log (real interactive bash) =="
HOME="$T/home" PATH="$T/usr/bin:$PATH" bash --rcfile "$T/home/.bashrc" -i >/dev/null 2>&1 <<'EOF'
echo first
 echo hidden-with-leading-space
false
cd /tmp
exit
EOF
AL="$T/home/.jaa/audit.log"
check "commands logged" sh -c "grep -q 'echo first' '$AL' && grep -q 'cd /tmp' '$AL'"
check "leading-space commands still logged" grep -q 'hidden-with-leading-space' "$AL"
check "exit code recorded (false -> rc=1)" grep -qP 'rc=1\t[^\t]*\tfalse\t' "$AL"
check "exit code recorded (cd -> rc=0)" grep -qP 'rc=0\t[^\t]*\tcd /tmp\t' "$AL"
out="$(HOME="$T/home" bash "$T/usr/bin/jaa-audit" verify 2>&1)"
check "chain verifies" sh -c "echo \"\$0\" | grep -q 'intact'" "$out"
sed -i '1s/echo first/echo FIRST/' "$AL"
HOME="$T/home" bash "$T/usr/bin/jaa-audit" verify >/dev/null 2>&1
check "tampering detected" test $? -ne 0

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
