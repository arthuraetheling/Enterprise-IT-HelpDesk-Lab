#!/bin/bash
#
# macos_health_check.sh - Tier 1/Tier 2 health and compliance snapshot for a managed Mac (KB0015, KB0016).
#
# Written for the bash 3.2 that ships with macOS (no associative arrays, no ${var,,}).
# Read-only. Some checks (MDM enrollment detail, network time) are more complete with sudo.
#
#   ./macos_health_check.sh              human-readable report
#   sudo ./macos_health_check.sh --json  JSON with inventory fields (ComputerName, SerialNumber, OS, ...)
#                                        that python/cmdb_reconcile.py understands
#   --check-updates                      also run `softwareupdate -l` (slow, needs network)
#
# Exit codes: 0 = OK, 1 = warning, 2 = critical (same contract as Get-EndpointHealth.ps1)

set -u

JSON=0
CHECK_UPDATES=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --check-updates) CHECK_UPDATES=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script runs on macOS only." >&2
  exit 64
fi

# Thresholds (match docs/01-lab-design.md section 9)
DISK_WARN_PCT=15; DISK_WARN_GB=25; DISK_CRIT_PCT=10; DISK_CRIT_GB=10
MEM_WARN_FREE=20; MEM_CRIT_FREE=10
UPTIME_WARN_DAYS=14; UPTIME_CRIT_DAYS=30
BATTERY_WARN_CAPACITY=80

WORST=0
CHECKS_JSON=""

json_escape() {
  # escape backslash, double quote, tab and newline for JSON strings
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | tr '\n' ' '
}

record() {
  # record <id> <check> <OK|WARN|CRIT|INFO|UNKNOWN> <value>
  local id="$1" check="$2" status="$3" value="$4"
  case "$status" in
    WARN) [ "$WORST" -lt 1 ] && WORST=1 ;;
    CRIT) WORST=2 ;;
  esac
  if [ "$JSON" -eq 0 ]; then
    printf '  %-9s %-24s %s\n' "[$status]" "$check" "$value"
  fi
  local item
  item=$(printf '{"Id":"%s","Check":"%s","Status":"%s","Value":"%s"}' \
    "$(json_escape "$id")" "$(json_escape "$check")" "$status" "$(json_escape "$value")")
  if [ -z "$CHECKS_JSON" ]; then CHECKS_JSON="$item"; else CHECKS_JSON="$CHECKS_JSON,$item"; fi
}

# --- Inventory --------------------------------------------------------------------------------
HW=$(system_profiler SPHardwareDataType 2>/dev/null)
hw_field() { printf '%s\n' "$HW" | awk -F': ' -v k="$1" '$1 ~ k {print $2; exit}'; }
COMPUTER_NAME=$(scutil --get ComputerName 2>/dev/null || hostname -s)
MODEL_NAME=$(hw_field "Model Name")
MODEL_ID=$(hw_field "Model Identifier")
SERIAL=$(hw_field "Serial Number")
CHIP=$(hw_field "Chip")
[ -z "$CHIP" ] && CHIP=$(hw_field "Processor Name")
MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
MEM_GB=$(( MEM_BYTES / 1073741824 ))
OS_NAME=$(sw_vers -productName 2>/dev/null)
OS_VERSION=$(sw_vers -productVersion 2>/dev/null)
OS_BUILD=$(sw_vers -buildVersion 2>/dev/null)
CONSOLE_USER=$(stat -f %Su /dev/console 2>/dev/null)
COLLECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ "$JSON" -eq 0 ]; then
  echo ""
  echo "macOS health check - $COMPUTER_NAME"
  echo "  $MODEL_NAME ($MODEL_ID), $CHIP, ${MEM_GB} GB RAM, serial $SERIAL"
  echo "  $OS_NAME $OS_VERSION ($OS_BUILD), console user: $CONSOLE_USER, collected $COLLECTED_AT"
  echo ""
fi

# --- Disk (APFS data volume shares the container's free space) -----------------------------------
DATA_VOL="/System/Volumes/Data"
[ -d "$DATA_VOL" ] || DATA_VOL="/"
read -r DISK_TOTAL_K DISK_AVAIL_K <<EOF
$(df -k "$DATA_VOL" | awk 'NR==2 {print $2, $4}')
EOF
if [ -n "${DISK_TOTAL_K:-}" ] && [ "$DISK_TOTAL_K" -gt 0 ]; then
  FREE_PCT=$(( DISK_AVAIL_K * 100 / DISK_TOTAL_K ))
  FREE_GB=$(( DISK_AVAIL_K / 1048576 ))
  TOTAL_GB=$(( DISK_TOTAL_K / 1048576 ))
  STATUS=OK
  if [ "$FREE_PCT" -lt "$DISK_CRIT_PCT" ] && [ "$FREE_GB" -lt "$DISK_CRIT_GB" ]; then STATUS=CRIT
  elif [ "$FREE_PCT" -lt "$DISK_WARN_PCT" ] && [ "$FREE_GB" -lt "$DISK_WARN_GB" ]; then STATUS=WARN; fi
  record "Disk-Data" "Disk free" "$STATUS" "${FREE_PCT}% free (${FREE_GB} of ${TOTAL_GB} GB)"
else
  record "Disk-Data" "Disk free" "UNKNOWN" "df returned no data"
fi

# --- Memory pressure ------------------------------------------------------------------------------
MEM_FREE=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/ {gsub("%","",$2); print $2}')
if [ -n "$MEM_FREE" ]; then
  STATUS=OK
  if [ "$MEM_FREE" -lt "$MEM_CRIT_FREE" ]; then STATUS=CRIT; elif [ "$MEM_FREE" -lt "$MEM_WARN_FREE" ]; then STATUS=WARN; fi
  record "Memory" "Memory" "$STATUS" "${MEM_FREE}% free (system-wide memory pressure)"
else
  record "Memory" "Memory" "UNKNOWN" "memory_pressure unavailable"
fi

# --- Uptime --------------------------------------------------------------------------------------
BOOT_SEC=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
NOW_SEC=$(date +%s)
if [ -n "$BOOT_SEC" ]; then
  UP_DAYS=$(( (NOW_SEC - BOOT_SEC) / 86400 ))
  STATUS=OK
  if [ "$UP_DAYS" -gt "$UPTIME_CRIT_DAYS" ]; then STATUS=CRIT; elif [ "$UP_DAYS" -gt "$UPTIME_WARN_DAYS" ]; then STATUS=WARN; fi
  record "Uptime" "Uptime" "$STATUS" "${UP_DAYS} day(s) since last restart"
fi

# --- Security posture -------------------------------------------------------------------------------
FV=$(fdesetup status 2>/dev/null | head -n 1)
case "$FV" in
  *"FileVault is On"*) record "FileVault" "FileVault" "OK" "On"; FILEVAULT="On" ;;
  *"Encryption in progress"*) record "FileVault" "FileVault" "WARN" "$FV"; FILEVAULT="Encrypting" ;;
  *"FileVault is Off"*) record "FileVault" "FileVault" "CRIT" "Off - disk is not encrypted"; FILEVAULT="Off" ;;
  *) record "FileVault" "FileVault" "UNKNOWN" "${FV:-no output}"; FILEVAULT="Unknown" ;;
esac

SIP=$(csrutil status 2>/dev/null)
case "$SIP" in
  *enabled*) record "SIP" "System Integrity Prot." "OK" "Enabled" ;;
  *disabled*) record "SIP" "System Integrity Prot." "CRIT" "Disabled" ;;
  *) record "SIP" "System Integrity Prot." "UNKNOWN" "${SIP:-no output}" ;;
esac

GK=$(spctl --status 2>/dev/null)
case "$GK" in
  *"assessments enabled"*) record "Gatekeeper" "Gatekeeper" "OK" "Enabled" ;;
  *) record "Gatekeeper" "Gatekeeper" "WARN" "${GK:-unknown}" ;;
esac

FW=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
case "$FW" in
  *"enabled"*) record "Firewall" "Application firewall" "OK" "Enabled" ;;
  *"disabled"*) record "Firewall" "Application firewall" "WARN" "Disabled" ;;
  *) record "Firewall" "Application firewall" "UNKNOWN" "${FW:-unknown}" ;;
esac

ENROLL=$(profiles status -type enrollment 2>/dev/null)
MDM_ENROLLED=false
if printf '%s' "$ENROLL" | grep -q "MDM enrollment: Yes"; then
  MDM_ENROLLED=true
  DEP=$(printf '%s\n' "$ENROLL" | awk -F': ' '/Enrolled via DEP/ {print $2}')
  record "MDM" "MDM enrollment" "OK" "Enrolled (ADE/DEP: ${DEP:-unknown})"
elif [ -n "$ENROLL" ]; then
  record "MDM" "MDM enrollment" "CRIT" "Not enrolled - see KB0016"
else
  record "MDM" "MDM enrollment" "UNKNOWN" "Run with sudo for enrollment status"
fi

# --- Battery ---------------------------------------------------------------------------------------
PWR=$(system_profiler SPPowerDataType 2>/dev/null)
if printf '%s' "$PWR" | grep -q "Cycle Count"; then
  CYCLES=$(printf '%s\n' "$PWR" | awk -F': ' '/Cycle Count/ {print $2; exit}')
  COND=$(printf '%s\n' "$PWR" | awk -F': ' '/Condition/ {print $2; exit}')
  CAP=$(printf '%s\n' "$PWR" | awk -F': ' '/Maximum Capacity/ {gsub("%","",$2); print $2; exit}')
  STATUS=OK
  if [ -n "$CAP" ] && [ "$CAP" -lt "$BATTERY_WARN_CAPACITY" ]; then STATUS=WARN; fi
  case "$COND" in *Service*|*Replace*) STATUS=WARN ;; esac
  record "Battery" "Battery" "$STATUS" "condition ${COND:-n/a}, max capacity ${CAP:-n/a}%, ${CYCLES:-?} cycles"
fi

# --- Network ---------------------------------------------------------------------------------------
IFACE=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
if [ -n "$IFACE" ]; then
  IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null)
  DNS=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ {print $3}' | sort -u | tr '\n' ' ')
  case "$IP" in
    169.254.*) record "Network" "Network" "CRIT" "$IFACE has self-assigned $IP (DHCP failure - KB0005)" ;;
    "") record "Network" "Network" "WARN" "$IFACE has no IPv4 address" ;;
    *) record "Network" "Network" "OK" "$IFACE $IP, DNS ${DNS:-none}" ;;
  esac
  if nslookup -timeout=3 www.apple.com >/dev/null 2>&1; then
    record "DNS" "Name resolution" "OK" "www.apple.com resolves"
  else
    record "DNS" "Name resolution" "WARN" "External name lookup failed (KB0004)"
  fi
else
  record "Network" "Network" "WARN" "No default route - offline?"
fi

if [ "$(id -u)" -eq 0 ]; then
  NT=$(systemsetup -getusingnetworktime 2>/dev/null)
  case "$NT" in
    *On*) record "Time" "Network time" "OK" "Enabled" ;;
    *) record "Time" "Network time" "WARN" "${NT:-unknown} (Kerberos/SSO need accurate time - KB0010)" ;;
  esac
fi

# --- Updates (optional) --------------------------------------------------------------------------------
if [ "$CHECK_UPDATES" -eq 1 ]; then
  UPD=$(softwareupdate -l 2>&1)
  if printf '%s' "$UPD" | grep -q "No new software available"; then
    record "Updates" "Software updates" "OK" "Up to date"
  else
    COUNT=$(printf '%s\n' "$UPD" | grep -c '^\* Label:')
    record "Updates" "Software updates" "WARN" "${COUNT} update(s) available"
  fi
fi

# --- Output ----------------------------------------------------------------------------------------
case "$WORST" in 0) OVERALL=OK ;; 1) OVERALL=Warning ;; *) OVERALL=Critical ;; esac

if [ "$JSON" -eq 1 ]; then
  printf '{"SchemaVersion":1,"Source":"macos_health_check.sh","CollectedAt":"%s","ComputerName":"%s","SerialNumber":"%s",' \
    "$COLLECTED_AT" "$(json_escape "$COMPUTER_NAME")" "$(json_escape "$SERIAL")"
  printf '"Manufacturer":"Apple Inc.","Model":"%s","ModelIdentifier":"%s","Cpu":{"Name":"%s"},"MemoryGB":%s,' \
    "$(json_escape "$MODEL_NAME")" "$(json_escape "$MODEL_ID")" "$(json_escape "$CHIP")" "$MEM_GB"
  printf '"OS":{"Name":"%s","DisplayVersion":"%s","Build":"%s"},"LoggedOnUser":"%s","MdmEnrolled":%s,"FileVault":"%s",' \
    "$(json_escape "$OS_NAME")" "$(json_escape "$OS_VERSION")" "$(json_escape "$OS_BUILD")" "$(json_escape "$CONSOLE_USER")" "$MDM_ENROLLED" "$FILEVAULT"
  printf '"Overall":"%s","ExitCode":%s,"Checks":[%s]}\n' "$OVERALL" "$WORST" "$CHECKS_JSON"
else
  echo ""
  echo "Overall: $OVERALL (exit code $WORST)"
  [ "$(id -u)" -ne 0 ] && echo "Tip: run with sudo for MDM and network-time detail."
fi
exit "$WORST"
