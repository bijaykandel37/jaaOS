#!/usr/bin/env bash
# Runs INSIDE the rootfs chroot during mkrootfs (via mmdebstrap --customize-hook).
# Static, device-independent system configuration only. Anything that needs the real
# block device (crypttab/fstab UUIDs, bootloader, UKI, snapper store) happens later in
# build/mkimage.sh.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Do NOT inherit the host's locale/home environment into the chroot. In particular a
# snap-provided LOCPATH (e.g. from VS Code: /snap/code/.../usr/lib/locale) points at a path that
# does not exist inside the chroot, which makes locale-gen/update-locale fail with "invalid
# locale settings". Neutralize those; the target locale is configured explicitly below.
unset LOCPATH LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES LC_NUMERIC LC_TIME LC_COLLATE \
	LC_MONETARY LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION 2>/dev/null || true
export LANG=C.UTF-8 HOME=/root

# --- locale / time / identity ---
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "bastion" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1	localhost
127.0.1.1	bastion
::1		localhost ip6-localhost ip6-loopback
EOF

# --- default user (demo credentials; change on first login / via installer) ---
if ! id bastion >/dev/null 2>&1; then
	useradd --create-home --shell /bin/bash --groups sudo bastion
fi
echo "bastion:bastion" | chpasswd
echo "root:bastion"    | chpasswd
install -d -m 0700 -o bastion -g bastion /home/bastion/.ssh

# --- make the shipped helper executable ---
chmod 0755 /usr/local/sbin/bastion-apt-snapshot

# --- ensure btrfs + crypto bits land in the initramfs ---
for m in btrfs; do grep -qxF "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules; done

# --- AppArmor: set shipped profiles to enforce (best effort; applied at boot too) ---
if command -v aa-enforce >/dev/null 2>&1; then
	aa-enforce /etc/apparmor.d/* 2>/dev/null || true
fi

# --- services: enable what the minimal profile needs, mask what it does not ---
systemctl enable ssh nftables auditd apparmor \
	systemd-timesyncd systemd-resolved snapper-cleanup.timer >/dev/null 2>&1 || true
systemctl mask ctrl-alt-del.target >/dev/null 2>&1 || true

# resolved: point /etc/resolv.conf at the stub
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

# --- auditd: a small baseline ruleset (expanded in the monitoring phase) ---
install -d /etc/audit/rules.d
cat > /etc/audit/rules.d/10-bastion.rules <<'EOF'
-D
-b 8192
-f 1
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /var/log/auth.log -p wa -k authlog
-w /etc/ssh/sshd_config -p wa -k sshd
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -k rootcmd
EOF

echo "10-customize.sh: done"
