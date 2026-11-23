// jaaOS netmap dashboard. Reads data.json (written by `jaa-net serve`) and renders the network.
// No framework, no external calls. All values from the scan are escaped before they hit the DOM.
"use strict";
const $ = (s, r = document) => r.querySelector(s);
const el = (t, c, txt) => { const n = document.createElement(t); if (c) n.className = c; if (txt != null) n.textContent = txt; return n; };
const SECURE = new Set([22, 443, 853, 993, 995]); // ports that are not plaintext

let DATA = { devices: [], counts: {}, left: [] };
let FILTER = "";

function fmtAge(sec) {
  if (!sec) return "—";
  const d = Math.max(0, Math.floor(Date.now() / 1000) - sec);
  if (d < 60) return d + "s ago";
  if (d < 3600) return Math.floor(d / 60) + "m ago";
  if (d < 86400) return Math.floor(d / 3600) + "h ago";
  return Math.floor(d / 86400) + "d ago";
}
function role(d) { return d.is_gateway ? "gateway" : d.is_self ? "this phone" : d.status === "new" ? "new" : ""; }
function cls(d) { return d.is_gateway ? "gw" : d.is_self ? "me" : d.status === "new" ? "new" : ""; }

function matches(d, q) {
  if (!q) return true;
  const hay = [d.ip, d.mac, d.vendor, d.hostname, ...(d.open_ports || []).map(p => p.port + " " + p.service)].join(" ").toLowerCase();
  return hay.includes(q);
}

function renderStats() {
  const c = DATA.counts || {};
  const items = [
    ["devices", c.total || 0, ""],
    ["new this scan", c.new || 0, c.new ? "warn" : "good"],
    ["left", c.left || 0, c.left ? "bad" : ""],
    ["exposing ports", c.with_open_ports || 0, c.with_open_ports ? "warn" : "good"],
  ];
  const box = $("#stats"); box.innerHTML = "";
  for (const [k, v, kind] of items) {
    const s = el("div", "stat" + (kind ? " " + kind : ""));
    s.append(el("div", "k", k), el("div", "v", String(v)));
    box.append(s);
  }
}

function card(d) {
  const c = el("div", "card " + cls(d));
  const r1 = el("div", "row1");
  r1.append(el("span", "ip", d.ip || "?"));
  const rl = role(d); if (rl) r1.append(el("span", "role", rl));
  c.append(r1);
  c.append(el("div", "host", d.hostname || " "));
  const mac = el("div", "mac");
  mac.append(el("span", "vend", d.vendor || "unknown vendor"));
  if (d.mac) mac.append(document.createTextNode("  ·  " + d.mac));
  c.append(mac);
  if ((d.open_ports || []).length) {
    const ps = el("div", "ports");
    for (const p of d.open_ports) {
      const tag = el("span", "port" + (SECURE.has(p.port) ? " secure" : ""), p.port + (p.service ? "/" + p.service : ""));
      ps.append(tag);
    }
    c.append(ps);
  }
  c.addEventListener("click", () => openSheet(d));
  return c;
}

function render() {
  renderStats();
  const grid = $("#grid"); grid.innerHTML = "";
  const list = DATA.devices.filter(d => matches(d, FILTER));
  $("#empty").hidden = list.length > 0;
  for (const d of list) grid.append(card(d));
  const n = DATA;
  $("#netinfo").innerHTML = n.ssid ? `net <b>${esc(n.ssid)}</b> · gw <b>${esc(n.gateway || "?")}</b>` : "no network";
  $("#foottime").textContent = "last scan " + fmtAge(n.generated) + (n.self ? "  ·  me " + n.self : "");
}

function esc(s) { const d = document.createElement("div"); d.textContent = s == null ? "" : s; return d.innerHTML; }

function openSheet(d) {
  const b = $("#sheetbody"); b.innerHTML = "";
  b.append(el("h2", null, d.hostname || d.ip));
  const kv = el("dl", "kv");
  const rows = [["ip", d.ip], ["mac", d.mac || "unknown"], ["vendor", d.vendor || "unknown"],
    ["role", role(d) || "client"], ["first seen", fmtAge(d.first_seen)], ["last seen", fmtAge(d.last_seen)]];
  for (const [k, v] of rows) { kv.append(el("dt", null, k), el("dd", null, String(v))); }
  b.append(kv);
  if ((d.open_ports || []).length) {
    b.append(el("div", "k", "open ports / services"));
    const pl = el("div", "portlist");
    for (const p of d.open_ports) {
      const row = el("div", "pl");
      row.append(el("span", "pn", p.port + "/" + p.proto), el("span", "ps", p.service || "?"));
      if (p.product) row.append(el("span", "pp", p.product));
      pl.append(row);
    }
    b.append(pl);
  } else {
    b.append(el("p", "dim", "no open TCP ports found in the fast scan."));
  }
  if (!d.is_self) {
    const note = el("div", "blocknote");
    note.innerHTML = `<b>Block this device</b> the administrator way — through your router, not by attacking it.
      Open <b>http://${esc(DATA.gateway || "your-router")}</b> → Access control / MAC filtering, and block:
      <span class="cmd">${esc(d.mac || "(unknown MAC — read it from the router)")}</span>
      On the phone you can also run: <span class="cmd">jaa-net block ${esc(d.ip)}</span>`;
    b.append(note);
  }
  $("#sheet").hidden = false;
}

async function tick() {
  try {
    const r = await fetch("data.json?_=" + Date.now(), { cache: "no-store" });
    if (!r.ok) throw new Error(r.status);
    DATA = await r.json();
    $("#livetxt").textContent = "live";
    $("#livedot").style.background = "var(--accent)";
    render();
  } catch (e) {
    $("#livetxt").textContent = "offline";
    $("#livedot").style.background = "var(--bad)";
  }
}

$("#filter").addEventListener("input", e => { FILTER = e.target.value.trim().toLowerCase(); render(); });
$("#sheetclose").addEventListener("click", () => { $("#sheet").hidden = true; });
$("#sheet").addEventListener("click", e => { if (e.target.id === "sheet") $("#sheet").hidden = true; });
document.addEventListener("keydown", e => { if (e.key === "Escape") $("#sheet").hidden = true; });

tick();
setInterval(tick, 5000);
