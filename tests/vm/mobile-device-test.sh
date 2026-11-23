#!/usr/bin/env bash
# jaaOS test: lineage-device-info (multi-device support) with local YAML/API fixtures (no network),
# plus jaa-debloat rom-check driven for a NON-Samsung phone to prove the install flow is generic.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LDI="$REPO/mobile/devices/lineage-device-info"
DEBLOAT="$REPO/mobile/debloat/jaa-debloat"
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
check() { if "${@:2}"; then ok "$1"; else no "$1"; fi; }

# --- fixtures: a Pixel 4a (Google) and a Fairphone 4, as the LineageOS wiki serves them ---
cat > "$SBX/sunfish.yml" <<'EOF'
vendor: Google
name: Pixel 4a
codename: sunfish
models: [sunfish]
before_install: {instructions: 'needs_specific_android_fw', lineage_version: 21, version: '13'}
quirks: []
EOF
printf '{"model":"sunfish","oem":"Google","versions":["23.2","24.0"]}' > "$SBX/sunfish.api"
info() { JAA_DEVICE_YAML="$SBX/$1.yml" JAA_DEVICE_API="$SBX/$1.api" bash "$LDI" "$1" 2>&1; }

echo "== lineage-device-info parses any vendor's metadata =="
o="$(info sunfish)"
check "name"    sh -c "echo \"\$0\" | grep -qx 'NAME=Pixel 4a'" "$o"
check "vendor"  sh -c "echo \"\$0\" | grep -qx 'VENDOR=Google'" "$o"
check "models"  sh -c "echo \"\$0\" | grep -qx 'MODELS=sunfish'" "$o"
check "required stock Android = 13 (not lineage_version 21)" sh -c "echo \"\$0\" | grep -qx 'REQ_ANDROID=13'" "$o"
check "lineage versions from the API" sh -c "echo \"\$0\" | grep -qx 'LINEAGE_VERSIONS=23.2 24.0'" "$o"
check "SOURCE=live when metadata is present" sh -c "echo \"\$0\" | grep -qx 'SOURCE=live'" "$o"

echo "== fetched content cannot execute (injection) =="
rm -f "$SBX/pwned"
printf 'name: X $(touch %s/pwned) `touch %s/pwned`\nvendor: Y\nmodels: [M]\nbefore_install: {version: 13}\n' "$SBX" "$SBX" > "$SBX/evil.yml"
JAA_DEVICE_YAML="$SBX/evil.yml" JAA_DEVICE_API=/dev/null bash "$LDI" evildev >/dev/null 2>&1
check "command substitution in YAML does not run" test ! -e "$SBX/pwned"
bash "$LDI" 'bad;rm -rf x' >/dev/null 2>&1; check "codename is validated" test $? -ne 0

echo "== offline falls back to the curated list; refuses unknown =="
printf '# c | models | fw | lineage | guide\na71 | SM-A715F SM-A715F/DS | 13 | 23.2 (Android 16) | mobile/devices/a71.md\n' > "$SBX/supported.txt"
o="$(JAA_DEVICE_OFFLINE=1 JAA_DEVICE_SUPPORTED="$SBX/supported.txt" bash "$LDI" a71 2>&1)"
check "offline a71 from supported.txt" sh -c "echo \"\$0\" | grep -qx 'SOURCE=offline' && echo \"\$0\" | grep -qx 'REQ_ANDROID=13'" "$o"
JAA_DEVICE_OFFLINE=1 JAA_DEVICE_SUPPORTED="$SBX/supported.txt" bash "$LDI" sunfish >/dev/null 2>&1
check "offline unknown device refused" test $? -ne 0

echo "== rom-check works for a NON-Samsung phone (generic install flow) =="
cat > "$SBX/adb" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = devices ]; then echo "List of devices attached"; printf 'PX4A0001\tdevice\n'; exit 0; fi
[ "$1" = -s ] && shift 2
[ "$1" = shell ] && shift
case "$*" in
  "getprop ro.product.manufacturer") echo Google ;;
  "getprop ro.product.device") echo sunfish ;;
  "getprop ro.product.model") echo "Pixel 4a" ;;
  "getprop ro.build.version.release") echo 13 ;;
  "getprop sys.oem_unlock_allowed") echo 1 ;;
  "dumpsys account") ;;
  "dumpsys battery") echo "  level: 90" ;;
esac
EOF
chmod +x "$SBX/adb"
# device-info helper the debloat tool calls resolves live metadata from our fixture via env.
o="$(ADB="$SBX/adb" JAA_ANY_VENDOR=1 JAA_DEBLOAT_STATE="$SBX/st" JAA_DEVICE_YAML="$SBX/sunfish.yml" JAA_DEVICE_API="$SBX/sunfish.api" bash "$DEBLOAT" rom-check 2>&1)"; rc=$?
check "rom-check READY for a supported Pixel" sh -c "[ $rc -eq 0 ] && echo \"\$0\" | grep -q READY" "$o"
check "rom-check names the device + LineageOS version" sh -c "echo \"\$0\" | grep -q 'Pixel 4a' && echo \"\$0\" | grep -q 'LineageOS 23.2'" "$o"
check "rom-check says generic flow for a non-curated device" sh -c "echo \"\$0\" | grep -q 'generic for this device'" "$o"
# wrong stock firmware on the same phone -> fail
cat > "$SBX/adb2" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = devices ]; then echo x; printf 'PX4A0001\tdevice\n'; exit 0; fi
[ "$1" = -s ] && shift 2; [ "$1" = shell ] && shift
case "$*" in
  "getprop ro.product.manufacturer") echo Google;; "getprop ro.product.device") echo sunfish;;
  "getprop ro.product.model") echo "Pixel 4a";; "getprop ro.build.version.release") echo 12;;
  "getprop sys.oem_unlock_allowed") echo 1;; "dumpsys battery") echo "  level: 90";; esac
EOF
chmod +x "$SBX/adb2"
o="$(ADB="$SBX/adb2" JAA_ANY_VENDOR=1 JAA_DEBLOAT_STATE="$SBX/st" JAA_DEVICE_YAML="$SBX/sunfish.yml" JAA_DEVICE_API="$SBX/sunfish.api" bash "$DEBLOAT" rom-check 2>&1)"; rc=$?
check "wrong stock firmware fails on the Pixel too" sh -c "[ $rc -ne 0 ] && echo \"\$0\" | grep -q 'needs stock Android 13'" "$o"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
