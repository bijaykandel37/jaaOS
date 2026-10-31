#!/usr/bin/env bash
# BastionOS Phase 1 acceptance checks. Copy into the running VM and run as root:
#   sudo bash checks.sh
# Exits non-zero if any check fails.
set -u
pass=0; fail=0
chk() { # <description> <command...>
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
	else printf 'FAIL  %s\n' "$desc"; fail=$((fail+1)); fi
}
grepq() { grep -q "$@"; }

echo "== BastionOS Phase 1 checks =="

# Kernel hardening
chk "lockdown = confidentiality" sh -c 'grep -q "\[confidentiality\]" /sys/kernel/security/lockdown'
chk "module signature enforced"  sh -c '[ "$(cat /sys/module/module/parameters/sig_enforce)" = "Y" ]'
chk "init_on_free active"        sh -c 'grep -q init_on_free=1 /proc/cmdline'
chk "slab_nomerge active"        sh -c 'grep -q slab_nomerge /proc/cmdline'
chk "kptr_restrict=2"            sh -c '[ "$(sysctl -n kernel.kptr_restrict)" = "2" ]'
chk "ptrace_scope=2"             sh -c '[ "$(sysctl -n kernel.yama.ptrace_scope)" = "2" ]'
chk "unprivileged_bpf disabled"  sh -c '[ "$(sysctl -n kernel.unprivileged_bpf_disabled)" = "1" ]'

# MAC
chk "AppArmor enabled"           sh -c '[ "$(cat /sys/module/apparmor/parameters/enabled)" = "Y" ]'
chk "AppArmor profiles loaded"   sh -c 'aa-status --enabled && [ "$(aa-status --profiled)" -gt 0 ]'

# Storage / crypto
chk "root is Btrfs"              sh -c '[ "$(findmnt -no FSTYPE /)" = "btrfs" ]'
chk "root is on LUKS2"           sh -c 'cryptsetup status bastion_root | grep -qi "type:.*LUKS2"'
chk "LUKS uses argon2id"         sh -c 'cryptsetup luksDump "$(findmnt -no SOURCE / | sed "s#/dev/mapper/##;s#^#/dev/disk/by-uuid/#" 2>/dev/null; true)" 2>/dev/null | grep -qi argon2id || cryptsetup luksDump "$(blkid -t TYPE=crypto_LUKS -o device | head -n1)" | grep -qi argon2id'
chk "/tmp is tmpfs"              sh -c '[ "$(findmnt -no FSTYPE /tmp)" = "tmpfs" ]'
chk "/var/tmp is tmpfs"          sh -c '[ "$(findmnt -no FSTYPE /var/tmp)" = "tmpfs" ]'
chk "swap is zram (no disk swap)" sh -c 'swapon --show=NAME --noheadings | grep -q zram && ! swapon --show=NAME --noheadings | grep -q /dev/mapper'

# Boot integrity
chk "booted via EFI"             sh -c '[ -d /sys/firmware/efi ]'
chk "booted a UKI (stub)"        sh -c 'bootctl status 2>/dev/null | grep -qi "bastionos-"'
# Secure Boot: only meaningful if enrolled in the VM firmware; informational if not.
if [ -d /sys/firmware/efi ]; then
	if mokutil --sb-state 2>/dev/null | grep -qi enabled || bootctl status 2>/dev/null | grep -qi "Secure Boot: enabled"; then
		chk "Secure Boot enabled" true
	else
		echo "INFO  Secure Boot not enforced in this VM (image binaries are still signed)."
	fi
fi

# Snapshots
chk "snapper root config"        sh -c 'snapper -c root list'
chk "snapshot create works"      sh -c 'snapper -c root create -d checks-$$ && snapper -c root list | grep -q checks'

# Firewall / SSH
chk "nftables default-drop in"   sh -c 'nft list chain inet filter input | grep -q "policy drop"'
chk "SSH password auth off"      sh -c 'sshd -T 2>/dev/null | grep -qi "^passwordauthentication no"'
chk "SSH root login off"         sh -c 'sshd -T 2>/dev/null | grep -qi "^permitrootlogin no"'

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
