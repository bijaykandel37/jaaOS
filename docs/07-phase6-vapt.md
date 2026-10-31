# jaaOS — Phase 6: VAPT toolkit (`jaa-scan`)

Status: **written; guardrails exercised in a sandbox (real run, no root, no network — 
`tests/vm/vapt-test.sh`, 28/28).** The containerized tools themselves have not been run against a
live target here (that needs Podman + the built image + an authorized target — see Test plan).
The bash `jaa-scan` is the behavioural spec; the Rust port target is `crates/jaa-scan`
(ADR 0002).

## The one thing to understand first

`jaa-scan` is **authorized-testing-only**. Its job is to make unauthorized or out-of-scope
testing *hard to do by accident*. The value over running `nmap` by hand is the **guardrails**:

> No engagement file, or no `AUTHORIZATION_REF`, or no scope → **refuse**.
> Target not in scope, or excluded, or in a hard-denied range, or outside the time window →
> **refuse**. One out-of-scope target in a batch → **refuse the whole run**. Every run is
> **audited**. Tools run **containerized**, rootless, with all capabilities dropped.

It ships **no exploits, no DoS/stress, no detection-evasion, and no mass-targeting**. The default
profiles are non-destructive reconnaissance / vulnerability **assessment**. That is a deliberate
line for a solo-maintained distro, not an oversight (see `packages/jaa-scan/profiles/README.md`).

## Commands

```
jaa-scan engagement init <name>        # scaffold ./engagement.conf
jaa-scan engagement show | validate    # show / validate authorization + scope + window
jaa-scan scope check <target...>       # test targets against scope WITHOUT scanning
jaa-scan run <profile> <target...>     # run a profile against in-scope targets (audited)
jaa-scan report                        # results + audit summary
```

`JAA_SCAN_ENGAGEMENT=<file>` picks the engagement; `JAA_SCAN_DRYRUN=1` resolves scope and
writes the audit line **without launching anything** (what the test and a dry-run use).

## The engagement file (authorization is mandatory)

A parsed `KEY=value` file — **data, never sourced** (so a stray backtick can't run). Example in
`packages/jaa-scan/engagement.example.conf`. Required: `AUTHORIZATION_REF` and at least one
of `SCOPE_CIDRS` / `SCOPE_HOSTS` / `SCOPE_DOMAINS`. Optional: `WINDOW_START/END`, `EXCLUDE`,
`MAX_RATE_PPS`, `ALLOW_PROFILES`, `OPERATOR`.

```
AUTHORIZATION_REF=SOW-2026-014 (written authorization on file)   # no ref -> no scan
SCOPE_CIDRS=203.0.113.0/24 198.51.100.10/32
SCOPE_HOSTS=app.example.com
SCOPE_DOMAINS=example.com          # also matches *.example.com
EXCLUDE=203.0.113.1                # exclusions ALWAYS win over scope
WINDOW_START=2026-10-01T00:00:00Z
WINDOW_END=2026-12-31T23:59:59Z
MAX_RATE_PPS=100
ALLOW_PROFILES=discovery tls web
```

## How the scope gate decides (and why it is conservative)

For each target (an IP, host, or URL — the host is extracted from a URL):

1. **Hard-denied ranges** are refused *even if someone scopes them*: `169.254.0.0/16`
   (link-local, incl. the cloud-metadata `169.254.169.254`), `224.0.0.0/4` (multicast),
   `0.0.0.0/8`, and the broadcast address. Loopback is **not** hard-denied — self-testing
   `127.0.0.1` is legitimate — but only runs if you put it in scope explicitly.
2. **Exclusions** win over scope: an `EXCLUDE` match is refused.
3. **IP targets** must fall inside a `SCOPE_CIDRS` entry (IPv4 CIDR math).
4. **Host targets** must be an exact `SCOPE_HOSTS` entry or a sub-domain of a `SCOPE_DOMAINS`
   entry.

`scope check` runs *only* this logic — no packets, no DNS — so you can prove what is in scope
before touching anything.

## Containerized execution

Tools run in the pinned image (`packages/jaa-scan/containers/Containerfile.vapt`,
Debian-based, unprivileged `scanner` user) via rootless Podman:

```
podman run --rm --network=slirp4netns --cap-drop=ALL --security-opt no-new-privileges=true \
  --read-only --tmpfs /tmp -v <results>:/out:Z localhost/jaaos/vapt:pinned <tool cmd>
```

No capabilities, no new privileges, read-only rootfs, results to a single bind mount. The image
has no `ENTRYPOINT`: `jaa-scan` passes the exact command, so the container can only do what
the scope-enforcing wrapper tells it to.

## Profiles (non-destructive)

| Profile | Tool(s) | Output |
|---|---|---|
| `discovery` | `nmap -sT -sV -Pn --script=safe` (rate-capped) | `<host>.nmap.xml` |
| `tls` | `sslscan` | `<host>.sslscan.xml` |
| `web` | `whatweb` + `nuclei` (community templates, rate-capped) | `<host>.whatweb.txt`, `<host>.nuclei.txt` |

Active exploitation / fuzzing / DoS are intentionally **not** default profiles — see the
profiles README for the rationale and how a separately-authorized heavier tool would be added.

## Audit

Every `run` (including dry-runs) appends one JSON line to `/var/log/jaa-scan/audit.log`:
timestamp, operator, engagement, `authorization_ref`, profile, targets, image, `dry_run`, and the
exact command. Harden it append-only on a real host: `sudo chattr +a /var/log/jaa-scan/audit.log`.

## Files in this phase

| File | Purpose |
|---|---|
| `packages/jaa-scan/bin/jaa-scan` | The CLI (bash prototype / spec): engagement, scope gate, run, audit. |
| `packages/jaa-scan/engagement.example.conf` | Documented example engagement (RFC 5737/2606 ranges). |
| `packages/jaa-scan/profiles/README.md` | What each profile runs; why no exploit/DoS profile. |
| `packages/jaa-scan/containers/Containerfile.vapt` | Pinned, unprivileged VAPT image. |
| `config/rootfs/etc/jaa/scan/scan.conf` | Image ref, audit-log and results paths. |
| `crates/jaa-scan/` | Rust port scaffold (clap tree). |
| `tests/vm/vapt-test.sh` | Guardrail tests — scope/auth/window/audit, no scanning. |

`build/profiles/security-lab.packages` already pulls in the container runtime (podman, buildah,
skopeo, uidmap, slirp4netns) for this phase.

## Build / test (copy-paste)

```bash
cd /home/bijay/Public/jaaOS
bash -n packages/jaa-scan/bin/jaa-scan
bash tests/vm/vapt-test.sh          # guardrails only — no scanning, no network, no root

# On a host with rootless Podman:
podman build -t localhost/jaaos/vapt:pinned -f packages/jaa-scan/containers/Containerfile.vapt .
cp packages/jaa-scan/engagement.example.conf ./engagement.conf
$EDITOR ./engagement.conf           # set AUTHORIZATION_REF + your OWN in-scope targets
jaa-scan engagement validate
jaa-scan scope check <your-target>            # prove scope before scanning
JAA_SCAN_DRYRUN=1 jaa-scan run discovery <your-target>   # see the exact command first
jaa-scan run discovery <your-target>          # against a target you are authorized to test
```

## Acceptance criteria

- [x] Refuses with no engagement, no `AUTHORIZATION_REF`, or no scope. *(test)*
- [x] In-scope IP/host/sub-domain accepted; out-of-scope, excluded, and hard-denied refused;
      exclusions and hard-deny win over scope. *(test)*
- [x] Outside the engagement window → refused; one out-of-scope target aborts the whole run. *(test)*
- [x] The assembled container command drops all caps, sets no-new-privileges, uses the pinned
      image and the rate cap, and carries no privileged flags. *(test)*
- [x] Every run is audited with the authorization reference; dry-runs execute nothing. *(test)*
- [ ] On a host: the image builds; `discovery`/`tls`/`web` produce results against an authorized
      target; results land in `/out`.

## Known limitations

1. **Guardrails tested; live scanning not run here.** No image build or real scan in this
   environment (no Podman/network). The container command is assembled and audited but only
   executed on a real host.
2. **Scope is matched on the declared identifier, not a resolved IP.** A hostname in scope is
   not cross-checked against the IP it resolves to (that would require DNS and could itself leak
   intent). Declare both the host and its CIDR if you want both enforced. Documented; a
   resolve-and-reconcile step is a later refinement.
3. **IPv4 only** for CIDR math. IPv6 scope entries are not yet matched; add host entries instead.
4. **bash prototype**, pending the Rust port (`crates/jaa-scan`).
5. **nuclei is fetched from a GitHub release** in the image (not Debian); pin by version and
   verify its checksum in a real build. Debian-packaged tools (nmap/sslscan/whatweb) inherit
   Debian security maintenance.
6. **Audit log integrity** relies on `chattr +a` + normal file permissions; it is not a tamper-
   proof store. Ship it off-box for real engagements.
