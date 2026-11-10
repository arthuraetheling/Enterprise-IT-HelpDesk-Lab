#!/usr/bin/env bash
#
# linux_health_check.sh - health check for MON01 (Ubuntu 24.04 + Docker + Zabbix).
#
#   ./linux_health_check.sh          human-readable report
#   ./linux_health_check.sh --json   JSON for automation
#
# Checks: root and Docker disk space, memory, load vs CPU count, failed systemd units, Docker containers,
#         Zabbix web UI, DNS resolution of the domain controller, NTP sync, pending reboot, pending updates.
# Exit codes: 0 = OK, 1 = warning, 2 = critical.

set -uo pipefail

JSON=0
[ "${1:-}" = "--json" ] && JSON=1
DC_NAME="${DC_NAME:-dc01.corp.contoso.internal}"
ZABBIX_URL="${ZABBIX_URL:-http://localhost/}"
WORST=0
CHECKS=()

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  '; }

record() {  # record <id> <check> <OK|WARN|CRIT|UNKNOWN> <value>
  local id="$1" check="$2" status="$3" value="$4"
  case "$status" in
    WARN) (( WORST < 1 )) && WORST=1 ;;
    CRIT) WORST=2 ;;
  esac
  (( JSON == 0 )) && printf '  %-9s %-22s %s\n' "[$status]" "$check" "$value"
  CHECKS+=("{\"Id\":\"$(json_escape "$id")\",\"Check\":\"$(json_escape "$check")\",\"Status\":\"$status\",\"Value\":\"$(json_escape "$value")\"}")
}

disk_check() {  # disk_check <id> <mount>
  local id="$1" mount="$2" line pct used avail
  [ -d "$mount" ] || return 0
  line=$(df -P -BG "$mount" | awk 'NR==2 {print $2, $4, $5}')
  read -r size avail pct <<<"$line"
  pct=${pct%\%}; avail=${avail%G}; size=${size%G}
  local free=$(( 100 - pct )) status=OK
  if (( free < 10 )); then status=CRIT; elif (( free < 15 )); then status=WARN; fi
  record "$id" "Disk $mount" "$status" "${free}% free (${avail} of ${size} GB)"
}

(( JSON == 0 )) && echo "" && echo "Linux health check - $(hostname) ($(. /etc/os-release && echo "$PRETTY_NAME"))" && echo ""

disk_check "Disk-root" "/"
disk_check "Disk-docker" "/var/lib/docker"

read -r mem_total mem_avail <<<"$(free -m | awk '/^Mem:/ {print $2, $7}')"
mem_free_pct=$(( mem_avail * 100 / mem_total ))
status=OK; (( mem_free_pct < 10 )) && status=CRIT || { (( mem_free_pct < 20 )) && status=WARN; }
record "Memory" "Memory" "$status" "${mem_free_pct}% available (${mem_avail} of ${mem_total} MB)"

cpus=$(nproc)
load5=$(awk '{print $2}' /proc/loadavg)
status=OK
if awk -v l="$load5" -v c="$cpus" 'BEGIN { exit !(l > c * 1.5) }'; then status=CRIT
elif awk -v l="$load5" -v c="$cpus" 'BEGIN { exit !(l > c) }'; then status=WARN; fi
record "Load" "Load (5 min)" "$status" "$load5 on $cpus CPU(s)"

failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [ -n "${failed// /}" ]; then record "Systemd" "Failed units" "WARN" "$failed"
else record "Systemd" "Failed units" "OK" "none"; fi

if command -v docker >/dev/null 2>&1; then
  if down=$(docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null); then
    bad=$(printf '%s\n' "$down" | awk 'NF && $2 != "Up" {print $1}' | tr '\n' ' ')
    total=$(printf '%s\n' "$down" | awk 'NF' | wc -l)
    if [ -n "${bad// /}" ]; then record "Docker" "Containers" "CRIT" "not running: $bad"
    else record "Docker" "Containers" "OK" "$total container(s) up"; fi
  else
    record "Docker" "Containers" "UNKNOWN" "cannot query Docker (add user to the docker group or use sudo)"
  fi
fi

code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$ZABBIX_URL" || true)
if [[ "$code" =~ ^(200|301|302)$ ]]; then record "Zabbix" "Zabbix web UI" "OK" "HTTP $code at $ZABBIX_URL"
else record "Zabbix" "Zabbix web UI" "CRIT" "HTTP ${code:-000} at $ZABBIX_URL"; fi

if addr=$(getent hosts "$DC_NAME" | awk '{print $1; exit}') && [ -n "$addr" ]; then
  record "DNS" "Resolve $DC_NAME" "OK" "$addr"
else
  record "DNS" "Resolve $DC_NAME" "WARN" "failed - check /etc/netplan nameservers (10.10.10.10)"
fi

synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)
if [ "$synced" = "yes" ]; then record "Time" "NTP synchronized" "OK" "yes"
else record "Time" "NTP synchronized" "WARN" "$synced (Zabbix timestamps and TLS depend on time)"; fi

if [ -f /var/run/reboot-required ]; then record "Reboot" "Pending reboot" "WARN" "yes ($(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null))"
else record "Reboot" "Pending reboot" "OK" "no"; fi

if command -v apt >/dev/null 2>&1; then
  upd=$(apt list --upgradable 2>/dev/null | grep -c 'upgradable' || true)
  sec=$(apt list --upgradable 2>/dev/null | grep -c -- '-security' || true)
  status=OK; (( sec > 0 )) && status=WARN
  record "Updates" "Pending updates" "$status" "$upd upgradable ($sec security)"
fi

case "$WORST" in 0) overall=OK ;; 1) overall=Warning ;; *) overall=Critical ;; esac
if (( JSON == 1 )); then
  joined=$(IFS=,; echo "${CHECKS[*]}")
  printf '{"SchemaVersion":1,"ComputerName":"%s","CollectedAt":"%s","Overall":"%s","ExitCode":%s,"Checks":[%s]}\n' \
    "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$overall" "$WORST" "$joined"
else
  echo ""; echo "Overall: $overall (exit code $WORST)"
fi
exit "$WORST"
