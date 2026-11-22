# jaaOS Mobile — build, verify and install it on a Galaxy A71

This is the complete procedure, from an empty computer to a working jaaOS Mobile phone, plus what
was actually tested and what this phone cannot do. Device: **Samsung Galaxy A71, SM-A715F**
(also /DS, /DSN, /DSM). Never use these files on the A71 5G (SM-A716*).

## What jaaOS Mobile is

**Official LineageOS 23.2 (Android 16)** for the A71, plus a **jaaOS layer** that `jaa-mobile`
installs over USB:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ jaaOS layer (mobile/jaa-mobile, mobile/apps.lock, mobile/termux/)              │
│  F-Droid + Aurora Store (Play Store apps) · optional microG · Termux toolkit   │
│  FMD remote wipe · Wasted panic wipe · ntfy alerts · NetGuard · Aegis · KeePass │
│  audit logs · low-bandwidth mode · XFCE desktop over VNC · speed defaults       │
├──────────────────────────────────────────────────────────────────────────────┤
│ LineageOS 23.2 (Android 16), official A71 build, signed by LineageOS            │
│  no Google · file-based encryption · SELinux · per-app sandbox · weekly updates │
├──────────────────────────────────────────────────────────────────────────────┤
│ Samsung firmware (modem, bootloader, closed drivers) — Android 13, 2024-02-01  │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Why the official image, rather than a jaaOS image compiled from source:** it's the same rule as
jaaOS on the desktop (*inherit upstream security maintenance*). LineageOS publishes a signed,
device-tested A71 build every week, and the phone's Updater installs it. A self-compiled image
would need its own signing keys, a 400 GB / 64 GB RAM build machine every week, and nobody
testing it on hardware. Everything jaaOS adds is installed *on top*, so it survives updates. If
you still want to compile it yourself, see Appendix A.

## Your requirements, honestly mapped to this phone

| You asked for | On the A71 with jaaOS Mobile | Status |
|---|---|---|
| Lightweight, fast | LineageOS without any Google/Samsung apps (about 100 system components), zram, animations at 0.5x | done. Speed can only be measured on the phone itself |
| Apps from APK | any APK (file manager, or `jaa-mobile install-apk`) | done |
| Play Store apps | **Aurora Store** (Play Store catalogue, no Google account) + optional **microG** for push notifications | done. Apps that demand Play Integrity (some banks) refuse to run |
| No Google services by default | `pure` flavour: zero Google code (verified: 0 Google apps in the image) | done |
| Full-disk encryption | **file-based encryption** of `/data` with AES-256-XTS v2, hardware inline crypto, per-user keys | done. File contents and names are encrypted; file-system metadata (sizes, times) is not |
| Strong app sandboxing | Android per-app UID sandbox + SELinux (built into the kernel) | done (stock Android mechanism) |
| **Verified boot** | **not possible on this phone**: the A71 bootloader cannot be relocked with LineageOS, and the image disables AVB (vbmeta flags = 3) | ✗. Only phones that can relock with custom keys (mainly Pixels with GrapheneOS/CalyxOS) can do this |
| Two PINs → two workspaces | **Private space** (own PIN/pattern, hidden while locked) or a **second user** (own lock + own encryption key; the build allows 4 users) | done. Hidden from casual inspection only (see limits) |
| Audit log of every command | Termux shell: every command line, exit code and directory, hash-chained (`jaa-audit verify`). Computer: every `adb` command `jaa-mobile` runs | done. Tamper-*evident*, not tamper-proof (no root) |
| Remote wipe | **FMD** (remote locate/lock/wipe by SMS or FMD server) + **Wasted** (panic wipe trigger) | done (you activate device admin on the phone) |
| DevOps + security toolkit | Termux with 89 verified packages + Ansible: kubectl, helm, k9s, gh, git, aws/doctl CLIs, Go/Rust/Python/Node/Java, Postgres/MariaDB/Redis clients, nmap, dig, mtr, iperf3, socat, Tor, radare2/rizin, binwalk, gdb, termshark (+ PCAPdroid captures) | done. Assessment tools only: no exploit frameworks or brute-forcers (jaaOS policy) |
| Desktop over USB-C to a monitor | **not possible on this phone**: the A71 kernel has **no DisplayPort driver** (checked in its build config) and its USB-C port carries no video | ✗. Substitute: XFCE Linux desktop over VNC (`jaa-desktop`), on the phone with a Bluetooth keyboard/mouse, or on any PC/TV through an SSH tunnel |
| Low-bandwidth mode | `jaa-mobile lowbw on`: Data Saver blocks background data for every app except Termux (SSH), ConnectBot, ntfy (alerts) and FMD (wipe) | done, on mobile data. For Wi-Fi too, block apps in NetGuard |

## Before you start

- A Linux computer (jaaOS desktop works) with about 3 GB free, a USB cable, and these tools:

  ```bash
  sudo apt install adb python3 openssl curl unzip default-jre-headless
  ```

  `apksigner` (for checking app signatures) is in Google's Android build-tools. Download
  `build-tools_r37_linux.zip` from https://dl.google.com/android/repository/build-tools_r37_linux.zip
  and unzip it. Then:

  ```bash
  export APKSIGNER="$HOME/android-37.0/apksigner"
  ```

- The phone: **back up everything** (photos, contacts, 2FA codes). Installing LineageOS wipes it.
- Knox: unlocking the bootloader **trips Knox permanently** (Samsung Pass/Wallet and Secure Folder
  stop working forever). Calls: LineageOS has **no VoLTE / Wi-Fi calling** on this phone, so calls
  need your carrier's 2G/3G network. Check that it still exists.

## Step 1 — Get the image and verify it (on the computer)

```bash
mobile/jaa-mobile fetch-image a71
```

It downloads the newest official build and its published SHA-256 hashes from
download.lineageos.org, then runs `verify-image`:

```
PASS  all files match SHA256SUMS
PASS  signed by the LineageOS release key (whole-file signature verified)
NOTE  vbmeta flags=3: Android Verified Boot is disabled for this device (its bootloader cannot be relocked).
```

The signature check is the same one the phone's recovery makes, against LineageOS's public key
(`mobile/keys/lineageos_pubkey`). **Do not continue if any line says FAIL.**

## Step 2 — Prepare the phone (read-only check)

On the phone: Settings > About phone > Software information > tap **Build number** 7 times;
Developer options > **USB debugging** and **OEM unlocking** on. Remove all Google accounts.

```bash
mobile/debloat/jaa-debloat rom-check
```

It must print `READY`: right model, stock **Android 13** firmware (LineageOS requires it), OEM
unlocking allowed, no Google account (factory reset protection), battery ≥ 50%.

## Step 3 — Install LineageOS (manual, from the official guide)

Follow `mobile/devices/a71.md` §"Path B" (it mirrors https://wiki.lineageos.org/devices/a71/install/):
unlock the bootloader, flash `vbmeta.img` and `recovery.img` with samloader-rs, format data,
and sideload the zip. **Do not install Google Apps** when the recovery offers add-ons. Boot,
finish the setup wizard, and enable USB debugging again.

## Step 4 — Install the jaaOS layer

```bash
mobile/jaa-mobile fetch-apps
```

```bash
mobile/jaa-mobile setup
```

`fetch-apps` downloads the apps pinned in `mobile/apps.lock` from F-Droid and microG and refuses
any file whose SHA-256 **or** signing certificate differs from the pin. `setup` checks the phone
runs LineageOS, installs the apps, sets animations to 0.5x, and copies the toolkit script to the
phone's Downloads.

With push notifications through microG (recommended if you use Play Store messengers), use
`--flavor microg` on both commands, then on the phone: microG Settings > **Self-Check** (grant
everything) > **Cloud Messaging** on. Without microG (`pure`), there is no Google code at all.

**Play Store apps:** open **Aurora Store**, choose *anonymous*, and search and install as in Play.
**Any APK:** open it in Files, or:

```bash
mobile/jaa-mobile install-apk ~/Downloads/app.apk
```

## Step 5 — DevOps + security toolkit (on the phone, in Termux)

```bash
termux-setup-storage
```

```bash
bash ~/storage/downloads/jaa-devsec-setup.sh --desktop
```

This installs the toolkit (`mobile/termux/jaa-devsec-setup.sh` lists every package), turns on SSH
(port 8022, **keys only**: put your public key in `~/.ssh/authorized_keys`), and adds the commands
below. Leave out `--desktop` if you don't want the Linux desktop.

| Command | What it does |
|---|---|
| `jaa-audit verify` | checks the command log's hash chain (shows the first edited/removed line) |
| `jaa-audit ship user@host:logs/` | copies the log off the phone over SSH |
| `jaa-alert "text"` | phone notification; also pushes to ntfy when `JAA_NTFY_URL` is set |
| `jaa-desktop start` | XFCE desktop on `127.0.0.1:5901`; open it in **AVNC** (run `vncpasswd` once first) |

Desktop on a big screen: pair a Bluetooth keyboard and mouse and use AVNC on the phone, or
from a computer on the same network:

```bash
ssh -p 8022 -L 5901:127.0.0.1:5901 192.168.1.50
```

then point a VNC viewer at `localhost:5901` (replace 192.168.1.50 with the phone's IP).

## Step 6 — Two PINs, two workspaces

- **Private space** (lightest): Settings > Security & privacy > **Private space**. It gets its own
  PIN/pattern, its apps disappear while it is locked, and it can be hidden.
- **Second user** (strongest separation): Settings > System > **Multiple users** > add a user, then
  switch to it and set its own PIN. It has its own encryption key. (The official A71 build enables
  this: up to 4 users, checked in its framework overlay.)

```bash
mobile/jaa-mobile workspace
```

Limits (same as jaaOS's desktop dual environment): each workspace's **contents** are strongly
protected while locked. The second workspace is hidden only from **casual** inspection: it shows
in Settings and to forensic tools. It is **no** defence against malware with system access, or
against being forced to unlock it.

## Step 7 — Remote wipe

1. Open **FMD**: grant it device-admin and SMS permissions, set an FMD **PIN**, and add your
   trusted phone numbers (or connect it to an FMD server). FMD shows the exact SMS commands for
   locate / lock / delete. *Delete* needs the PIN.
2. Optional: **Wasted**, a panic trigger (e.g. a quick-settings tile or notification action) that
   locks or wipes immediately.

A wipe only happens while the phone is on and reachable. If it's off, your data is still
protected by encryption (Step 6 and the table above).

## Step 8 — Low-bandwidth mode

```bash
mobile/jaa-mobile lowbw on
```

```bash
mobile/jaa-mobile lowbw off
```

`on` turns on Android's **Data Saver** and allowlists only Termux (SSH), ConnectBot, ntfy and FMD.
Every other app loses background data on mobile networks. For a hard block (also on Wi-Fi and in
the foreground), set NetGuard to block all apps except those four.

## Step 9 — Updates

- **LineageOS:** Settings > System > Updater (weekly, signed by LineageOS). The jaaOS layer stays.
- **Apps:** F-Droid and Aurora Store update themselves.
- **Toolkit:** in Termux, run `pkg upgrade`.
- To move the pins forward on the computer, run `mobile/tools/update-apps-lock` and review
  `git diff mobile/apps.lock`.

## Test results

Run in the jaaOS build container on 2026-11-22. There was no phone and no KVM, so no Android
emulator. These are the **real files**, checked with real tools:

| Test | Result |
|---|---|
| A71 build `lineage-23.2-20261118-nightly-a71-signed.zip` + 6 images: SHA-256 vs download.lineageos.org | all 7 OK |
| Whole-file OTA signature vs LineageOS's published key (`jaa-mobile verify-image`) | PASS. **One changed byte → FAIL** |
| Inside the image (unpacked, mounted read-only) | Android 16, security patch 2026-11-01, `release-keys`; **0 Google apps** (only a Google Sans font overlay); Aperture camera, Updater, Seedvault, PrivateSpace present |
| Encryption (vendor fstab) | `/data` `fileencryption=aes-256-xts:aes-256-cts:v2`, `inlinecrypt`; no metadata encryption |
| Multi-user (framework + A71 overlay) | `config_multiuserMaximumUsers=4`, `config_enableMultiUserUI=true` |
| Kernel config (from boot.img) | SELinux, dm-verity, inline FS encryption, zram: built in. **No DisplayPort driver** |
| Verified boot (vbmeta) | flags = 3: AVB **disabled** |
| 17 pinned apps (`jaa-mobile fetch-apps --flavor microg`) | all OK: SHA-256 + signing certificate via `apksigner`. microG pinned to its repository key; a wrong pin is refused |
| 89 Termux toolkit packages | all present in the Termux aarch64 index |
| `tests/vm/mobile-tools-test.sh` (fake adb/pkg, real bash) | 42 checks: setup flavours and order, refusals, low-bandwidth on/off, both audit logs (incl. tamper detection), toolkit install, SSH keys-only, localhost-only VNC |
| `tests/vm/mobile-debloat-test.sh` | 40 checks (stock path and rom-check) |

**Not tested here** (it needs the phone): flashing, first boot, calls, camera quality, battery
and speed, FMD/Wasted wipes, and the Termux toolkit running on Android.

## Appendix A — compiling the image yourself (optional)

Only needed if you want your own build or signing keys. LineageOS's guide asks for **400 GB of
storage and 64 GB RAM** for lineage-21 and newer (less RAM works, but slowly), and several hours. The commands, from the LineageOS "Build for a71"
guide (https://wiki.lineageos.org/devices/a71/build/):

```bash
mkdir -p ~/android/lineage && cd ~/android/lineage
```

```bash
repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs --no-clone-bundle
```

```bash
repo sync -j8
```

```bash
source build/envsetup.sh && breakfast a71
```

The build also needs the A71's proprietary Samsung files, which you extract from a phone already
running LineageOS: in `device/samsung/a71`, run `./extract-files.py` (or `./extract-files.sh` if
that is what the directory contains; see that guide). Then:

```bash
croot && brunch a71
```

The result appears in `out/target/product/a71/` (named like `lineage-23.2-<date>-UNOFFICIAL-a71.zip`). You then sign it with your own keys and install
it like Step 3. **None of Appendix A was run in this project.** The jaaOS layer is the same
either way (Steps 4–9).
