# Security policy

BastionOS is security tooling intended for **authorized** use on systems you own or are
explicitly permitted to test. Please understand the honest limits of its protections before
relying on them.

## Reporting a vulnerability

Use GitHub's **“Report a vulnerability”** (Security Advisories) on this repository for a private
report. Please do **not** open a public issue for an undisclosed vulnerability. Include steps to
reproduce and the affected files/commit. There are no SLAs — this is a one-maintainer project.

## Current status: prototype, not audited

Phases 0–2 are **design + prototype code that has only been syntax-checked**, not built, booted,
or security-reviewed. The PAM/crypto/boot paths are explicitly marked “prototype / unaudited”.
Do not deploy BastionOS on data you cannot afford to lose, and do not rely on it in a real
threat scenario until it has been reviewed.

## Honest scope of the dual-password / “deniable” feature

It protects the **contents** of both home environments when the machine is **powered off**, and
hides the second environment from **opportunistic** inspection. It does **not**:

- hide that a second environment exists from a competent forensic examiner, or from anyone who
  knows the machine runs BastionOS;
- protect one environment from malware that gained **root** while the other was active (system
  directories are shared);
- defend against being **legally compelled** to disclose a password.

Full analysis: [`docs/01-threat-model.md`](docs/01-threat-model.md) and
[`docs/03-phase2-dual-env.md`](docs/03-phase2-dual-env.md) §9.

## VAPT tooling (later phase)

The bundled vulnerability-assessment tools are **authorized-testing-only**: every run requires an
engagement file declaring scope + an authorization reference, out-of-scope targets are refused,
and runs are logged for audit. Do not use them against systems you are not permitted to test.
