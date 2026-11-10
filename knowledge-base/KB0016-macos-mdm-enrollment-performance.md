# KB0016 · macOS MDM enrollment / configuration profiles and slow-Mac triage

| Field | Value |
|---|---|
| KB ID | KB0016 |
| Applies to | Company Macs (`LT-MAC-###`) on macOS 14 or later, enrolled in MDM (Automated Device Enrollment for company-owned Macs) |
| Category | Software › OS (macOS) · performance: Hardware › laptop |
| Audience | Tier 1 (Contoso Service Desk) → Tier 2 for MDM console actions |
| Owner | Contoso Desktop Support |
| Last reviewed | 2026-11 |
| Typical priority | P4 (profile missing, workaround exists) · P3 (no Wi-Fi/VPN profile, or the Mac is unusable) |
| Related scripts | [`macos_health_check.sh`](../scripts/bash/macos_health_check.sh) |
| Lab note | Macs are not virtualized in the lab; run the health check on a physical Mac if you have one. MDM steps are vendor-neutral. |

## Symptoms

- Company Wi-Fi, VPN, certificates or apps are missing; the company self-service app is empty.
- *System Settings › General › Device Management* shows no MDM profile, or a pending approval notification.
- MDM or compliance reports show the Mac as unmanaged or not checked in for days.
- The Mac is slow: spinning cursor, loud fans, apps slow to open, storage almost full.

## Likely causes

| Area | Cause |
|---|---|
| Enrollment | Not enrolled, or enrollment not **user-approved** (required for user-initiated enrollment) |
| Enrollment | Company Mac not assigned to the MDM server in Apple Business Manager |
| Delivery | Apple Push Notification service blocked — Macs need outbound TCP **5223** (falls back to **443**); MDM commands never arrive |
| Delivery | Wrong date/time (TLS failures); profile scoped to the wrong group in MDM |
| Performance | Low storage, high memory pressure, weeks of uptime, many login items, Spotlight re-indexing after an update, outdated macOS, ageing battery |

## Quick checks

```bash
sw_vers                                  # macOS version
sudo profiles status -type enrollment    # expect "Enrolled via DEP: Yes" and "MDM enrollment: Yes (User Approved)"
sudo profiles show                       # installed configuration profiles
```

GUI: *System Settings › General › Device Management* (older macOS: *Profiles*).

Performance snapshot:

```bash
df -h /                                  # free space on the system volume
uptime
memory_pressure | tail -n 1              # "System-wide memory free percentage: NN%"
softwareupdate -l                        # pending updates (needs network; can take a minute)
sudo ./macos_health_check.sh             # FileVault, SIP, Gatekeeper, firewall, MDM, disk, memory, battery, updates
sudo ./macos_health_check.sh --json      # same, as JSON to attach to the ticket
```

## Resolution (Tier 1)

### A — Enrollment and profiles

1. **Pending approval:** open *System Settings › General › Device Management* and complete the approval (the user may
   need to enter an administrator password).
2. **Company Mac not enrolled** (`Enrolled via DEP: No` or `MDM enrollment: No`): trigger enrollment again; a
   *Device Enrollment / Remote Management* notification appears — the user clicks it and follows the prompts.

```bash
sudo profiles renew -type enrollment
```

3. **Enrolled but profiles missing:** confirm date & time are automatic, the Mac is online (not on a guest network
   that blocks 5223), then restart. Still missing → ask Tier 2 to force a check-in or re-push profiles.
4. **Evidence for Tier 2:**

```bash
log show --last 1h --predicate 'process == "mdmclient"' > ~/Desktop/mdmclient.log
```

### B — Slow Mac

1. **Restart** if uptime is more than about two weeks.
2. *Activity Monitor* (Applications › Utilities): *CPU* and *Memory* tabs — the **Memory Pressure** graph should be
   green; yellow/red means memory shortage. Quit runaway apps with the user's permission.
3. **Storage:** *System Settings › General › Storage* — follow the recommendations; keep at least **15%** free.
4. **Login items:** *System Settings › General › Login Items* — remove what the user does not need.
5. Just updated macOS? Spotlight re-indexing can slow the Mac for a few hours — recheck later before going deeper.
6. Install pending updates (*System Settings › General › Software Update*).
7. **Safe Mode** to rule out third-party extensions — Apple silicon: shut down, press and hold the power button until
   startup options appear, select the disk, hold **Shift**, choose *Continue in Safe Mode*. Intel: restart holding **Shift**.
8. **Apple Diagnostics** — Apple silicon: hold the power button until startup options appear, then press **Command (⌘)-D**.
   Intel: hold **D** while starting up. Note any reference code for Tier 2.

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| Enrollment renew fails, or the Mac is missing from Apple Business Manager / MDM | Contoso Desktop Support | P3 |
| Enrolled but profiles never arrive | Contoso Desktop Support (MDM console); Contoso Network Operations if push traffic is blocked network-wide | P3 |
| Diagnostics reference code or battery service warning | Contoso Desktop Support (Apple service) | P3/P4 |
| Many Macs stop checking in at once | Desktop Support lead + Contoso Network Operations | P2 |

Attach: `sw_vers`, `sudo profiles status -type enrollment`, the profile names from `sudo profiles show`, the
`macos_health_check.sh --json` output, the serial number, the `mdmclient` log and screenshots.

## Verification

- `sudo profiles status -type enrollment` → `MDM enrollment: Yes (User Approved)`.
- Expected profiles are listed (Wi-Fi, FileVault escrow, restrictions); company Wi-Fi and VPN connect.
- The health check reports no failures; the user confirms normal performance.

## Prevention

- Company Macs enroll through Automated Device Enrollment so management cannot be skipped at setup.
- Keep macOS on a supported version; watch *last check-in* age in MDM.
- Keep at least 15% free storage; restart weekly.

## Ticket note example

```text
INC0010061 | No company Wi-Fi profile on Mac | priya.shah (HR) | P3
Issue: LT-MAC-001 cannot see the company Wi-Fi network; self-service app shows no items.
Steps taken:
  1. sw_vers: macOS 15.x. sudo profiles status -type enrollment -> "Enrolled via DEP: Yes", "MDM enrollment: No".
  2. sudo profiles renew -type enrollment; user clicked the Device Enrollment notification and approved with her admin password.
  3. Status now "MDM enrollment: Yes (User Approved)"; after ~5 minutes sudo profiles show lists Wi-Fi, FileVault escrow
     and restrictions profiles.
  4. macos_health_check.sh --json attached - no failures.
Result: Company Wi-Fi connected automatically; self-service app populated.
Next action: Resolve. Asked Desktop Support to check why enrollment was removed (MDM audit log). KB0016 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md) · Platform notes:
[docs/05-endpoint-management.md](../docs/05-endpoint-management.md)
