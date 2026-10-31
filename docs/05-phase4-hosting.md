# BastionOS — Phase 4: Hosting & load-balancing CLI (`bastion-host`)

Status: **written and syntax-checked; not yet run against live services** (needs a host with
nginx/caddy/haproxy/keepalived installed — see Test plan). Prototype in bash is the behavioural
spec; the Rust port target is `crates/bastion-host` (ADR 0002).

## Goal

One CLI, `bastion-host`, to stand up web sites and load balancers safely. Every mutating command
follows the same pipeline:

> **generate config → validate → reload with zero downtime → open the firewall port →
> register a monitoring target**

If validation fails, nothing is reloaded and no port is opened.

## Commands (matching the brief)

```
bastion-host site create example.com --php 8.3 --tls
bastion-host site create app.example.com --proxy http://127.0.0.1:3000
bastion-host site list | rm <domain>

bastion-host lb create app-lb --backend 10.0.0.11:80 --backend 10.0.0.12:80 \
                              --algo leastconn --health /healthz --port 80
bastion-host lb list | rm <name>

bastion-host ha create vip0 --vip 10.0.0.10/24 --interface eth0 --priority 150 --state MASTER
```

Engines: `site` → **nginx** (default) or **caddy** (`--engine caddy`, auto-TLS); `lb` →
**haproxy** (default) or **traefik** (`--engine traefik`); `ha` → **keepalived** (VRRP).

## How each step works

- **Generate:** config is written to the engine's own dir (`/etc/nginx/sites-*`,
  `/etc/caddy/bastion.d`, `/etc/haproxy/conf.d`, `/etc/traefik/dynamic`,
  `/etc/keepalived/conf.d`) and a small state record under `/etc/bastion/host/`.
- **Validate:** `nginx -t`, `caddy validate`, `haproxy -c -f`, `keepalived -t` before any reload.
- **Reload (zero-downtime):** `systemctl reload` (nginx graceful; haproxy seamless `-sf`; caddy
  `caddy reload`; traefik watches its dynamic dir; keepalived reload). Restart only as fallback.
- **Firewall:** the port is added live with `nft add element inet filter bastion_tcp_open { N }`
  and persisted to `/etc/nftables.d/bastion-host.nft` (included by the Phase-1 `nftables.conf`),
  so it survives reboot.
- **Monitoring:** a Prometheus **file_sd** target is written to
  `/etc/bastion/monitoring/targets.d/<name>.json`, which the Phase-5 stack discovers
  automatically. No restart of Prometheus needed.

## TLS and PHP (honest requirements)

- `--tls` with **caddy** is automatic (Caddy obtains/renews Let's Encrypt certs itself).
- `--tls` with **nginx** runs `certbot --nginx -d <domain>` — which needs the domain's A/AAAA
  record pointing here and ports 80/443 reachable from the internet. If `certbot` is absent or
  DNS isn't ready, the site is created on HTTP and a clear next-step is printed (no silent
  failure).
- `--php <ver>` generates a `fastcgi_pass` to `/run/php/php<ver>-fpm.sock`; install the matching
  `php<ver>-fpm` package first. The CLI warns if the socket/package is missing.

## Files in this phase

| File | Purpose |
|---|---|
| `packages/bastion-host/bin/bastion-host` | The CLI (bash prototype / spec). |
| `config/rootfs/etc/nftables.d/bastion-host.nft` | Persisted runtime-opened ports (included by `nftables.conf`). |
| `config/rootfs/etc/nftables.conf` | +`include` of the managed ports file (edited this phase). |
| `crates/bastion-host/` | Rust port scaffold (clap command tree) for the cloud. |
| `tests/vm/hosting-test.sh` | Generates configs to a sandbox dir and validates them with the engines if present. |

## Build / test (copy-paste)

```bash
cd /home/bijay/Public/jaaOS
bash -n packages/bastion-host/bin/bastion-host

# On a host/VM with the engines installed:
sudo apt install -y nginx caddy haproxy keepalived certbot python3-certbot-nginx
sudo bash tests/vm/hosting-test.sh            # config generation + validation (no public DNS needed)

# Live examples (need the services running):
sudo bastion-host site create demo.local --proxy http://127.0.0.1:8080
sudo bastion-host lb create app-lb --backend 127.0.0.1:8081 --backend 127.0.0.1:8082 --algo leastconn --health /healthz
```

## Acceptance criteria

- [ ] `site create` produces a config that passes `nginx -t`/`caddy validate`, reloads without
      dropping connections, opens the port in nftables, and writes a monitoring target.
- [ ] `lb create` with two backends passes `haproxy -c`, balances per `--algo`, and health-checks
      `--health`.
- [ ] A failed validation aborts before reload and before opening any port.
- [ ] Opened ports persist across a reboot (via the included nft file).
- [ ] `site list`/`lb list` show managed resources; `rm` removes config + monitoring target and
      reloads.

## Known limitations

1. **Not yet run against live services.** Syntax-checked only; needs the engines installed.
2. **bash prototype**, pending the Rust port (`crates/bastion-host`).
3. **nginx `--tls`** depends on public DNS + reachable 80/443; caddy is the turnkey auto-TLS path.
4. **Port removal on `site rm`** leaves shared 80/443 open (other sites may use them); only
   `lb`/explicit ports are closed. Documented; a refcount is a later refinement.
5. **Cockpit web UI** (the brief's optional GUI) is deferred to Phase 7 polish — the CLI is the
   source of truth; a Cockpit plugin would call these same commands.
6. **k3s** (optional) is not wired here; it belongs with the container/orchestration tooling.
