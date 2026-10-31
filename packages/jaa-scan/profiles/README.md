# jaa-scan profiles

A profile maps to a fixed, non-destructive tool command that `jaa-scan` runs inside the
pinned container (see `profile_cmd()` in `../bin/jaa-scan`). Every profile is reconnaissance
or **vulnerability assessment** — enumeration and known-issue detection — never active
exploitation. All are rate-capped from the engagement's `MAX_RATE_PPS`.

| Profile | Tool(s) | What it does | Output |
|---|---|---|---|
| `discovery` | `nmap -sT -sV -Pn --script=safe` | TCP connect scan + service/version detection; only the `safe` NSE category | `<host>.nmap.xml` |
| `tls` | `sslscan` | TLS protocol/cipher/cert hygiene (read-only handshake inspection) | `<host>.sslscan.xml` |
| `web` | `whatweb` + `nuclei` | Tech fingerprint + template-based detection (ProjectDiscovery community templates) | `<host>.whatweb.txt`, `<host>.nuclei.txt` |

## Why no exploitation / fuzzing / DoS profile

The "PT" in VAPT (active exploitation) is intentionally **not** a push-button profile:

- A solo-maintained distro should not ship an auto-exploit button; the blast radius and the
  authorization bar are different in kind from assessment.
- Tools like `sqlmap --risk=3`, aggressive `ffuf` fuzzing, or exploit frameworks are *available
  in the container ecosystem* but are not wired into a default profile. Running them is an
  explicit, manual, separately-authorized act — and still only ever against in-scope targets.
- Nothing here does stress/DoS or detection-evasion. Those are out of scope for jaaOS.

If an engagement genuinely needs a heavier tool, add it to the Containerfile and define a new
profile, keep it out of the default `ALLOW_PROFILES`, and require its own authorization line in
the engagement. The scope gate and audit log apply to it exactly the same way.
