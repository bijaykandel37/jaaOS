# jaaOS — Docker + RKE2 cluster roles

Every jaaOS system ships **Docker** (Debian's `docker.io`) and a **pinned RKE2** release
(`build/rke2.lock`, hash-checked by `build/fetch-rke2.sh`). The installer asks what the
machine is in a Kubernetes cluster: **master**, **worker** or **none**. `jaa-cluster`
(`packages/jaa-cluster/bin/jaa-cluster`, bash spec; Rust port target `crates/jaa-cluster`)
does the work, both from the installer and on a running system.

| Term in jaaOS | RKE2 term | What runs |
|---|---|---|
| master | server | control plane (etcd, API server, scheduler) + kubelet |
| worker | agent | kubelet + your pods |
| none | — | nothing (Docker only); RKE2 stays installed but disabled |

## Choosing the role

**At install time** (`sudo jaa-install` from the live ISO), after the profile question:

1. *What is this machine in a Kubernetes cluster?* none / master / worker.
2. Worker only: pick the master from the list of masters announcing on this network (or type
   its address), type the **join code**, then confirm the **fingerprint** (see below).
3. The hostname defaults to `jaa-master-<last 4 hex of the MAC>` or `jaa-worker-…`, because every
   node needs a unique name.

The installer writes `/etc/rancher/rke2/config.yaml`, the firewall drop-in and the kernel
settings into the new system and enables `rke2-server` or `rke2-agent`. The node starts on
first boot.

Unattended installs set the same choice in the answer file (see
`installer/answers.example.conf`): `CLUSTER_ROLE`, plus for a worker `CLUSTER_SERVER`,
`CLUSTER_JOIN_CODE` and `CLUSTER_FINGERPRINT`.

**Later**, on an installed or live system:

```bash
sudo jaa-cluster setup master
sudo jaa-cluster setup none
sudo jaa-cluster status
```

## How a master and a worker find and trust each other

Two fresh machines on the same LAN need three things: the master's **address**, a **secret**
that lets the worker join, and a way for the worker to know it is talking to the **real**
master. They have to get these from the console, where there is no copy and paste. The jaaOS
design:

```
 MASTER                                              WORKER
 ──────                                              ──────
 sudo jaa-cluster join-code                          (installer, or: sudo jaa-cluster discover)
   Master:       192.168.1.10 (jaa-master-ab12)
   Join code:    k3x9qa.8hd02mf7s1pzq4ve   ──typed──▶  join code
   Fingerprint:  3f9a 1c2b 7d4e 9a01       ◀─compare─  "Master fingerprint: 3f9a 1c2b 7d4e 9a01 — match?"

 sudo jaa-cluster announce   ── mDNS: _jaa-rke2._tcp, address + fingerprint (no secret) ──▶ list of masters
```

1. **Discovery (address).** `jaa-cluster announce` advertises the master over mDNS (Avahi)
   as `_jaa-rke2._tcp` for 30 minutes (`--minutes N`), with its fingerprint in the TXT record.
   Workers list announcing masters with `jaa-cluster discover`; the installer shows that list.
   Avahi is **disabled at boot** and runs only during announce/discover, so jaaOS is not
   advertising itself on the network the rest of the time. mDNS does not cross routers: across
   subnets, type the master's address.
2. **Join code (secret).** `jaa-cluster join-code` creates a Kubernetes *bootstrap token*
   (`rke2 token create`): 23 characters (`abcdef.0123456789abcdef`), easy to type, and expiring
   (default 2 h, `--ttl`). It is never broadcast. The permanent cluster token stays on the
   master (`jaa-cluster token` prints it if you really need it).
3. **Fingerprint (trust).** The worker downloads the master's cluster CA
   (`https://master:9345/cacerts`) and shows the first 16 hex digits of its SHA-256. You compare
   them with the master's screen, like pairing a Bluetooth device. The worker then joins with
   `K10<CA hash>::<join code>`: RKE2 itself refuses any server whose CA does not match that hash.
   So a fake "master" answering discovery cannot capture the join or take over the worker.
4. **Firewall.** Cluster ports open only to the LAN subnet(s) the node is directly connected
   to (detected at setup; change with `jaa-cluster firewall --cidr 10.0.0.0/8`), plus the pod
   and overlay interfaces. The rules live in their own chains (`jaa_cluster_in` /
   `jaa_cluster_fwd`), loaded from `/etc/nftables.d/jaa-cluster.nft`. Changing the role never
   flushes Docker's or Kubernetes' own tables.

| Port | Proto | Opened on | From | For |
|---|---|---|---|---|
| 9345 | tcp | master | LAN | workers register (RKE2 supervisor) |
| 6443 | tcp | master | LAN | Kubernetes API (kubectl, workers) |
| 2379–2381 | tcp | master | LAN | etcd between masters (HA) |
| 10250 | tcp | all | LAN | kubelet |
| 8472 | udp | all | LAN | canal VXLAN overlay |
| 30000–32767 | tcp | all | LAN | NodePort services |
| 5353 | udp | all | LAN | mDNS while announce/discover runs |

Recommendations:
- Give the master a **fixed address** (DHCP reservation or static IP): workers store it.
- On machines with **more than one network card**, tell RKE2 which address faces the cluster:
  `sudo jaa-cluster setup master --node-ip 192.168.1.10` (and `--node-ip` on `join` for workers).
  Otherwise RKE2 uses the address of the default route. The master also pins canal's VXLAN
  overlay (flannel) to "the NIC whose address is in the cluster LAN" on every node. Without
  that, flannel picks the default-route NIC and pods on different nodes cannot reach each other.
- For **HA**, add two more masters: `sudo jaa-cluster setup master --server <first-master> --token <its permanent token>`.
- Use `sudo jaa-cluster kubeconfig` to get `kubectl` access as your own user (cluster-admin;
  keep it private). Root shells get `KUBECONFIG` automatically.

## What `jaa-cluster setup master|worker` changes

- `/etc/rancher/rke2/config.yaml` (0600): node name, token, `server:` (worker), and `cni: canal` +
  `tls-san: <name>, <name>.local` (master). Re-running keeps the existing cluster secret.
- `/etc/nftables.d/jaa-cluster.nft`: the firewall rules above.
- Master only: `/var/lib/rancher/rke2/server/manifests/jaa-canal-iface.yaml`, a `HelmChartConfig`
  that sets canal's `flannel.regexIface` to an IP regex of the cluster LAN subnet(s).
- `/etc/sysctl.d/90-jaa-cluster.conf` (`ip_forward`, `bridge-nf-call-iptables`, inotify
  limits), `/etc/modules-load.d/jaa-cluster.conf` (`br_netfilter`, `overlay`).
- `/etc/NetworkManager/conf.d/90-jaa-rke2.conf`: NetworkManager ignores `cali*`/`flannel*`.
- **zram swap is disabled** (the kubelet refuses to run with swap on). The original config is kept
  as `zram-generator.conf.jaa-orig`; `setup none` restores it and removes the other files.
- Hostname, `/etc/jaa/cluster.conf` (role, name, LAN, master), and enables `rke2-server` or
  `rke2-agent`.

## Docker

Docker is **socket-activated**: nothing runs at boot, and the first `docker` command starts
it. The base firewall allows forwarding from Docker bridges and DNATed traffic. As on any
Docker host, `docker run -p` makes a port reachable from the network, because Docker DNATs
it past the input chain. Membership of the `docker` group is equivalent to root, so jaaOS
does not add anyone to it. Use `sudo docker`, or add yourself deliberately.

## Live ISO

The live system has everything above, so you can try a master or worker without installing
(`sudo jaa-cluster setup master`). Its container storage (`/var/lib/{docker,containerd,rancher,kubelet}`)
is in RAM, because container filesystems cannot sit on the live overlay. Each of those tmpfs mounts
gets half the RAM by default, and RKE2's images alone take ~2 GB. Use **≥8 GB RAM for a live
master or worker** (with 4 GB, the test worker hit `DiskPressure` and evicted pods). Expect
everything to be gone after a reboot. For real use, install to disk.

By default nodes pull RKE2's system images from the internet on first start. Build the ISO with
`AIRGAP=1` to bundle them (~800 MB more); `jaa-cluster setup` then puts them where RKE2 loads them.

## Tests

- `tests/vm/cluster-test.sh` (in `make test`, no root, 64 checks): config, firewall, host tuning
  and service actions for each role. It also checks refusal of hostile input (YAML/nft injection,
  bad CIDRs, names, tokens, node IPs) and the flannel interface regex (matches in-range addresses,
  rejects others, valid YAML). The generated firewall rules pass `nft -c` against the base
  ruleset for all three roles.
- **Two QEMU VMs booted from the ISO on a shared virtual LAN**, each with a second NAT NIC
  (software emulation, Haswell CPU model). Verified on the unmodified ISO:
  - Master `setup master --node-ip …` → node Ready.
  - `join-code` printed the LAN address and fingerprint, and `announce` ran.
  - The worker's `discover` found the master over mDNS through both firewalls.
  - `jaa-cluster fingerprint` (as a normal user) matched, and a wrong fingerprint was refused.
  - `join` succeeded under a unique `jaa-worker-<mac>` name.
  - **Both nodes Ready, and canal 2/2 on both.**
- Single VM: Docker started on demand (overlay2 on the live tmpfs) and ran `hello-world`. The
  shell shortcuts, `jaa-keys`, motd and firewall forwarding were checked. No failed units.

This testing found and fixed five bugs:
1. **The serious one:** the `nft` 1.1.1 inside RKE2's Calico container segfaults when it reads
   *any* named nftables set created by Debian's `nft` 1.1.3. The old `jaa_tcp_open` port set
   therefore stopped Calico from programming its rules, and pod networking never became ready.
   `jaa_tcp_open` is now a chain of plain rules (same name, same behaviour for `jaa-host` and
   `jaa apply`). jaaOS's own ruleset must not use named sets.
2. The fingerprint was computed over the CA with its trailing newline stripped, so every
   legitimate join would have been refused.
3. `join-code` printed the default-route address instead of the cluster `--node-ip`.
4. `jaa-cluster` was not on a normal user's PATH.
5. **Multi-NIC nodes:** flannel put the VXLAN tunnel on the default-route NIC, so a pod on the
   worker could not reach CoreDNS on the master. The firewall dropped nothing; the tunnel was
   simply on the wrong NIC. Fixed by the master's `jaa-canal-iface.yaml` (see above).

## Limits (honest)

- **Cross-node pod traffic has not been seen working yet.** The flannel-interface fix (bug 5) is
  covered by the sandbox tests, and the API server accepted it in the VM. But the emulated
  master's control plane was too CPU-starved (load ~40, controller-manager crash-looping) to
  re-run the canal install that applies it. Verify on real hardware or KVM, as root on the
  master (it runs a lookup from a pod on the first worker):

  ```bash
  W=$(kubectl get nodes --no-headers | awk '$3 !~ /control-plane/ {print $1; exit}'); kubectl run dnstest --rm -i --restart=Never --image=busybox:1.36 --overrides="{\"spec\":{\"nodeName\":\"$W\"}}" -- nslookup kubernetes.default.svc.cluster.local
  ```

  Single-NIC machines (the normal case) never needed the fix.
- Tested in emulated VMs only, not on real hardware. **The installer's role step has not been
  run end to end** (it needs a real or virtual disk install; the same `jaa-cluster` code it
  calls is what the VM tests exercised).
- Under emulation, the canal network pod needs a CPU model with modern instructions: it crashes
  with SIGILL on QEMU's default `qemu64`. Real x86-64 CPUs from the last decade are fine.
- Bootstrap join codes expire. RKE2/k3s document that a node which joined with one keeps working
  after it expires, but jaaOS has not verified that for itself yet. If a worker cannot restart
  after the code expired, rejoin it with a fresh code, or use a longer `--ttl`.
- The fingerprint check is only as good as the comparison you make: 16 hex digits = 64 bits.
- mDNS announcements reveal the master's hostname and address to the LAN while announce runs.
- RKE2 is an upstream binary (not from Debian). Its updates come from bumping `build/rke2.lock`,
  not from `apt`.
