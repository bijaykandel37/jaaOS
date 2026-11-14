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

# --- initramfs: zstd-compressed, rebuilt so it definitely contains the live-boot hooks ---
sed -i 's/^COMPRESS=.*/COMPRESS=zstd/' /etc/initramfs-tools/initramfs.conf
update-initramfs -u -k all

# --- drop caches and logs that only add size ---
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/cache/debconf/*-old \
	/var/log/*.log /var/log/apt/* /tmp/* /root/.bash_history

echo "20-live.sh: done"
