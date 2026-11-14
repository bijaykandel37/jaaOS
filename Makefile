# jaaOS top-level entry points. Run `make help`.
SHELL := bash
.DEFAULT_GOAL := help
FIRMWARE ?= 0

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

deps: ## Install host build/test dependencies (Debian/Ubuntu)
	sudo apt update && sudo apt install -y \
	  squashfs-tools xorriso grub-common grub-pc-bin grub-efi-amd64-bin mtools \
	  mmdebstrap uidmap debian-archive-keyring gdisk cryptsetup-bin btrfs-progs dosfstools \
	  sbsigntool efitools openssl uuid-runtime \
	  qemu-system-x86 qemu-utils ovmf swtpm shellcheck

keys: ## Generate Secure Boot keys (idempotent)
	bash build/secureboot.sh

keyring: ## Fetch + verify the Debian archive keyring from the pinned snapshot
	bash build/fetch-keyring.sh

rootfs: ## Build the reproducible Debian rootfs tarball (out/rootfs.tar)
	bash build/mkrootfs.sh

image: ## Build the encrypted, signed, bootable image (image step needs root)
	bash build/build.sh

vm: ## Boot out/jaaos-minimal.img in QEMU (OVMF + swtpm)
	bash tests/vm/run-qemu.sh

live: ## Build the lite live ISO out/jaaos-lite.iso (root; FIRMWARE=1 adds WiFi/GPU firmware)
	sudo FIRMWARE="$(FIRMWARE)" bash build/mklive.sh

live-test: ## Boot out/jaaos-lite.iso in QEMU (BIOS + UEFI) and wait for the login prompt
	bash tests/vm/live-iso-boot.sh

release: ## Checksums + manifest + SBOM + signature over out/ artifacts (out/dist/)
	bash build/release.sh

test: ## Run the sandboxed test suites (no root, no VM)
	@for t in hosting monitoring vapt update release system-toml cluster; do \
	  echo "== $$t =="; bash tests/vm/$$t-test.sh || exit 1; done

rust: ## Build all Rust crates in release mode
	cargo build --release

rust-lint: ## clippy (deny warnings) + rustfmt check
	cargo clippy --all-targets -- -D warnings
	cargo fmt --all --check

rust-test: ## Run Rust unit tests
	cargo test

pam: ## Build the native C PAM module skeleton (needs libpam0g-dev)
	$(MAKE) -C packages/jaa-env/pam_module

lint: ## bash -n + shellcheck every shell script
	@files=$$(grep -rlE '^#!/(usr/bin/env bash|bin/sh|bin/bash)' build packages tests installer 2>/dev/null); \
	for f in $$files; do bash -n "$$f" && echo "bash -n ok: $$f"; done; \
	if command -v shellcheck >/dev/null; then shellcheck -S warning $$files || true; \
	else echo "(shellcheck not installed; ran bash -n only)"; fi

clean: ## Remove build outputs (out/)
	rm -rf out

.PHONY: help deps keys keyring rootfs image vm live live-test release test rust rust-lint rust-test pam lint clean
