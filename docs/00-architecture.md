# BastionOS — Architecture (Phase 0)

Status: **accepted for Phase 1**. Audience: the maintainer and any future contributor.
This document fixes the base, the component layering, and the decisions that are expensive to
reverse. The explicit threat model lives in [01-threat-model.md](01-threat-model.md).

---

## 0. The constraint that shapes everything: one maintainer

The architecture is driven less by the feature list than by the fact that **one person**
maintains it. A from-scratch distribution (own archive of thousands of packages, own security
team tracking CVEs, own kernel builds per CVE) is not sustainable solo — the predictable
failure mode is a system that falls behind on security updates, which is *worse* than a stock
distro. Therefore:

> **BastionOS is a Debian 13 (trixie) stable derivative delivered as a thin overlay**, not a
> new distribution. We inherit Debian's package archive, security team, signed kernel, and
> reproducibility infrastructure. We own only: an installer preset, a signed overlay repo of
> `bastion-*` packages, config packages, and hardening defaults.

Every decision below is checked against "can one person keep this patched?"

---

## 1. Base distribution: Debian 13 stable (committed)

### Alternatives considered

| | **Debian stable (chosen)** | **Arch** |
|---|---|---|
| Hosting stability | Rock solid; point releases, no surprise breakage | Rolling; breakage requires active babysitting — bad for unattended servers |
| Security maintenance | Dedicated security team backports fixes for the frozen versions (+ LTS) | Fixes arrive via rolling updates; no security-only channel; you track breakage yourself |
| Update safety | `unattended-upgrades` is mature; security-only pocket | Rolling updates can't be "security only" |
| Freshness of **security tools** | **Stale** in the base archive (the main weakness) | Always current |
| Reproducibility | **snapshot.debian.org** pins every package to a timestamp → bit-reproducible base | Rolling target moves; reproducibility is harder |
| Minimal base | `mmdebstrap` → very small base | `pacstrap` → very small base (tie) |
| Secure Boot / snapshot tooling | shim infra, `sbctl`, snapper, well-trodden derivative path (Kali, Parrot) | `linux-hardened` exists, but less turnkey FDE/UKI/snapshot integration |
| Solo maintenance burden | **Low** (inherit Debian) | **High** (you become a rolling-distro integrator) |

### Why the one real weakness doesn't bite

Debian's staleness only matters for fast-moving **security tools** and **DevOps CLIs**. We solve
freshness exactly where it matters and nowhere else — which also keeps the host minimal:

- **VAPT tools run in pinned, versioned containers**, never as host packages (Phase 6). Freshness
  = pull a newer image. Zero host contamination. This is already the required design.
- **Fast-moving Go tools** (nuclei, httpx, subfinder, ffuf, trivy, grype, syft) ship as pinned
  static binaries in the overlay repo, bumped by a one-line CI job.
- **DevOps CLIs** (kubectl, helm, OpenTofu, k9s, cloud CLIs) are managed by **`mise`** per the
  product spec — version-pinned per project, decoupled from the base.

Result: the **host** stays stable, minimal, and Debian-maintained; the **tools** stay current.
Arch would give freshness everywhere at the cost of stability and solo maintainability — the
wrong trade for this project.

### aarch64 (what it would take, deferred post-1.0)

Debian is already multi-arch, so the base is free. The work is: an `arm64` component in the
overlay repo; re-applying the hardened kernel cmdline/config for arm64; Secure Boot via the
arm64 shim (per-board, no universal UEFI like x86); and arm64 variants of the VAPT container
images (most exist; a few tools are x86-only — documented gaps). Not in scope for v1.

**ADR:** [docs/decisions/0001-base-distribution.md](decisions/0001-base-distribution.md)

---

## 2. Component layering

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ PROFILES (APT meta-packages, every component a toggle)                    │
 │   minimal · server(+web/lb/monitoring) · desktop(GNOME) · security-lab    │
 ├─────────────────────────────────────────────────────────────────────────┤
 │ BASTION TOOLING (bastion-* debs in signed overlay repo)                   │
 │   bastion (system.toml: diff/apply) · bastion-env (dual-home)             │
 │   bastion-host (sites/LB) · bastion-scan (VAPT) · bastion-health          │
 │   bastion-audit (Lynis/CIS)                                               │
 ├───────────────────────────────┬───────────────────────────────────────────┤
 │ CONTAINERIZED WORKLOADS        │ MONITORING STACK (local, containerized)   │
 │   VAPT tools (netns-isolated,  │   Prometheus · node_exporter · Loki ·     │
 │   scope-enforced) · Podman     │   Alloy · Grafana · Alertmanager · Falco  │
 │   rootless default · k3s opt   │                                           │
 ├───────────────────────────────┴───────────────────────────────────────────┤
 │ AUTH / POLICY                                                             │
 │   PAM (pam_bastion_env: tries pw → mounts matching home) · polkit ·       │
 │   AppArmor (enforcing, profiles per shipped service) · sudo/su            │
 ├─────────────────────────────────────────────────────────────────────────┤
 │ SYSTEM SERVICES                                                           │
 │   systemd · nftables (default-deny inbound) · auditd · AIDE ·             │
 │   CrowdSec · unattended-upgrades · snapper                                │
 ├─────────────────────────────────────────────────────────────────────────┤
 │ KERNEL (Debian signed stock kernel + hardening)                          │
 │   lockdown=confidentiality · module.sig_enforce · KSPP cmdline/sysctl ·   │
 │   AppArmor LSM · IOMMU · (no fork)                                        │
 ├─────────────────────────────────────────────────────────────────────────┤
 │ STORAGE                                                                   │
 │   LUKS2 (Argon2id) FDE · Btrfs + snapper (system subvols only) ·          │
 │   hidden Environment B volume (passphrase-only) · encrypted swap (random) │
 ├─────────────────────────────────────────────────────────────────────────┤
 │ BOOT                                                                      │
 │   systemd-boot · signed UKI (kernel+initrd+cmdline as one signed image)   │
 ├─────────────────────────────────────────────────────────────────────────┤
 │ FIRMWARE                                                                  │
 │   UEFI Secure Boot (user-enrolled keys via sbctl) · TPM2                  │
 └─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Boot and Secure Boot

- **systemd-boot** + **Unified Kernel Image (UKI)**: kernel, initrd, and **kernel command line**
  are combined into one PE binary and signed as a unit. This matters because the cmdline and
  initrd carry the FDE-unlock logic; signing them as a unit stops an attacker appending
  `init=/bin/sh` or swapping the initrd. A split kernel+initrd+loader-config setup cannot
  guarantee that.
- **Keys:** user-enrolled with **`sbctl`** (firmware in Setup Mode → enroll own PK/KEK/db). For a
  solo project this is simpler and stronger than relying on the Microsoft-signed shim. The
  shim path is documented for anyone who later redistributes images to machines they can't put
  in Setup Mode.
- **TPM2** measures the boot chain; see §4 for how auto-unlock interacts with deniability.

---

## 4. Full-disk encryption, TPM2, and the deniability tension

FDE is on by default: **LUKS2 with Argon2id** (memory-hard KDF, resists GPU/ASIC cracking).

**The tension (flagged, not hidden):** TPM2 auto-unlock works by sealing the LUKS key to the
measured boot state and storing a **TPM2 token in the LUKS2 header**. That is fine for a volume
whose existence you don't need to deny. But a TPM2 token, keyslot, or sealed key object for the
**hidden Environment B** is itself *evidence that B exists*. So:

- **Primary / declarable volume:** normal LUKS2, optional **TPM2 + PIN** sealing. Auto-unlocks on
  trusted boot state; PIN resists a stolen-but-powered-off machine. Fully declarable.
- **Hidden Environment B:** **passphrase-only, no TPM token, no visible keyslot.** Realized as a
  hidden volume whose header is indistinguishable from the random data the whole disk is
  initialized with. Storage mechanism is decided in Phase 2; the current lean is **Shufflecake**
  (purpose-built Linux multi-hidden-volume dm target) with a LUKS2-detached-header fallback. Its
  **beta maturity is a Top Risk** (§8).

**Honest consequence:** TPM2 convenience applies to the declarable environment only. The hidden
environment trades auto-unlock away by necessity. And even perfect crypto hides B's *contents*,
not its *existence* — see the threat model.

Other storage rules:
- **Encrypted swap** with a **random per-boot key** (no hibernation → keys never written to disk).
- **`/tmp` and `/var/tmp` on tmpfs** (RAM-backed, gone on power-off).
- **Btrfs + snapper** snapshots are scoped to **system subvolumes only, never the mounted home**,
  so a snapshot can never capture Environment B's contents, timestamps, or even the fact that it
  mounted. Home containers live outside the snapshotted Btrfs tree.

---

## 5. Kernel hardening (no fork)

We ship **Debian's signed stock kernel** and harden it at runtime + boot, rather than building a
`linux-hardened` equivalent. Rebuilding the kernel per-CVE solo is the fastest route to running an
*out-of-date* kernel; inheriting Debian's kernel security team is strictly safer in practice. An
opt-in custom-config `bastion-hardened-kernel` may come in a later phase, never in v1.

KSPP-aligned defaults, with workload-breaking options justified:

| Setting | Effect | Breakage & mitigation |
|---|---|---|
| `lockdown=confidentiality` | Blocks kexec, `/dev/mem`, unsigned module load, raw kernel access | Breaks hibernation (already disabled), kdump (disabled — crash dumps leak memory incl. keys), some driver-level VAPT ops. Those VAPT ops run in containers with explicit caps instead. **Documented limitation.** |
| `module.sig_enforce=1` | Only signed modules load | Breaks unsigned DKMS (VirtualBox, some NVIDIA). Mitigation: **MOK enrollment + auto-sign DKMS** at build. Flagged for users needing those. |
| `init_on_alloc=1 init_on_free=1` | Zeroes heap on alloc/free, kills many use-after-free infoleaks | ~1–3% perf cost. Accepted. |
| `slab_nomerge`, `randomize_kstack_offset=1`, `pti=on`, `vsyscall=none` | Harden allocator/stack/meltdown/legacy ABI | Low risk. `vsyscall=none` can break *very* old static glibc binaries — not relevant here. |
| `mitigations=` | CPU-vuln mitigations | **Server profile defaults to `auto` (keeps SMT)** for throughput; **workstation/high-assurance can opt into `auto,nosmt`**. `nosmt` is a real, large perf loss — surfaced as a choice, not forced. |
| IOMMU on (`intel_iommu=on`/`amd_iommu=on`, `iommu=force`), Thunderbolt security | Blocks DMA attacks | Rare device-passthrough friction; acceptable. |

Hardened **sysctl** (kptr_restrict, dmesg_restrict, `kernel.yama.ptrace_scope=2`,
`unprivileged_bpf_disabled`, `net.ipv4` anti-spoofing, etc.) ships in a config package.

---

## 6. Mandatory access control: AppArmor (enforcing)

**AppArmor**, not SELinux. Rationale: it is the Debian/Ubuntu-native LSM (profiles for shipped
services are far easier to write and maintain solo than SELinux policy), path-based profiles are
tractable for one person, and GNOME/GDM integrate with it cleanly. SELinux offers finer type
enforcement but a maintenance cost a solo project can't carry. Every **shipped service** (nginx,
Caddy, HAProxy, Traefik, the `bastion-*` daemons, monitoring exporters) ships an enforcing
profile; third-party workloads default to the generic container confinement (Podman + its
AppArmor/seccomp defaults).

---

## 7. Profiles (meta-packages; every component a toggle)

Each profile is an APT meta-package depending on component meta-packages. The installer presents
components as toggles; `bastion install <component>` adds one later; `system.toml` makes the set
declarative.

| Profile | Contents | Target idle RAM¹ | Target disk¹ |
|---|---|---|---|
| **Minimal** | base + SSH (key-only) + nftables + CLI tools + auditd + CrowdSec; no GUI | ~400–600 MB | ~3–4 GB |
| **Server** | Minimal + `bastion-host` (nginx/Caddy/HAProxy/Traefik/keepalived) + Podman + monitoring | ~0.8–1.2 GB | ~6–8 GB |
| **Desktop** | Minimal + **GNOME** (Wayland) + Flatpak/bubblewrap + optional server tooling | ~1.5–2 GB | ~12–15 GB |
| **Security Lab** | Desktop + containerized VAPT toolkit (`bastion-scan`) | ~2–2.5 GB | ~20–30 GB (images) |

¹ Estimates to be *verified* by Phase 1/3 acceptance tests, not promises.

**Desktop = GNOME** over KDE Plasma: stronger/simpler Wayland story, a smaller moving-part count
for a solo maintainer, and a GDM/lock-screen PAM stack that integrates predictably with the
dual-env PAM module (lock-screen consistency is a hard requirement). KDE is more configurable
(the "Arch feel") but heavier and a larger attack/maintenance surface — noted as the alternative.

---

## 8. Top risks

1. **Solo-maintainer sustainability (highest).** A signed repo, CI ISO builds, and security
   tracking are ongoing work; if they lapse, users run stale systems. *Mitigation:* overlay-on-
   Debian (inherit the hard part), containerized tools, minimal custom code, heavy CI automation.
2. **Deniability over-promise = user-safety risk.** The marquee feature can give users false
   confidence that gets them hurt under coercion/forensics. *Mitigation:* ship the honest threat
   model on-device; `bastion-env status` reveals nothing; never market "undetectable."
3. **Deniable-storage maturity.** Shufflecake is beta; beta code in the storage/boot path risks
   data loss. *Mitigation:* extensive VM + forensic test suite (Phase 2), per-environment backups,
   a LUKS2-detached-header fallback design.
4. **TPM2 ↔ deniability conflict.** Auto-unlock tokens are evidence. *Mitigation:* B is
   passphrase-only; documented.
5. **Hardened-kernel breakage.** lockdown/`sig_enforce` break DKMS/VBox/NVIDIA and some host-level
   VAPT ops. *Mitigation:* MOK auto-signing, containerized tools, documented opt-outs.
6. **Shared system dirs defeat env isolation under compromise.** Root malware persisting in the
   shared `/` can read the other environment once unlocked. *Architectural limit*, documented;
   partial mitigation via AIDE/auditd/AppArmor/rootless containers.
7. **Installer complexity for deniable FDE.** Stock Calamares can't partition deniable volumes; a
   custom module or a `bastion-env init` post-install flow is required. *Scheduled realistically
   in Phase 2/3.*
8. **Supply chain of fast-moving tools.** Pinned binaries/images rot or disappear. *Mitigation:*
   pin by digest, mirror images into the overlay, record provenance.

---

## 9. Acceptance criteria for Phase 0

- [x] Base distribution chosen with alternatives and trade-offs, and committed (Debian 13).
- [x] Component diagram covering firmware → profiles.
- [x] Explicit threat model with per-adversary verdicts ([01-threat-model.md](01-threat-model.md)).
- [x] Repository layout defined and scaffolded.
- [x] Top risks enumerated with mitigations.
- [x] The deniability limits stated honestly, not deferred.

## 10. Known limitations of this phase

- Numbers in §7 are targets, not measurements.
- The dual-home **storage mechanism** is a *lean* (Shufflecake), not yet a commitment — it is
  decided in Phase 2 after a prototype and forensic testing.
- No code or build artifacts yet; Phase 1 produces the first bootable ISO.
