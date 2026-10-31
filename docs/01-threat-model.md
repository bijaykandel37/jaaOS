# BastionOS — Threat Model (Phase 0)

This document is deliberately pessimistic. The dual-password feature is the one most likely to be
*trusted with someone's safety*, so it gets the harshest treatment. The detailed per-datum leakage
analysis (journald, `/tmp`, Docker state, swap, kernel keyring, timestamps, monitoring metrics,
etc.) is produced in **Phase 2** against a real VM disk image; this phase states the model and the
honest verdicts that follow from the architecture.

## Assets

- **A1** Contents of Environment A's home (the declarable one).
- **A2** Contents of Environment B's home (the hidden one).
- **A3** The *fact that B exists*.
- **A4** System integrity (that the running OS is the signed one).
- **A5** Credentials/keys in memory while unlocked.

## What "dual-password" is, precisely

One username, one UID, shared system directories. Password A unlocks and mounts home A at
`/home/<user>`; password B unlocks and mounts home B at the same path. Only one is mounted at a
time. `/etc/shadow` holds **no password hash for the user** — authentication succeeds iff an
entered password decrypts one of the home containers (design detail in Phase 2), so a stored hash
cannot reveal that two passwords exist. Authentication timing is equalized whichever matches (or
none does), so response time can't signal "two slots exist."

This gives **confidentiality isolation** between A and B that is strong at rest. It attempts
**deniability of A3**. The two are not equally achievable, and conflating them is the trap.

## Per-adversary verdicts

Legend: **Defends** / **Partial** / **Does not defend**.

| # | Adversary / scenario | Verdict | Why |
|---|---|---|---|
| T1 | **Lost/stolen laptop, powered off** | **Defends** (A1, A2, A3) | LUKS2 + Argon2id on the whole disk; disk is random-initialized so headers of the hidden volume are not distinguishable from free space *by casual inspection*. Contents and existence both protected against someone who just powers it on. |
| T2 | **Lost laptop, suspended (RAM powered)** | **Partial** (A5 at risk) | Keys for the *currently unlocked* environment live in RAM. Cold-boot/DMA attacks possible. Mitigations: IOMMU on, Thunderbolt locked, TPM2+PIN so a reboot can't silently re-unlock, lock-on-suspend. Hibernation is **disabled** (so keys are never written to disk), which means suspend keeps them in RAM — an accepted trade. **Advice: power off, don't suspend, when crossing a risk boundary.** |
| T3 | **Shoulder-surfing** | **Defends (moderately)** | A and B are both just passwords; an observer who sees you type one cannot tell which environment it opened, and `bastion-env status` never names the other. Does not help if they record you typing *both* over time. |
| T4 | **Coerced disclosure, adversary unaware of BastionOS / non-technical** | **Partial** | You can disclose password A and present a plausible, used Environment A. Works only while the coercer has no reason to believe a second environment exists. |
| T5 | **Coerced disclosure, adversary knows you run BastionOS** | **Does not defend (A3)** | This is the core honest limitation. BastionOS's defining feature is dual-home. An informed coercer assumes B may exist and keeps coercing. "There is only A" is **not credible** on a system whose name implies otherwise. No software fixes this. |
| T6 | **Legal compulsion** | **Does not defend** | In several jurisdictions you can be legally ordered to disclose keys, with penalties for refusal. Deniable encryption is not a defense against the law. |
| T7 | **Malware/rootkit gains root in Environment A** | **Does not defend (A2, A3)** | System directories are **shared**. Root-level persistence installed while A is unlocked survives into the B session and can read B's home the moment it mounts, log B's password, or exfiltrate. Env separation is **not** a malware boundary. Partial detection only: AIDE (file integrity), auditd, AppArmor, Secure Boot + signed UKI (protect A4, not A2). |
| T8 | **Forensic examiner with a full disk image** | **Contents: Defends. Existence (A3): Does not defend.** | Crypto protects A1/A2 — B's bytes are unrecoverable without the password. But a competent examiner sees: LUKS2 headers, a fully random-initialized disk, and the on-disk **BastionOS deniable-storage tooling itself**. That combination is strong evidence a hidden volume *may* be present. They can't read it, but they can assert it probably exists. Statistical/freespace analysis and any write to the decoy that perturbs hidden regions strengthen the inference. |
| T9 | **Hidden-volume overwrite (operational, not an adversary)** | **Risk to A2** | Writing enough to Environment A (the outer/decoy) can overwrite Environment B's region and destroy it, because the decoy must not "know" B is there. Mitigation: size reservations, warnings, and per-environment backups (Phase 2/6). VeraCrypt-style hidden volumes share this hazard; Shufflecake mitigates but does not eliminate it. |
| T10 | **Evil-maid (tamper with boot while you're away)** | **Partial** | Secure Boot + signed UKI + TPM2 PCR measurement detect/か prevent tampering with the boot chain (A4); TPM2+PIN means a tampered boot state won't unseal. Does not defend against a hardware implant below the measured boot (firmware, DMA device) — out of scope for software. |

## The one sentence a user must internalize

> BastionOS's dual-home feature protects the **contents** of both environments when the machine is
> **off**, and hides the second environment from **casual and opportunistic** inspection. It does
> **not** hide that a second environment might exist from someone who knows you run BastionOS, from
> a forensic examiner, or from malware that got root — and it is not a defense against being
> legally compelled to disclose a password.

## Why we still ship it

Within its real envelope — lost/stolen powered-off device, shoulder-surfing, opportunistic access,
separating client engagements from personal data — it is genuinely useful, and the honest framing
lets users decide for themselves. The alternative (shipping it as "undetectable") would be the
actual harm. The on-device docs and `bastion-env --help` repeat this envelope.

## Deferred to Phase 2 (full leakage analysis)

For each of these, Phase 2 states shared/isolated/scrubbed + residual risk, measured on a VM
image: journald & auth logs (which container mounted), `/tmp`, `/var/tmp`, `/var/cache`,
`/var/lib` (Docker/Podman/Flatpak state), `/run/user`, swap, hibernation, crash dumps, package
manager logs, NetworkManager profiles, systemd **user** units, cron/at jobs, kernel keyring,
filesystem timestamps, disk-usage metrics exposed by monitoring, thumbnail and recently-used
caches. The architecture already forecloses several (tmpfs `/tmp`, random-key swap, no
hibernation, no kdump, home-excluded snapshots); the rest need measurement, not assertion.
