#!/usr/bin/env bash
# Runs INSIDE the live-ISO chroot (build/mklive.sh), after 10-customize.sh.
# Live-only tweaks: per-boot identity, no baked-in SSH host keys, a working apt source,
# a zstd initramfs that contains live-boot, and removal of caches that only add size.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

# --- identity: every boot (and every copy of the ISO) gets its own machine-id ---
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

# --- SSH: never ship host keys inside a public ISO; generate them on each boot instead ---
rm -f /etc/ssh/ssh_host_*
cat > /etc/systemd/system/jaa-ssh-hostkeys.service <<'EOF'
[Unit]
Description=jaaOS live: generate SSH host keys for this boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
systemctl enable jaa-ssh-hostkeys.service >/dev/null

# --- apt: the build used a temporary keyring path; point the live system at Debian directly ---
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://deb.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

# --- fstab: / is live-boot's overlay. Container storage cannot sit on an overlay (Docker's
# overlay2 and RKE2's containerd snapshotter need a real upper filesystem), so it goes in RAM.
cat > /etc/fstab <<'EOF'
# jaaOS live: / is an overlay over the squashfs (live-boot). Container storage lives in RAM.
tmpfs /var/lib/docker     tmpfs mode=0710 0 0
tmpfs /var/lib/containerd tmpfs mode=0711 0 0
tmpfs /var/lib/rancher    tmpfs mode=0755 0 0
tmpfs /var/lib/kubelet    tmpfs mode=0750 0 0
EOF
mkdir -p /var/lib/docker /var/lib/containerd /var/lib/rancher /var/lib/kubelet

# --- login message for the live session ---
cat > /etc/motd <<'EOF'

  jaaOS lite (live). Nothing you change here is kept after a reboot.

    sudo jaa-install             install to a disk (asks: Kubernetes master / worker / none)
    sudo jaa-cluster setup ...   try an RKE2 master or worker right here (needs 8 GB RAM)
    docker run --rm hello-world  Docker is built in (starts on first use)
    jaa-keys                     keyboard shortcuts (Tab, Ctrl+R, Alt+S = sudo, ...)

EOF

# --- desktop edition: boot straight into XFCE as `jaa` ---
if [ "${JAA_EDITION:-lite}" = desktop ]; then
	# Auto-login cannot handle the forced first-login password change the console edition uses,
	# so the live desktop keeps the well-known password `jaa` (for sudo) without forcing a change.
	# Acceptable for a live session only: SSH takes keys only, and nothing is kept after reboot.
	# The installer always asks for real credentials.
	chage -d "$(date -u -d "@${SOURCE_DATE_EPOCH:-0}" +%F)" jaa
	install -d /etc/lightdm/lightdm.conf.d
	cat > /etc/lightdm/lightdm.conf.d/50-jaa-live.conf <<'EOF'
# jaaOS live desktop: log in automatically (installed systems show the normal login screen).
[Seat:*]
autologin-user=jaa
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
EOF
	cat > /usr/share/applications/jaa-install.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Install jaaOS
Comment=Install jaaOS to a disk (asks: Kubernetes master / worker / none)
Exec=xfce4-terminal --title="Install jaaOS" --hold -x sudo jaa-install
Icon=system-software-install
Categories=System;
EOF
	cat > /usr/share/applications/jaa-keys.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=jaaOS keyboard shortcuts
Comment=Shell shortcuts cheat sheet (Tab, Ctrl+R, Alt+S = sudo, ...)
Exec=xfce4-terminal --title="jaaOS shortcuts" --geometry=82x34 --hold -x jaa-keys
Icon=input-keyboard
Categories=System;Utility;
EOF
	install -d -o jaa -g jaa /home/jaa/Desktop
	for f in jaa-install jaa-keys xfce4-terminal firefox-esr; do
		[ -f "/usr/share/applications/$f.desktop" ] || continue
		install -m 0755 -o jaa -g jaa "/usr/share/applications/$f.desktop" "/home/jaa/Desktop/$f.desktop"
	done
	systemctl enable lightdm.service >/dev/null 2>&1 || true
	systemctl set-default graphical.target >/dev/null
fi

# --- initramfs: zstd-compressed, rebuilt so it definitely contains the live-boot hooks ---
sed -i 's/^COMPRESS=.*/COMPRESS=zstd/' /etc/initramfs-tools/initramfs.conf
update-initramfs -u -k all

# --- drop caches and logs that only add size ---
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/cache/debconf/*-old \
	/var/log/*.log /var/log/apt/* /tmp/* /root/.bash_history

echo "20-live.sh: done"
