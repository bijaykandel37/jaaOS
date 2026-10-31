#!/usr/bin/env bash
# BastionOS Phase 5 test: validate the monitoring stack's shipped config and the bastion-health
# CLI in a sandbox (no root, no running services). It checks:
#   - every config parses (YAML via python3, JSON via jq),
#   - the Prometheus scrape config consumes the Phase-4 bastion-host file_sd targets,
#   - bastion-health discovers a target that bastion-host actually wrote (end-to-end handoff),
#   - bastion-security-metrics emits valid Prometheus text,
#   - the deniability guard (Alloy drops the dual-env auth path) is present.
# Live scrape/reload/eBPF behaviour needs a real host with the services — see docs/06.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RC="$REPO/config/rootfs/etc"
HEALTH="$REPO/packages/bastion-health/bin/bastion-health"
SECMET="$REPO/packages/bastion-health/bin/bastion-security-metrics"
HOST="$REPO/packages/bastion-host/bin/bastion-host"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
no() { echo "FAIL  $1"; fail=$((fail + 1)); }
yaml_ok() { python3 -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "$1" 2>/dev/null; }
json_ok() { jq -e . "$1" >/dev/null 2>&1; }
has() { grep -qF "$2" "$1" 2>/dev/null; }

command -v python3 >/dev/null || { echo "python3 required"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "python3 pyyaml required"; exit 2; }
command -v jq >/dev/null || { echo "jq required"; exit 2; }

echo "== YAML configs parse =="
for f in prometheus/prometheus.yml prometheus/rules/bastion-alerts.yml alertmanager/alertmanager.yml \
         loki/config.yml grafana/provisioning/datasources/bastion.yml \
         grafana/provisioning/dashboards/bastion.yml falco/config.d/bastion.yaml falco/rules.d/bastion.yaml; do
	yaml_ok "$RC/$f" && ok "yaml: $f" || no "yaml: $f"
done

echo "== JSON dashboards parse + have panels =="
for d in bastion-overview bastion-security; do
	f="$RC/grafana/dashboards/$d.json"
	json_ok "$f" && ok "json: $d" || no "json: $d"
	[ "$(jq '.panels | length' "$f" 2>/dev/null)" -ge 1 ] && ok "$d has panels" || no "$d has panels"
	[ "$(jq -r .uid "$f" 2>/dev/null)" = "$d" ] && ok "$d uid matches" || no "$d uid matches"
done

echo "== Prometheus consumes bastion-host file_sd =="
has "$RC/prometheus/prometheus.yml" "/etc/bastion/monitoring/targets.d/*.json" \
	&& ok "scrape config references targets.d" || no "scrape config references targets.d"
python3 - "$RC/prometheus/prometheus.yml" <<'PY' && ok "node+bastion-host jobs present" || no "node+bastion-host jobs present"
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
jobs = {j["job_name"] for j in c["scrape_configs"]}
sys.exit(0 if {"node", "bastion-host", "prometheus"} <= jobs else 1)
PY

echo "== alert rules well-formed + expected alerts present =="
python3 - "$RC/prometheus/rules/bastion-alerts.yml" <<'PY' && ok "alert rules structure" || no "alert rules structure"
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
names = {r.get("alert") for g in c["groups"] for r in g["rules"] if r.get("alert")}
need = {"TargetDown","DiskSpaceCritical","AuditdDown","AideChangesDetected","FalcoEvents"}
sys.exit(0 if need <= names else 1)
PY

echo "== deniability guard: Alloy drops the dual-env auth path =="
a="$RC/alloy/config.alloy"
{ has "$a" 'action        = "drop"' && has "$a" "bastion-env"; } \
	&& ok "alloy drops bastion-env identifiers" || no "alloy drops bastion-env identifiers"
# No dashboard/rule may contain an env-enumerating metric or label.
if grep -REn 'bastion_env_(count|list)|environments?"\s*:|hidden_env' \
	"$RC/prometheus" "$RC/grafana/dashboards" >/dev/null 2>&1; then
	no "no env-enumerating metric/label in metrics configs"
else
	ok "no env-enumerating metric/label in metrics configs"
fi

echo "== bastion-security-metrics emits valid Prometheus text =="
OUT="$SBX/sec.prom"
BASTION_SECMETRICS_OUT="$OUT" BASTION_AIDE_LOG_DIR="$SBX/noaide" BASTION_FALCO_LOG="$SBX/nofalco" \
	bash "$SECMET" >/dev/null 2>&1
[ -f "$OUT" ] && ok "security metrics file written" || no "security metrics file written"
has "$OUT" "bastion_auditd_up" && ok "auditd metric present" || no "auditd metric present"
has "$OUT" "bastion_security_metrics_last_run_timestamp_seconds" && ok "heartbeat metric present" || no "heartbeat metric present"
# Every non-comment, non-blank line must look like a Prometheus sample.
if awk 'NF==0||/^#/{next} !/^[a-zA-Z_][a-zA-Z0-9_]*(\{[^}]*\})?[ \t]+-?[0-9]/{bad=1} END{exit bad}' "$OUT"; then
	ok "prom text format valid"
else
	no "prom text format valid"
fi

echo "== end-to-end: bastion-host writes a target, bastion-health discovers it =="
export BASTION_HOST_PREFIX="$SBX"
bash "$HOST" site create demo.local --proxy http://127.0.0.1:3000 >/dev/null 2>&1
BASTION_HEALTH_PREFIX="$SBX" BASTION_HEALTH_PROM="http://127.0.0.1:1" \
	bash "$HEALTH" targets 2>/dev/null | grep -q "site-demo.local" \
	&& ok "bastion-health targets lists the bastion-host site" \
	|| no "bastion-health targets lists the bastion-host site"

echo "== bastion-health status runs and leaks no environment info =="
st="$(BASTION_HEALTH_PREFIX="$SBX" BASTION_HEALTH_PROM="http://127.0.0.1:1" bash "$HEALTH" status 2>/dev/null)"
printf '%s' "$st" | grep -q "BastionOS health" && ok "status renders" || no "status renders"
if printf '%s' "$st" | grep -qiE 'shufflecake|hidden|second (home|environment)|dual-env'; then
	no "status reveals no environment info"
else
	ok "status reveals no environment info"
fi

echo "== bastion-health check runs (threshold tool) =="
ck="$(BASTION_HEALTH_PREFIX="$SBX" bash "$HEALTH" check 2>/dev/null)"
printf '%s' "$ck" | grep -qE '^(OK|FAIL|WARN)' \
	&& ok "check emits status lines" || no "check emits status lines"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
