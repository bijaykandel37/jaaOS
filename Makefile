# BastionOS top-level entry points. Run `make help`.
SHELL := bash
.DEFAULT_GOAL := help

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

deps: ## Install host build/test dependencies (Debian/Ubuntu)
	sudo apt update && sudo apt install -y \
	  mmdebstrap uidmap gdisk cryptsetup-bin btrfs-progs dosfstools \
	  sbsigntool efitools openssl uuid-runtime \
	  qemu-system-x86 qemu-utils ovmf swtpm shellcheck

keys: ## Generate Secure Boot keys (idempotent)
	bash build/secureboot.sh

rootfs: ## Build the reproducible Debian rootfs tarball (out/rootfs.tar)
	bash build/mkrootfs.sh

image: ## Build the encrypted, signed, bootable image (image step needs root)
	bash build/build.sh

vm: ## Boot out/bastionos-minimal.img in QEMU (OVMF + swtpm)
	bash tests/vm/run-qemu.sh

rust: ## Build all Rust crates in release mode
	cargo build --release

rust-lint: ## clippy (deny warnings) + rustfmt check
	cargo clippy --all-targets -- -D warnings
	cargo fmt --all --check

rust-test: ## Run Rust unit tests
	cargo test

pam: ## Build the native C PAM module skeleton (needs libpam0g-dev)
	$(MAKE) -C packages/bastion-env/pam_module

lint: ## bash -n + shellcheck every shell script
	@files=$$(grep -rlE '^#!/(usr/bin/env bash|bin/sh|bin/bash)' build packages tests 2>/dev/null); \
	for f in $$files; do bash -n "$$f" && echo "bash -n ok: $$f"; done; \
	if command -v shellcheck >/dev/null; then shellcheck -S warning $$files || true; \
	else echo "(shellcheck not installed; ran bash -n only)"; fi

clean: ## Remove build outputs (out/)
	rm -rf out

.PHONY: help deps keys rootfs image vm rust rust-lint rust-test pam lint clean
