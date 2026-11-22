#!/usr/bin/env bash
# jaa-devsec-setup.sh — the jaaOS Mobile DevOps + security toolkit, installed INSIDE Termux.
# Pushed to the phone by `jaa-mobile setup`. On the phone, in Termux:
#
#   termux-setup-storage
#   bash ~/storage/downloads/jaa-devsec-setup.sh            # toolkit + SSH + audit log + alerts
#   bash ~/storage/downloads/jaa-devsec-setup.sh --desktop  # + XFCE Linux desktop (over VNC)
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
	iw wireless-tools wpa-supplicant)
PIP=(ansible-core yamllint)
DESKTOP_PKGS=(xfce4 tigervnc)

echo "== jaaOS Mobile toolkit: updating Termux"
pkg update -y
echo "== base, DevOps and security packages (${#BASE[@]} + ${#DEVOPS[@]} + ${#SECURITY[@]})"
pkg install -y "${BASE[@]}" "${DEVOPS[@]}" "${SECURITY[@]}"
echo "== Python tools: ${PIP[*]}"
pip install --upgrade "${PIP[@]}"

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

# ---- WiFi auditor (jaa-wifi) --------------------------------------------------------------
if [ -f "$HOME/storage/downloads/jaa-wifi" ]; then
	install -m0755 "$HOME/storage/downloads/jaa-wifi" "$PREFIX/bin/jaa-wifi"
	install -Dm0644 "$HOME/storage/downloads/wifi-engagement.example.conf" "$PREFIX/share/jaa-wifi/engagement.example.conf" 2>/dev/null || true
	echo "== installed jaa-wifi (WiFi security auditor, authorized-scope-only)"
fi

cat <<EOF

jaaOS Mobile toolkit installed.
  SSH:      add your public key to ~/.ssh/authorized_keys, then  sshd  (port 8022, keys only)
  Audit:    open a new Termux session; every command is logged. Check:  jaa-audit verify
  Alerts:   jaa-alert "deploy finished"      (set JAA_NTFY_URL to also push to ntfy)
  WiFi:     jaa-wifi engagement init   (list YOUR networks)   then   jaa-wifi audit
$( [ "$DESKTOP" = 1 ] && echo "  Desktop:  jaa-desktop start   then AVNC -> 127.0.0.1:5901 (run vncpasswd first)" )
Security tools are for systems you are authorized to test.
EOF
