#!/usr/bin/env python3
# jaa-net-scan.py — turn an nmap -sn/-sV XML scan + the ARP table + an OUI table into the JSON the
# jaaOS network dashboard reads. Pure parsing: it opens no sockets and runs nothing. Run with -I.
#
#   jaa-net-scan.py --xml scan.xml --neigh neigh.txt --oui nmap-mac-prefixes \
#       --self 192.168.1.50 --gateway 192.168.1.1 --ssid MyWiFi --baseline base.json
#
# Emits one JSON object: {generated, ssid, gateway, self, counts, devices:[...]}.
# A device: {ip, mac, vendor, hostname, is_gateway, is_self, status(new|known|returned),
#            first_seen, last_seen, open_ports:[{port, proto, service, product}]}.
import argparse
import html
import ipaddress
import json
import os
import re
import sys
import time
import xml.etree.ElementTree as ET


def load_oui(path):
    table = {}
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) == 2 and re.fullmatch(r"[0-9A-Fa-f]{6}", parts[0]):
                table[parts[0].upper()] = parts[1].strip()
    return table


def vendor_for(mac, oui):
    if not mac:
        return ""
    prefix = mac.upper().replace(":", "")[:6]
    return oui.get(prefix, "")


def load_neigh(path):
    # `ip neigh` lines: "192.168.1.1 dev wlan0 lladdr aa:bb:cc:dd:ee:ff REACHABLE"
    macs = {}
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            m = re.match(r"(\d+\.\d+\.\d+\.\d+).*lladdr ([0-9a-fA-F:]{17})", line)
            if m:
                macs[m.group(1)] = m.group(2).lower()
    return macs


def parse_nmap(path):
    hosts = {}
    if not path or not os.path.exists(path):
        return hosts
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return hosts
    for h in root.findall("host"):
        st = h.find("status")
        if st is not None and st.get("state") != "up":
            continue
        ip = mac = vendor = hostname = ""
        for a in h.findall("address"):
            t = a.get("addrtype")
            if t == "ipv4":
                ip = a.get("addr", "")
            elif t == "mac":
                mac = (a.get("addr") or "").lower()
                vendor = a.get("vendor", "") or ""
        hn = h.find("hostnames/hostname")
        if hn is not None:
            hostname = hn.get("name", "")
        ports = []
        for p in h.findall("ports/port"):
            state = p.find("state")
            if state is None or state.get("state") != "open":
                continue
            svc = p.find("service")
            ports.append({
                "port": int(p.get("portid")),
                "proto": p.get("protocol", "tcp"),
                "service": (svc.get("name") if svc is not None else "") or "",
                "product": (svc.get("product") if svc is not None else "") or "",
            })
        if ip:
            hosts[ip] = {"ip": ip, "mac": mac, "vendor": vendor, "hostname": hostname,
                         "open_ports": sorted(ports, key=lambda x: x["port"])}
    return hosts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--xml"); ap.add_argument("--neigh"); ap.add_argument("--oui")
    ap.add_argument("--self", default=""); ap.add_argument("--gateway", default="")
    ap.add_argument("--ssid", default=""); ap.add_argument("--baseline")
    a = ap.parse_args()

    now = int(time.time())
    oui = load_oui(a.oui)
    neigh = load_neigh(a.neigh)
    hosts = parse_nmap(a.xml)

    # The ARP table may know devices nmap did not annotate with a MAC (common without root).
    for ip, mac in neigh.items():
        hosts.setdefault(ip, {"ip": ip, "mac": "", "vendor": "", "hostname": "", "open_ports": []})
        if not hosts[ip].get("mac"):
            hosts[ip]["mac"] = mac
    # Make sure self + gateway appear even if the scan missed them.
    for ip in (a.self, a.gateway):
        if ip:
            hosts.setdefault(ip, {"ip": ip, "mac": neigh.get(ip, ""), "vendor": "", "hostname": "", "open_ports": []})

    base_list = []
    if a.baseline and os.path.exists(a.baseline):
        try:
            base_list = json.load(open(a.baseline)).get("devices", [])
        except (ValueError, OSError):
            base_list = []
    # Index the baseline by BOTH mac and ip. Unrooted scans often miss the MAC, so a device may
    # be known by mac one scan and only by ip the next; matching on either keeps it as the same
    # device instead of reporting a false "left + joined".
    base_by_mac = {d["mac"]: d for d in base_list if d.get("mac")}
    base_by_ip = {d["ip"]: d for d in base_list if d.get("ip")}

    devices = []
    cur_macs, cur_ips = set(), set()
    for ip, d in hosts.items():
        if not d.get("vendor"):
            d["vendor"] = vendor_for(d.get("mac", ""), oui)
        d["hostname"] = html.unescape(d.get("hostname", ""))
        d["is_gateway"] = (ip == a.gateway)
        d["is_self"] = (ip == a.self)
        mac = d.get("mac", "")
        prev = (base_by_mac.get(mac) if mac else None) or base_by_ip.get(ip)
        if prev is None:
            d["status"] = "new"; d["first_seen"] = now
        else:
            d["first_seen"] = prev.get("first_seen", now)
            d["status"] = "known"
            # Carry ports forward from a heavier earlier scan, so a light host-discovery refresh
            # (jaa-net serve/watch) does not blank a known device's open ports.
            if not d.get("open_ports") and prev.get("open_ports"):
                d["open_ports"] = prev["open_ports"]
        d["last_seen"] = now
        if mac:
            cur_macs.add(mac)
        cur_ips.add(ip)
        devices.append(d)

    # A baseline device has left only if NEITHER its mac nor its ip is seen now.
    left = [d for d in base_list
            if not ((d.get("mac") and d["mac"] in cur_macs) or (d.get("ip") and d["ip"] in cur_ips))]

    def sort_key(d):
        try:
            return (0 if d["is_gateway"] else 1, int(ipaddress.ip_address(d["ip"])))
        except ValueError:
            return (2, 0)
    devices.sort(key=sort_key)

    out = {
        "generated": now, "ssid": a.ssid, "gateway": a.gateway, "self": a.self,
        "counts": {
            "total": len(devices),
            "new": sum(1 for d in devices if d["status"] == "new"),
            "left": len(left),
            "with_open_ports": sum(1 for d in devices if d["open_ports"]),
        },
        "devices": devices,
        "left": left,
    }
    json.dump(out, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
