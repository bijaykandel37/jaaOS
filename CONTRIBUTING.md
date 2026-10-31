# Contributing to BastionOS

Start with [`CLAUDE.md`](CLAUDE.md) (the fastest orientation) and the design docs in
[`docs/`](docs/). BastionOS is a **Debian 13 derivative** built as a thin overlay, developed in
reviewable **phases** — each phase's goals, acceptance criteria, and known limitations live in
its `docs/0N-*.md`.

## Dev setup

```bash
make deps     # host build/test dependencies (Debian/Ubuntu)
make lint     # bash -n + shellcheck everything
make help     # list all entry points
```

Building/booting an image needs a Debian host with root; the functional and forensic tests
create real LUKS containers — **run them only in a disposable root VM, never on your workstation.**

## Conventions

- **Shell:** `#!/usr/bin/env bash`, `set -euo pipefail`, tabs, must pass `shellcheck`.
- **Docs are the source of truth for design.** Change behaviour → update the relevant
  `docs/0N-*.md` in the same change.
- **Honesty is a feature.** Don't overstate what the dual-env/deniability or VAPT features do;
  match the framing in `docs/01-threat-model.md`. State verification status truthfully (e.g.
  "syntax-checked, not yet booted").
- **Security-critical code** (PAM, crypto, boot) keeps its "prototype / unaudited" banner until a
  real review happens. Don't remove banners casually.
- Commands in docs must be copy-paste ready — no placeholders.

## The hard-won gotchas

See the **Don'ts** section of [`CLAUDE.md`](CLAUDE.md): no aggressive flags in the signed UKI
cmdline, don't disable user namespaces, the `pam_exec` exit-code bypass trap, and no
environment-enumerating command.

## Scope

BastionOS and its VAPT tooling are for **authorized** security work only. Contributions that are
primarily aimed at attacking third parties, evading detection for malicious use, or similar are
out of scope.
