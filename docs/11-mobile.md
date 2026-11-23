# jaaOS Mobile — a de-Googled Samsung phone with two PINs and two workspaces

Goal: keep everything that makes the phone a smartphone (all cameras and camera modes, calls,
SMS, sensors, NFC, fingerprint), remove Google's and Samsung's background apps, and have **two
unlock secrets that open two separate workspaces**.

Status: **Path A is code + sandbox-tested** (`tests/vm/mobile-debloat-test.sh`, against a fake
`adb`; not yet run on a real phone). **Path B is a documented design and an overlay file**; no
ROM has been built or booted.

## First: what is and is not possible on a Samsung phone

| Fact | Consequence |
|---|---|
| Samsung's camera app and its image processing (night mode, zoom fusion, portrait, Expert RAW…) are proprietary and exist only in Samsung firmware | **Every custom ROM loses camera features and quality.** "All camera features" therefore means staying on Samsung firmware (path A). |
| A custom ROM needs an unlocked bootloader. US/Canada models never allow it, and since One UI 8 (2025) Samsung has removed bootloader unlocking from many models worldwide | Run `jaa-debloat check`: if "OEM unlocking allowed" is not "yes", path B is impossible on your phone. |
| Unlocking trips the **Knox e-fuse permanently** | Samsung Wallet/Pay, Secure Folder, Samsung Pass and some banking apps stop working for good, even if you go back to stock. |
| Building Android needs ~300 GB disk, 32–64 GB RAM and the phone's exact codename | It cannot be built inside the jaaOS build container; it needs a big machine and the model number. |

That gives two paths.

**Galaxy A71 (SM-A715F) owners:** the complete procedure is [`12-mobile-build.md`](12-mobile-build.md). your phone *can* take path B. It has an official LineageOS 23.2
(Android 16) build, while Samsung's own updates stopped at Android 13. Read
[`mobile/devices/a71.md`](../mobile/devices/a71.md) for the stay-or-switch comparison (VoLTE,
camera, banking apps, Knox) and the exact steps. `jaa-debloat rom-check` verifies the phone is
ready (model, Android 13 firmware, OEM unlocking, no Google account, battery) without changing
anything.

## Path A (recommended): stock Samsung firmware, de-Googled with `jaa-debloat`

Keeps **every camera feature**, Knox, updates from Samsung and Secure Folder. Nothing is
unlocked, nothing is rooted, and everything is reversible (a factory reset also restores all).

1. On the phone: Settings > About phone > Software information > tap **Build number** 7 times.
   Then Settings > **Developer options** > **USB debugging** on.
2. Connect the phone by USB to a Linux computer (jaaOS works), and tap **Allow** on the phone.
3. Install adb and look at the phone:

   ```bash
   sudo apt install adb
   ```

   ```bash
   mobile/debloat/jaa-debloat check
   ```

4. See what would go (nothing changes yet), then remove it:

   ```bash
   mobile/debloat/jaa-debloat plan --tier standard
   ```

   ```bash
   mobile/debloat/jaa-debloat apply --tier standard
   ```

5. Changed your mind?

   ```bash
   mobile/debloat/jaa-debloat restore --all
   ```

The tiers are in `mobile/debloat/lists/*.txt`. Each line says what you lose.

| Tier | Removes | You lose |
|---|---|---|
| `safe` | Facebook/Netflix/OneDrive preinstalls, Samsung Free, Tips, TV Plus, Game Launcher, Google TV/Meet/YT Music… | nothing you would miss |
| `standard` | + YouTube, Maps, Gmail, Drive, Photos, Chrome, Google app/Assistant, Bixby, AR Zone, Samsung Members… | those apps (use Samsung Internet/Gallery/Email, or F-Droid apps) |
| `aggressive` | + **Google Play Services, Play Store**, Google sync, ARCore, AR Emoji, Quick Share | push notifications in many apps, Google sign-in, Google Pay, Play updates, some AR camera modes |

**Never removed** (`lists/protected.txt`, enforced even if a list names them): the camera (`*camera*`),
dialer and calls, SMS, system UI, settings, keyboard, biometrics, Knox and Secure Folder, WebView,
gallery, files, Samsung Internet, Find My Mobile.

Before `aggressive`, install **F-Droid** (open-source app store) and, if you need Play apps,
**Aurora Store**. Keep Galaxy Store for Samsung updates.

How it works: `pm uninstall -k --user 0 <app>` removes the app for the phone's owner and stops
it from running. The original stays in the read-only system partition, which is why it is
reversible and why it cannot brick the phone.

## Two PINs, two workspaces

### On path A: Secure Folder (works today)

Samsung's **Secure Folder** is a second workspace with its **own PIN, pattern or password** (and
its own fingerprint option), its own copies of apps (**camera included**: photos taken inside
stay inside), and its own encryption key from the Knox hardware.

- Set it up: Settings > Security and privacy > More security settings > **Secure Folder**.
  Choose a different PIN/pattern from the lock screen one.
- Unlock the phone with **PIN 1** and you are in workspace 1. Open Secure Folder (icon or
  quick-settings tile), enter **PIN 2**, and you are in workspace 2.
- To make it less obvious: Secure Folder settings > turn off **"Add Secure Folder to Apps
  screen"**, then open it from the quick-settings tile.
- Check it from the computer: `mobile/debloat/jaa-debloat workspace`.

### On path B: two Android users, each with its own PIN

On a custom ROM, the overlay `mobile/rom/overlay/.../config.xml` enables multiple users on the
phone. Each user has its own lock-screen PIN/pattern and its own file-based-encryption key. At the
lock screen you tap the user icon, pick the workspace, and enter that workspace's PIN.

A single PIN field that silently decides the workspace from the PIN you type (PIN 1 → workspace 1,
PIN 2 → workspace 2) needs a change to Android's lock screen (SystemUI/LockSettingsService). The
change: when the PIN fails for the current user, check it against the other user and switch on a
match. That is **designed here but not implemented**: it touches the credential path, so it must
keep Android's per-user attempt throttling and must not leak the second user through timing. Per
the jaaOS rules for security-critical code, it would ship with a "prototype / unaudited" banner.

### What the two workspaces protect, and what they do not (read this)

The same honesty rules apply as for jaaOS's desktop dual environment (`docs/01-threat-model.md`):

- **Protects the contents** of each workspace while the phone is off or the workspace is locked.
  Each has its own key (Knox container key / per-user file-encryption key). This is strong.
- **Hides the second workspace only from casual inspection.** With the icon hidden, someone
  scrolling through your apps will not see it.
- It does **not** hide that a second workspace exists from anyone who looks. Secure Folder and
  extra users show up in Settings, and a forensic tool sees them immediately.
- It does **not** protect against malware with system/root access, or against a phone that was
  compromised while a workspace was unlocked.
- It is **no defence against being forced** to unlock it.

## Path B: custom ROM (only if `check` says OEM unlocking is allowed)

Base: **LineageOS** (open source, no Google apps by default). /e/OS is a de-Googled LineageOS
derivative if you want the work done for you. GrapheneOS and CalyxOS do not support Samsung.

1. Check that your exact model is on the LineageOS devices list
   (https://wiki.lineageos.org/devices/). If it is not, path B is not realistic.
2. Back up everything. Unlocking wipes the phone and trips Knox permanently (see the table above).
3. Follow that device's LineageOS install guide (it uses Odin/Heimdall + a custom recovery;
   Debian packages the Linux flasher as `heimdall-flash`).
4. To build a jaaOS-flavoured image instead of the official one: build LineageOS for the device
   (LineageOS "Build for <device>" guide, a 300 GB / 32 GB RAM machine), adding
   `mobile/rom/overlay` as a product overlay.

What you get: no Google, full control, multi-user workspaces. What you lose: Samsung's camera
processing (LineageOS's camera works, with fewer modes and less image quality), Knox features,
Samsung updates.

## Files

- `mobile/debloat/jaa-debloat` — the debloater (bash spec; host-side tool that drives `adb`).
- `mobile/debloat/lists/{google,samsung,thirdparty}.txt` — what to remove, by tier;
  `protected.txt` — never removed.
- `mobile/rom/overlay/` — custom-ROM overlay enabling multi-user workspaces (not built).
- `mobile/devices/supported.txt` + `mobile/devices/a71.md` — documented LineageOS phones (data
  for `rom-check`) and the Galaxy A71 guide.
- `tests/vm/mobile-debloat-test.sh` — sandbox test with a fake `adb` (in `make test`).

## Limits (honest)

- `jaa-debloat` has only run against a fake `adb`, not a real phone yet. Package names come from
  common Samsung builds; some may not exist on yours (they are simply skipped).
- Samsung firmware updates can reinstall removed apps; run `apply` again after a big update.
- Path B: nothing has been built or flashed. It depends entirely on your model being unlockable
  and supported.
