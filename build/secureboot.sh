#!/usr/bin/env bash
# Generate the BastionOS Secure Boot key set (PK / KEK / db) used to sign the UKI and
# systemd-boot. Idempotent: if keys already exist it does nothing. Keys live under
# build/secureboot/keys which is .gitignored — never commit private keys.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS="$ROOT/build/secureboot/keys"
mkdir -p "$KEYS"
cd "$KEYS"

if [ -f db.key ]; then
	echo "Secure Boot keys already present in $KEYS — skipping generation."
	exit 0
fi

GUID="$(uuidgen)"
echo "$GUID" > guid

gen() { # <name> <common-name>
	openssl req -new -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
		-subj "/CN=BastionOS $2/" -keyout "$1.key" -out "$1.crt"
	openssl x509 -in "$1.crt" -outform DER -out "$1.der"
}

gen PK  "Platform Key"
gen KEK "Key Exchange Key"
gen db  "Signature Database Key"

# EFI Signature Lists for firmware/OVMF enrollment (optional; needs efitools).
if command -v cert-to-efi-sig-list >/dev/null 2>&1; then
	for k in PK KEK db; do
		cert-to-efi-sig-list -g "$GUID" "$k.crt" "$k.esl"
	done
	echo "Enrollment .esl files written (PK/KEK/db)."
else
	echo "NOTE: efitools not installed; .esl not generated."
	echo "      These are only needed to enroll keys into firmware/OVMF."
	echo "      Install with: sudo apt install efitools"
fi

chmod 600 ./*.key
echo "Secure Boot keys written to $KEYS"
echo "Keep PK.key and db.key offline/backed up. db.key signs every image."
