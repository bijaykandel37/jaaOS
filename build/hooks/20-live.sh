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

# --- fstab: the live root is live-boot's overlay, nothing to mount ---
echo "# jaaOS live: / is an overlay over the squashfs (live-boot); no static mounts." > /etc/fstab

# --- initramfs: zstd-compressed, rebuilt so it definitely contains the live-boot hooks ---
sed -i 's/^COMPRESS=.*/COMPRESS=zstd/' /etc/initramfs-tools/initramfs.conf
update-initramfs -u -k all

# --- drop caches and logs that only add size ---
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/cache/debconf/*-old \
	/var/log/*.log /var/log/apt/* /tmp/* /root/.bash_history

echo "20-live.sh: done"
