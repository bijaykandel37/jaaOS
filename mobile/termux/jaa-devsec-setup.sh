#!/usr/bin/env bash
# jaa-devsec-setup.sh — the jaaOS Mobile DevOps + security toolkit, installed INSIDE Termux.
# Pushed to the phone by `jaa-mobile setup`. On the phone, in Termux:
#
#   termux-setup-storage
#   bash ~/storage/downloads/jaa-devsec-setup.sh            # full toolkit + SSH + audit log + alerts
#   MINIMAL=1 bash ~/storage/downloads/jaa-devsec-setup.sh  # lightweight core only (fast, small)
#   bash ~/storage/downloads/jaa-devsec-setup.sh --desktop  # + XFCE Linux desktop (over VNC)
#
# MINIMAL=1 installs a small core (git, ssh, nmap, python, tmux, jq …) instead of the ~95-package
# full toolkit; add more later with `pkg install <name>` or a full distro with `jaa-linux`.
#
# Every package name below was checked against the Termux package index (aarch64) on 2026-11-22.
# Security tools are for AUTHORIZED assessment only (same rule as jaaOS's jaa-scan): network
# discovery, DNS/TLS checks, traffic and binary analysis. No exploit frameworks, brute-forcers or
# DoS tools are installed.
set -euo pipefail

DESKTOP=0
for a in "$@"; do
	case "$a" in
		--desktop) DESKTOP=1 ;;
		*) echo "unknown option: $a" >&2; exit 2 ;;
	esac
done

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
if [ "${JAA_TERMUX_TEST:-0}" != 1 ]; then
	case "$PREFIX" in */com.termux/*) ;; *) echo "run this inside the Termux app" >&2; exit 1 ;; esac
fi

BASE=(termux-tools termux-api termux-services coreutils busybox ncurses-utils openssl openssh git curl
	wget rsync jq yq tmux neovim vim nano htop btop tree ripgrep fd fzf bat zoxide direnv starship mosh
	gnupg pass age sops restic rclone croc)
DEVOPS=(python python-pip nodejs-lts golang rust make cmake clang kubectl helm k9s gh awscli doctl
	httpie postgresql mariadb redis sqlite openjdk-21 maven gradle ruby php perl shellcheck mc)
SECURITY=(nmap dnsutils ldns whois traceroute mtr iperf3 netcat-openbsd socat openssl-tool iproute2
	net-tools lsof nethogs tor torsocks proxychains-ng radare2 rizin binwalk gdb strace ltrace termshark
	tshark sslscan iw wireless-tools wpa-supplicant arp-scan exiftool yara jadx apktool)
# VPN / tunnels / full-Linux userland. openvpn + wg-quick are CLI; the GUI VPN apps
# (OpenVPN for Android, Tailscale->Headscale) come from apps.lock. proot-distro gives a real
# Debian/Kali chroot where `apt install` works — see jaa-linux.
NETVPN=(openvpn wireguard-tools openssh-sftp-server proot proot-distro tsu)
PIP=(ansible-core yamllint)
DESKTOP_PKGS=(xfce4 tigervnc)

# A small, fast core for the lightweight build (every name verified in the Termux index).
CORE=(termux-tools termux-api openssh git curl wget jq tmux vim nano htop tree ripgrep fzf
	python openssl nmap dnsutils iproute2 openvpn proot-distro)

echo "== jaaOS Mobile toolkit: updating Termux"
pkg update -y
if [ "${MINIMAL:-0}" = 1 ]; then
	echo "== MINIMAL core (${#CORE[@]} packages) — add more with 'pkg install' or 'jaa-linux'"
	pkg install -y "${CORE[@]}"
else
	echo "== base, DevOps, security and VPN packages (${#BASE[@]} + ${#DEVOPS[@]} + ${#SECURITY[@]} + ${#NETVPN[@]})"
	pkg install -y "${BASE[@]}" "${DEVOPS[@]}" "${SECURITY[@]}" "${NETVPN[@]}"
	echo "== Python tools: ${PIP[*]}"
	pip install --upgrade "${PIP[@]}"
fi

# ---- SSH: keys only ----------------------------------------------------------------------
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
SSHD_CFG="$PREFIX/etc/ssh/sshd_config"
mkdir -p "$(dirname "$SSHD_CFG")"; touch "$SSHD_CFG"
for kv in "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitRootLogin no"; do
	k="${kv%% *}"
	if grep -qE "^#?$k " "$SSHD_CFG"; then sed -i -E "s|^#?$k .*|$kv|" "$SSHD_CFG"; else echo "$kv" >> "$SSHD_CFG"; fi
done
sv-enable sshd 2>/dev/null || true

# ---- audit log of every command run in Termux ------------------------------------------------
mkdir -p "$HOME/.jaa"
cat > "$HOME/.jaa/audit.bash" <<'AUDIT'
# jaaOS Mobile: log every command line typed in this shell to ~/.jaa/audit.log, hash-chained.
# Tamper-EVIDENT (jaa-audit verify finds edits/deletions), not tamper-proof: without root, the
# same user that runs commands owns the log. Ship it off the phone with `jaa-audit ship`.
HISTCONTROL=; HISTIGNORE=           # commands starting with a space must not escape the log
__JAA_AUDIT_LOG="$HOME/.jaa/audit.log"; __JAA_AUDIT_N=""
__jaa_audit() {
	local rc=$? h n cmd prev body
	h="$(HISTTIMEFORMAT='' builtin history 1)"; n="$(awk '{print $1}' <<<"$h")"
	[ -n "$n" ] && [ "$n" != "$__JAA_AUDIT_N" ] || return $rc
	__JAA_AUDIT_N="$n"; cmd="$(sed -E 's/^ *[0-9]+\*? *//' <<<"$h")"
	prev="0000000000000000000000000000000000000000000000000000000000000000"
	[ -s "$__JAA_AUDIT_LOG" ] && prev="$(tail -1 "$__JAA_AUDIT_LOG" | awk -F'\t' '{print $NF}')"
	body="$(date -u +%FT%TZ)	rc=$rc	$PWD	${cmd//$'\t'/ }"
	printf '%s\t%s\n' "$body" "$(printf '%s%s' "$prev" "$body" | sha256sum | cut -d' ' -f1)" >> "$__JAA_AUDIT_LOG"
	return $rc
}
case ";${PROMPT_COMMAND:-};" in *__jaa_audit*) ;; *) PROMPT_COMMAND="__jaa_audit${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;; esac
AUDIT
touch "$HOME/.bashrc"
grep -qF '.jaa/audit.bash' "$HOME/.bashrc" || printf '\n[ -r ~/.jaa/audit.bash ] && . ~/.jaa/audit.bash   # jaaOS audit log\n' >> "$HOME/.bashrc"

mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/jaa-audit" <<'TOOL'
#!/usr/bin/env bash
# jaa-audit — show, verify or ship the Termux command audit log (~/.jaa/audit.log).
#   jaa-audit            last 20 entries
#   jaa-audit verify     check the hash chain (detects edited or deleted lines)
#   jaa-audit ship user@host:path   copy the log off the phone over SSH
set -euo pipefail
LOG="$HOME/.jaa/audit.log"
[ -f "$LOG" ] || { echo "no audit log yet"; exit 0; }
case "${1:-show}" in
	show) tail -20 "$LOG" | cut -f1-4 ;;
	verify)
		prev="0000000000000000000000000000000000000000000000000000000000000000"; n=0
		while IFS= read -r line; do
			n=$((n + 1)); body="${line%$'\t'*}"; hash="${line##*$'\t'}"
			[ "$(printf '%s%s' "$prev" "$body" | sha256sum | cut -d' ' -f1)" = "$hash" ] \
				|| { echo "BROKEN at line $n: the log was edited or a line was removed" >&2; exit 1; }
			prev="$hash"
		done < "$LOG"
		echo "audit log intact: $n entries" ;;
	ship)
		dest="${2:?usage: jaa-audit ship user@host:path}"
		scp -q "$LOG" "$dest" && echo "shipped $LOG to $dest" ;;
	*) echo "usage: jaa-audit [show|verify|ship user@host:path]" >&2; exit 2 ;;
esac
TOOL
chmod 0755 "$PREFIX/bin/jaa-audit"

# ---- alerts: local notification + optional push through ntfy ---------------------------------
cat > "$PREFIX/bin/jaa-alert" <<'TOOL'
#!/usr/bin/env bash
# jaa-alert "message" — show a phone notification; also push it to ntfy if JAA_NTFY_URL is set
# (e.g. export JAA_NTFY_URL=https://ntfy.sh/your-private-topic in ~/.bashrc).
set -euo pipefail
msg="${*:?usage: jaa-alert message}"
termux-notification --title "jaaOS alert" --content "$msg" --priority high 2>/dev/null || echo "ALERT: $msg"
if [ -n "${JAA_NTFY_URL:-}" ]; then curl -fsS -d "$msg" "$JAA_NTFY_URL" >/dev/null && echo "pushed to ntfy"; fi
TOOL
chmod 0755 "$PREFIX/bin/jaa-alert"

# ---- jaa-linux: a full Debian/Kali userland (proot-distro) ----------------------------------
cat > "$PREFIX/bin/jaa-linux" <<'TOOL'
#!/usr/bin/env bash
# jaa-linux — a full Linux userland on the phone via proot-distro, where apt works and you can
# install anything your DevOps/security work needs (nikto, sqlmap, the Kali metapackages, …)
# that Termux's own repos do not carry. It is YOUR distro — install only what you are authorized
# to use. No root, no separate partition.
#   jaa-linux install [debian|ubuntu|kali]   # kali: then `apt install kali-linux-headless`
#   jaa-linux shell   [debian|ubuntu|kali]   # enter it
#   jaa-linux list                           # installed distros
set -euo pipefail
d="${2:-debian}"
case "${1:-shell}" in
	install) proot-distro install "$d" && echo "Installed $d. Enter it with: jaa-linux shell $d" ;;
	shell)   proot-distro login "$d" 2>/dev/null || { echo "'$d' not installed. Run: jaa-linux install $d" >&2; exit 1; } ;;
	list)    proot-distro list | sed -n '/Installed/,$p' ;;
	*) echo "usage: jaa-linux install|shell|list [debian|ubuntu|kali]" >&2; exit 2 ;;
esac
TOOL
chmod 0755 "$PREFIX/bin/jaa-linux"

# ---- jaa-vpn: OpenVPN / WireGuard from the command line --------------------------------------
cat > "$PREFIX/bin/jaa-vpn" <<'TOOL'
#!/usr/bin/env bash
# jaa-vpn — bring a VPN up/down from a config file (needs the VpnService permission; run once
# with `sudo` or via the OpenVPN/WireGuard apps for the tun device). For a tap-to-connect GUI use
# the OpenVPN for Android / Tailscale apps (Tailscale -> your Headscale login server).
#   jaa-vpn up   ~/vpn/client.ovpn      # OpenVPN
#   jaa-vpn up   ~/vpn/wg0.conf         # WireGuard (.conf)
#   jaa-vpn down                        # stop whatever is running
set -euo pipefail
case "${1:-}" in
	up)
		cfg="${2:?usage: jaa-vpn up CONFIG(.ovpn|.conf)}"
		case "$cfg" in
			*.ovpn) exec openvpn --config "$cfg" ;;
			*.conf) exec wg-quick up "$cfg" ;;
			*) echo "config must end .ovpn (OpenVPN) or .conf (WireGuard)" >&2; exit 2 ;;
		esac ;;
	down) pkill -INT openvpn 2>/dev/null; wg-quick down all 2>/dev/null; echo "VPN stopped" ;;
	*) echo "usage: jaa-vpn up CONFIG | down   (GUI: OpenVPN for Android / Tailscale apps)" >&2; exit 2 ;;
esac
TOOL
chmod 0755 "$PREFIX/bin/jaa-vpn"

# ---- home-screen shortcuts (Termux:Widget) --------------------------------------------------
# Termux:Widget shows ~/.shortcuts/* as a home-screen widget of one-tap buttons; Termux:Tasker
# can trigger ~/.shortcuts/tasks/* from Tasker / a Quick-Settings tile. These are the jaaOS
# "quick actions" for daily DevOps/security work.
mkdir -p "$HOME/.shortcuts/tasks"
sc() { install -m0700 /dev/stdin "$HOME/.shortcuts/$1"; }
sc "net-dashboard"  <<'S'
#!/usr/bin/env bash
# Network map + dashboard (http://127.0.0.1:8088)
am start -a android.intent.action.VIEW -d http://127.0.0.1:8088 >/dev/null 2>&1 &
exec jaa-net serve
S
sc "wifi-audit"     <<'S'
#!/usr/bin/env bash
exec jaa-wifi audit
S
sc "capture"        <<'S'
#!/usr/bin/env bash
# Live packet capture (Wireshark-style TUI). Ctrl+C to stop.
read -r -p "interface [wlan0]: " i; exec termshark -i "${i:-wlan0}"
S
sc "portscan"       <<'S'
#!/usr/bin/env bash
read -r -p "target (host/CIDR you are authorized to scan): " t; [ -n "$t" ] && exec nmap -sV -T4 "$t"
S
sc "linux-shell"    <<'S'
#!/usr/bin/env bash
exec jaa-linux shell debian
S
sc "linux-desktop"  <<'S'
#!/usr/bin/env bash
jaa-desktop start && am start -a android.intent.action.VIEW -d vnc://127.0.0.1:5901 >/dev/null 2>&1
echo "desktop on 127.0.0.1:5901 — open it in AVNC"
S
sc "openvpn"        <<'S'
#!/usr/bin/env bash
am start -n de.blinkt.openvpn/.activities.MainActivity >/dev/null 2>&1 || echo "install OpenVPN for Android"
S
sc "tailscale"      <<'S'
#!/usr/bin/env bash
# Tailscale / Headscale toggle
am start -n com.tailscale.ipn/.MainActivity >/dev/null 2>&1 || echo "install Tailscale (point it at your Headscale login server)"
S
sc "ssh"            <<'S'
#!/usr/bin/env bash
read -r -p "ssh target (user@host): " t; [ -n "$t" ] && exec ssh "$t"
S
sc "sshd-on"        <<'S'
#!/usr/bin/env bash
sshd && echo "sshd up on port 8022 (keys only). Your IP:"; ifconfig 2>/dev/null | awk '/inet /{print "  "$2}'
S
sc "audit-verify"   <<'S'
#!/usr/bin/env bash
jaa-audit verify; read -r -p "press enter"
S
cp "$HOME/.shortcuts/wifi-audit" "$HOME/.shortcuts/tasks/wifi-audit" 2>/dev/null || true
cp "$HOME/.shortcuts/sshd-on"   "$HOME/.shortcuts/tasks/sshd-on"   2>/dev/null || true

# ---- optional Linux desktop (XFCE over VNC) -------------------------------------------------
if [ "$DESKTOP" = 1 ]; then
	echo "== Linux desktop: XFCE + VNC"
	pkg install -y x11-repo
	pkg install -y "${DESKTOP_PKGS[@]}"
	mkdir -p "$HOME/.vnc"
	printf '#!/data/data/com.termux/files/usr/bin/sh\nexec startxfce4\n' > "$HOME/.vnc/xstartup"; chmod 0755 "$HOME/.vnc/xstartup"
	cat > "$PREFIX/bin/jaa-desktop" <<'TOOL'
#!/usr/bin/env bash
# jaa-desktop start|stop — XFCE desktop on VNC display :1, reachable only from this phone
# (localhost). View it with AVNC (127.0.0.1:5901), or from a PC through an SSH tunnel:
#   ssh -p 8022 -L 5901:127.0.0.1:5901 <phone-ip>   then open a VNC viewer on localhost:5901
set -euo pipefail
case "${1:-start}" in
	start) vncserver :1 -localhost yes -geometry 1920x1080 && echo "desktop on 127.0.0.1:5901" ;;
	stop)  vncserver -kill :1 ;;
	*) echo "usage: jaa-desktop start|stop" >&2; exit 2 ;;
esac
TOOL
	chmod 0755 "$PREFIX/bin/jaa-desktop"
fi

# ---- network admin / dashboard (jaa-net) --------------------------------------------------
if [ -f "$HOME/storage/downloads/jaa-net" ]; then
	install -m0755 "$HOME/storage/downloads/jaa-net" "$PREFIX/bin/jaa-net"
	install -m0644 "$HOME/storage/downloads/jaa-net-scan.py" "$PREFIX/bin/jaa-net-scan.py" 2>/dev/null || true
	# the scanner is loaded from the same dir as jaa-net; keep both in bin
	sed -i 's#\$SELF_DIR/jaa-net-scan.py#'"$PREFIX"'/bin/jaa-net-scan.py#; s#\$SELF_DIR/dashboard#'"$PREFIX"'/share/jaa-net/dashboard#' "$PREFIX/bin/jaa-net"
	if [ -d "$HOME/storage/downloads/jaa-net-dashboard" ]; then
		install -d "$PREFIX/share/jaa-net/dashboard"
		install -m0644 "$HOME/storage/downloads/jaa-net-dashboard"/* "$PREFIX/share/jaa-net/dashboard/"
	fi
	echo "== installed jaa-net (network map + dashboard, authorized-network-only)"
fi

# ---- WiFi auditor (jaa-wifi) --------------------------------------------------------------
if [ -f "$HOME/storage/downloads/jaa-wifi" ]; then
	install -m0755 "$HOME/storage/downloads/jaa-wifi" "$PREFIX/bin/jaa-wifi"
	install -Dm0644 "$HOME/storage/downloads/wifi-engagement.example.conf" "$PREFIX/share/jaa-wifi/engagement.example.conf" 2>/dev/null || true
	echo "== installed jaa-wifi (WiFi security auditor, authorized-scope-only)"
fi

# ---- hacker-vibe login banner (motd) ------------------------------------------------------
cat > "$HOME/.jaa/motd.sh" <<'MOTD'
#!/usr/bin/env bash
g=$'\e[38;5;48m'; c=$'\e[38;5;44m'; d=$'\e[38;5;240m'; b=$'\e[1m'; r=$'\e[0m'
printf '%s' "$g$b"
cat <<'ART'
     ▄▄▄  ▄▄▄   ▄▄▄   ▄▄▄  ▄▄▄
     █  █ █▄▄█  █▄▄█  █  █ █▄▄
  ▀▀▀█▄▄█ █  █  █  █  █▄▄█ ▄▄█   m o b i l e
ART
printf '%s' "$r"
printf '  %snode%s %s   %spatch%s %s   %sdevops // sec toolkit online%s\n'   "$d" "$r" "$(uname -m)" "$d" "$r" "$(getprop ro.build.version.security_patch 2>/dev/null || date +%F)" "$c" "$r"
printf '  %sjaa-net serve%s map · %sjaa-wifi audit%s wifi · %sjaa-linux shell%s linux · %sjaa-vpn up%s vpn\n' "$g" "$r" "$g" "$r" "$g" "$r" "$g" "$r"
printf '  %sauthorized use only%s\n\n' "$d" "$r"
MOTD
chmod 0755 "$HOME/.jaa/motd.sh"
grep -qF '.jaa/motd.sh' "$HOME/.bashrc" || printf '\n[ -t 1 ] && [ -x ~/.jaa/motd.sh ] && ~/.jaa/motd.sh   # jaaOS banner\n' >> "$HOME/.bashrc"

cat <<EOF

jaaOS Mobile toolkit installed.
  SSH:      add your public key to ~/.ssh/authorized_keys, then  sshd  (port 8022, keys only)
  Audit:    open a new Termux session; every command is logged. Check:  jaa-audit verify
  Alerts:   jaa-alert "deploy finished"      (set JAA_NTFY_URL to also push to ntfy)
  WiFi:     jaa-wifi engagement init   (list YOUR networks)   then   jaa-wifi audit
  Network:  jaa-net serve   (dashboard at http://127.0.0.1:8088)   ·   jaa-net map   ·   jaa-net watch
  Linux:    jaa-linux install debian   then   jaa-linux shell   (apt works; add Kali tools yourself)
  VPN:      jaa-vpn up ~/vpn/client.ovpn   ·   GUI: OpenVPN for Android / Tailscale (-> your Headscale)
  Capture:  termshark -i wlan0   ·   tshark   ·   PCAPdroid app (no root)
  Shortcuts: add the Termux:Widget to your home screen — one-tap VPN, dashboard, capture, SSH, Linux
$( [ "$DESKTOP" = 1 ] && echo "  Desktop:  jaa-desktop start   then AVNC -> 127.0.0.1:5901 (run vncpasswd first)" )
Security tools are for systems you are authorized to test.
EOF
