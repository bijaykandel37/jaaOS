# BastionOS — Phase 2: Dual-password environments (design + prototype)

Status: **design complete; prototype written and syntax-checked; not yet run end-to-end**
(the crypto/PAM/mount flow needs a root VM — see Test plan and Known limitations). This is
the most safety-critical component in BastionOS, so read §1 and §9 before trusting it.

> **One-line truth, repeated from the threat model:** this feature isolates two homes' *contents*
> strongly at rest and hides the second environment from *opportunistic* inspection. It does
> **not** reliably hide that a second environment exists from a competent forensic examiner, from
> anyone who knows you run BastionOS, or from malware that got root — and it is no defense against
> legal compulsion.

---

## 1. What is being built, precisely

- One Unix user, one UID, one `/home/<user>` mount point. System directories are shared.
- Two (or more) separately-encrypted home volumes, each opened by a **different password**.
- At login, the entered password decides which volume mounts at `/home/<user>`.
- Only **one** environment is ever active per machine at a time (one UID, one mount point).
- `/etc/shadow` stores **no password hash** for the user, so it cannot reveal that one — let
  alone two — passwords exist.
- Authentication takes the **same wall-clock time** whichever password matched, or none did.

This gives strong *confidentiality isolation*. It *attempts* deniability of the second
environment's existence, whose real limits are stated honestly in §9.

---

## 2. Storage mechanism — evaluation and decision

| Option | Hides B's *existence* from a forensic image? | Hides B from root while A is unlocked? | Maturity | Verdict |
|---|---|---|---|---|
| (a) Two LUKS2 containers | **No** — two `LUKS\xba\xbe` headers are plainly visible | B not mounted (contents safe), but two headers reveal two volumes | Rock solid | **Fallback / "isolation" mode** |
| (b) systemd-homed | **No** — `homectl list`, `*.home` images, user records are explicit | No | Solid | **Rejected**: fully enumerable; also fights one-UID/two-homes |
| (c) fscrypt | **No** — encrypted dir, filenames, policy, sizes, timestamps all visible | No | Solid | **Rejected**: metadata leaks existence completely |
| (d) **Shufflecake** | **Partially** — whole device looks random; number of hidden volumes is itself hidden | Contents safe (not mapped); existence only *inferable* | **Beta / research** | **Recommended for deniability**, with the maturity caveat |
| (e) VeraCrypt hidden volume | Partially (single hidden volume) | Contents safe; existence inferable | Mature, but awkward as a Linux *home*, single volume, overwrite hazard | Strong model, poor fit as system home |

### Decision: a **storage-provider abstraction**, defaulting honestly

No single mechanism is both maximally deniable *and* solid enough to be the only code path a
solo maintainer trusts in the boot/home path. So the PAM/mount/switch machinery is
**storage-agnostic**, talking to a provider that implements one contract (§4). Two providers:

- **`luks2`** (default, reliable): two LUKS2 containers with *identical* Argon2id parameters.
  Gives strong isolation and confidentiality. **Deniability of existence: weak** (two headers
  are detectable — the forensic test in §8 demonstrates exactly this). Appropriate when you have
  re-read the threat model and decided isolation is what you need.
- **`shufflecake`** (opt-in, for deniability): drives the upstream Shufflecake tool. Gives
  existence-hiding as far as any Linux scheme does. **Beta** — we isolate the dependency behind
  the provider interface and ship per-environment backups so a Shufflecake failure cannot lose
  the only copy.

Because you chose *deniability required*, the installer offers `shufflecake` and shows the
`luks2` honesty note; the design below is written so switching the provider changes nothing in
the auth/session/leakage layers.

**Honest answer to the two questions the brief demands:**
- *Can B's existence be hidden from root while A is unlocked?* **No, not reliably.** Root in A
  can read the BastionOS tooling and PAM config (which announce the feature exists), inspect the
  raw device, and — worst — install persistence that captures B's password the next time it is
  typed. What is protected is B's **contents** (B is not mapped and its key is not in memory).
- *Can B's existence be hidden from a forensic disk image?* **Contents: yes** (crypto). **Existence:
  no, not against a competent examiner** — the presence of deniable-storage software, free-space
  statistics, and container/free-space timestamps all signal a probable hidden volume. Deniable
  only against non-expert/opportunistic examination.

---

## 3. `/etc/shadow` handling

The user's shadow password field is set to `!` (locked) — **no hash at all**. Consequences:

- A stolen `/etc/shadow` reveals *zero* passwords. It cannot show that two exist, because it
  shows none, and a locked field is completely ordinary (service accounts use it), so it is not
  itself a tell.
- All authentication for the user flows through the BastionOS PAM entry (§4), which succeeds iff
  the entered password decrypts one of the volumes. `pam_unix` for this user always fails
  (locked), so it never contributes a decision and never needs a stored secret.
- Fail-closed: if the BastionOS PAM entry is removed or the volumes are gone, the account simply
  cannot authenticate — it never silently falls back to a weaker method.

The volume passwords live **only** in their LUKS/Shufflecake key material on the encrypted
device, never in any system database.

---

## 4. Authentication and session architecture

### 4.1 Why `pam_exec` + a helper, not (yet) a custom `.so`

A buggy custom PAM module is an auth bypass or a lockout. Following the Phase-0 rule *prefer
proven components*, the **running prototype uses the audited, upstream `pam_exec.so`** to invoke
a helper, `bastion-env-pam`. A native module (`pam_bastion_env.c`, in
`packages/bastion-env/pam_module/`) is provided as a compilable skeleton for the eventual native
integration **after security review** — it is not the trusted path yet, and is clearly banner-marked.

### 4.2 The provider contract (`packages/bastion-env/providers/<name>`)

Each provider is an executable implementing these verbs (password, when needed, on **stdin**):

```
init                 # create the primary (decoy) environment "A"
add                  # create an additional hidden environment
try-unlock           # stdin: password. Attempt to OPEN the matching env (constant time over
                     #   ALL envs). On success: print the opened mapper name, record nothing.
                     #   Exactly one env may match a given password; none => exit 1.
verify-active        # stdin: password. Test ONLY the currently-active env's key (re-auth).
mount <mapper>       # mount an opened mapper at /home/<user>
unmount              # unmount /home/<user>, close the mapper, wipe keys
active               # print the active env tag, or nothing
```

Constant-time rule: `try-unlock` **always runs the KDF for every environment** (opens all,
keeps the one that matched, immediately closes any stray match), so wall-clock time is identical
whether the 1st, 2nd, or no container matched. All containers share identical Argon2id parameters.

### 4.3 PAM flow (driven by `PAM_TYPE` from `pam_exec`)

```
auth:
    read password from stdin
    if an environment is already active on this machine:        # sudo / su / polkit / screen-unlock
        verify-active(password)      -> success/fail            # NEVER opens or switches envs;
                                                                #  B's password while A active => fail,
                                                                #  with no hint that B exists
    else:                                                       # fresh login: DM / TTY / SSH-kbd
        try-unlock(password) -> opened mapper or fail
        record {env, mapper} in /run/bastion-env/<uid> (tmpfs, 0600)

open_session:
    mount the recorded mapper at /home/<user>  (+ pam_namespace gives private /tmp, /var/tmp)

close_session:
    unmount, cryptsetup close, shred /run state, revoke session keyring
```

### 4.4 Consistency across every entry point

| Entry point | PAM service | Behaviour |
|---|---|---|
| Display manager (GDM) login | `gdm-password` | Fresh login → `try-unlock` selects the env |
| TTY login | `login` | Fresh login → `try-unlock` |
| SSH, keyboard-interactive | `sshd` | Fresh login → `try-unlock` (type the env password) |
| SSH, public-key | `sshd` (no authtok) | **Joins the already-active env**; if none is active there is **no home to mount** — see §4.5 |
| sudo | `sudo` | Re-auth → `verify-active` only |
| su | `su` / `su-l` | Re-auth → `verify-active` only |
| polkit | `polkit-1` | Re-auth → `verify-active` only |
| Screen lock (GNOME) | `gdm-password` (unlock) | Re-auth → `verify-active` only |
| Remote desktop (RDP/VNC) | its PAM service (e.g. `xrdp-sesman`) | Treated as a fresh login → `try-unlock` |

The "already active?" test is what makes a re-auth safe: once env A is live, only A's password
works anywhere, and presenting B's password merely fails like any wrong password.

### 4.5 SSH key-based login — which environment?

Public-key SSH carries no password, so it **cannot select or unlock** an environment. Rule:

- If an environment is already active (someone unlocked at the console/DM), key-based SSH
  **joins that environment** (its home is already mounted).
- If no environment is active, a key-based SSH session has **no home mounted** (login lands in a
  minimal shell with `$HOME=/var/empty` or is refused per policy). To bring an environment up
  remotely, use keyboard-interactive SSH and type the environment's password.

This is a deliberate, documented limitation: remote unlock of a specific environment requires the
password, never just a key.

---

## 5. Switching and concurrency

- **Switch = full logout.** `close_session` unmounts, `cryptsetup close`, shreds `/run` state,
  and revokes the session keyring **before** any other environment can be unlocked. Only when no
  environment is active does `try-unlock` run again.
- **Serialization.** All state transitions take an exclusive `flock` on
  `/run/bastion-env/lock`, so concurrent logins cannot race the mount.
- **Concurrent logins.** Because there is one UID and one `/home/<user>`, only one environment is
  active machine-wide. A second concurrent login must `verify-active` against the live env; the
  live env's password → it shares the session's env; the other env's password → it fails (and
  reveals nothing). You cannot have A and B mounted at once.

---

## 6. Recovery and backups — per environment, without revealing the other

- **Recovery keys:** each LUKS volume gets a second keyslot holding a recovery key (`bastion-env
  recover-key add` operates only on the active env). The decoy's recovery key can be disclosed
  under coercion; the hidden env's is kept off-device. In Shufflecake mode, recovery is a second
  password at that volume's level.
- **Backups:** `bastion-env backup` operates **only on the active environment**, writing to that
  environment's own encrypted repo (borg/restic with a per-env passphrase). Backing up B creates
  no artifact visible in A: the repo lives inside B's home or on removable media mounted only
  while B is active. There is intentionally **no command that enumerates all environments** — that
  would break deniability (see §7).

---

## 7. `bastion-env status` reveals nothing about the other environment

`status` prints only: whether an environment is active and, if so, *the active one's* free space
and backup age. It never prints a count, never names a non-active environment, and exits
identically whether or not a hidden environment exists. There is deliberately no `list` verb.
`add` creates a new hidden environment without ever confirming how many now exist.

---

## 8. Leakage analysis

How the architecture already forecloses leaks (Phase 1 + this phase), and the honest residuals.
"Scrubbed" = removed on logout/switch; "Isolated" = per-environment by construction.

| Surface | Shared / Isolated / Scrubbed | Mechanism | Residual risk |
|---|---|---|---|
| journald **system** log + `auth.log` | Shared | auditd/journald run as root | **We log identically regardless of env** (never record which env mounted); but *that a login happened* and its timing are visible. Medium. |
| journald **user** log (`--user`) | Shared (keyed by UID!) | same UID across envs | **Real leak**: env A's user-journal readable in B. The obvious fix (user journal `Storage=volatile`) is *not* applied by default because the only knob is system-wide and would also drop the persistent **system** audit log we need. **Documented residual**, not silently fixed. |
| `/tmp`, `/var/tmp` | **Scrubbed** | fresh per-session tmpfs via `pam_namespace`, destroyed at logout | Low. A switch is a logout, so nothing a user wrote to `/tmp` in one env survives into the other. |
| `/var/cache`, `/var/lib` (general) | Shared | system state | Low-value but activity-revealing; documented. |
| Docker (rootful) state `/var/lib/docker` | Shared | daemon writes outside home | **Leak**: images/volumes from A visible in B. Mitigation: **prefer rootless Podman** (stores in `~/.local/share/containers`, inside home ⇒ per-env). Rootful Docker discouraged for sensitive work. |
| Podman (rootless) | **Isolated** | stores inside home | Low. |
| Flatpak | Mostly isolated | per-user data in `~/.var`, `~/.local/share/flatpak` | System-installed *apps* shared (not data). Low. |
| `/run/user/<uid>` | Scrubbed | systemd removes on logout | Low. |
| swap | Scrubbed | zram, RAM-only, freed on process exit; no disk swap | Low (never hits disk). |
| hibernation | N/A | disabled (Phase 1) | None. |
| crash / core dumps | Scrubbed | `systemd-coredump` `Storage=none` (§ config); kdump off | Low. |
| package-manager logs | Shared | `/var/log/apt`,`/var/log/dpkg` | Activity-revealing, not home data. Low. |
| NetworkManager profiles | Shared | `/etc/NetworkManager/system-connections` (root) | **Leak**: Wi-Fi/VPN added in A visible in B. Per-env NM is out of scope; documented residual. Medium. |
| systemd **user** units | Isolated | `~/.config/systemd/user` inside home | Low (but their logs → see user journal). |
| cron/at | Shared | `/var/spool/cron/crontabs/<user>` keyed by name | **Leak**: a crontab set in A runs/visible in B. Mitigation: use systemd **user** timers (in home) instead; document. Medium. |
| kernel keyring | Scrubbed | session keyring revoked at logout; volume key in kernel only while mapped | Root while active can extract. Documented. |
| filesystem timestamps | Shared | container/free-space mtime changes when B is used | **Deniability leak**: a forensic image can see "free space" was written recently. Hard to fully mask. Medium–high for deniability. |
| disk-usage via monitoring | Shared | node_exporter filesystem collector | **Leak**: raw-device used-bytes includes B even when unmounted. Mitigation: collector scoped to mounted FS only + decoy sized plausibly. Residual: a careful observer can still compare. Medium. |
| thumbnail / recently-used caches | Isolated | `~/.cache`, `~/.local/share` inside home | Low. |

The clear residuals — user journal, NetworkManager, cron, filesystem timestamps, monitoring
used-bytes — are called out rather than hidden. Three (journal, coredump, /tmp) are closed by
the config drop-ins this phase ships; the rest are documented limitations.

---

## 9. Threat model (expanded from Phase 0 §T-table)

Defends: lost/stolen **powered-off** device; shoulder-surfing; opportunistic access; separating
engagements/clients from personal data. **Partial:** suspended-RAM (keys in RAM for the active
env); evil-maid (boot chain measured, hardware implant out of scope). **Does not defend:**
coerced disclosure by an adversary who knows BastionOS; legal compulsion; **malware with root in
the active env** (shared system dirs ⇒ it can lie in wait and read the other env on next unlock);
forensic proof of B's *existence*. These are properties of the problem, not bugs to be fixed
later.

---

## 10. Files in this phase

| File | Purpose |
|---|---|
| `packages/bastion-env/bin/bastion-env` | User CLI: `init`, `add`, `status`, `backup`, `lock`, `recover-key`. |
| `packages/bastion-env/bin/bastion-env-pam` | `pam_exec` helper: auth / open_session / close_session dispatch, constant-time. |
| `packages/bastion-env/providers/luks2` | Default provider (two LUKS2 containers, identical Argon2id params). |
| `packages/bastion-env/providers/shufflecake` | Opt-in deniable provider (drives upstream Shufflecake; honest guard if absent). |
| `packages/bastion-env/pam/bastion-env.pamd` | PAM snippet wiring `pam_exec` + `pam_namespace` into auth/session. |
| `packages/bastion-env/pam_module/pam_bastion_env.c` | Native PAM module **skeleton** (compilable, unaudited — not the trusted path). |
| `packages/bastion-env/pam_module/Makefile` | Builds the skeleton module. |
| `config/rootfs/etc/security/namespace.d/bastion.conf` | Polyinstantiated (per-env) `/tmp`, `/var/tmp`. |
| `config/rootfs/etc/systemd/coredump.conf.d/bastion.conf` | `Storage=none` (no core dumps to shared disk). |
| `config/rootfs/etc/bastion-env/config` | Managed-user + provider selection (installer writes it; inert until set). |
| `tests/vm/dual-env-test.sh` | Functional test: init two envs, auth with each, verify correct mount, wrong-pw fail, switch wipes, status reveals nothing, timing constant. |
| `tests/forensic/forensic-scan.sh` | Characterizes deniability of a powered-off image (detects LUKS headers in `luks2` mode; reports what Shufflecake changes). |

## 11. Build / test (copy-paste)

```bash
cd /home/bijay/Public/jaaOS

# Syntax-check the prototype (safe to run anywhere)
for f in packages/bastion-env/bin/* packages/bastion-env/providers/*; do bash -n "$f" && echo "ok $f"; done

# Build the native PAM module skeleton (optional; needs libpam dev headers)
sudo apt install -y libpam0g-dev build-essential
make -C packages/bastion-env/pam_module

# Functional + forensic tests run INSIDE a disposable root VM (they create loopback
# LUKS containers). DO NOT run on your workstation. In the Phase 1 VM:
sudo bash tests/vm/dual-env-test.sh         # exercises init/auth/mount/switch/status
sudo bash tests/forensic/forensic-scan.sh /path/to/backing.img   # deniability characterization
```

## 12. Acceptance criteria

- [ ] `bastion-env init` + `bastion-env add` create two volumes with identical Argon2id params.
- [ ] Password A mounts home A; password B mounts home B; a wrong password fails like any other.
- [ ] `verify-active` rejects the *other* env's password during sudo/su with no distinguishable
      behaviour vs. a random wrong password.
- [ ] `try-unlock` wall-clock time is statistically indistinguishable across {A, B, neither}
      (measured by `dual-env-test.sh`).
- [ ] Logout unmounts + closes + wipes before another env can unlock; concurrent logins cannot
      mount two envs.
- [ ] `bastion-env status` output is identical whether or not a second env exists.
- [ ] `/tmp` is per-env; no core dumps land in shared storage; user journal is volatile.
- [ ] `forensic-scan.sh` documents exactly what is and isn't detectable in each provider mode.

## 13. Known limitations

1. **Prototype, not audited.** Syntax-checked only; the crypto/PAM/mount flow must be exercised
   in a VM and security-reviewed before any real use. The native C module is explicitly not the
   trusted path yet.
2. **Deniability is weak in `luks2` mode and only "best-effort" in `shufflecake` mode** — see §2,
   §9. The forensic test makes this concrete rather than assuming it away.
3. **Shufflecake is beta.** Treated as an isolated, opt-in dependency with mandatory per-env
   backups; not forced on anyone.
4. **Residual leaks remain** (user journal timing, NetworkManager, cron, filesystem timestamps,
   monitoring used-bytes) — §8. Some need per-env namespacing we have not built.
5. **Root compromise of the active env defeats the whole model** (shared system dirs). This is
   architectural; documented, not fixed.
