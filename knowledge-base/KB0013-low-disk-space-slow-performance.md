# KB0013 · Low disk space and slow laptop performance

| Field | Value |
|---|---|
| KB ID | KB0013 |
| Applies to | Windows 11 laptops (`LT-WIN-###`); endpoint health checks and Zabbix disk alerts |
| Category | Hardware › disk (performance complaints: Hardware › laptop) |
| Audience | Tier 1 (Contoso Service Desk) — admin clean-up and hardware by Tier 2 |
| Owner | Contoso Desktop Support |
| Last reviewed | 2026-11 |
| Typical priority | P4 (warning: C: free < 15%) · P3 (critical: C: free < 10%, or the user cannot work) |
| Related scripts | [`Get-EndpointHealth.ps1`](../scripts/powershell/endpoint/Get-EndpointHealth.ps1), [`Invoke-EndpointRemediation.ps1`](../scripts/powershell/endpoint/Invoke-EndpointRemediation.ps1) (`-Action ClearTemp`, `-Action DiskCleanup`) |
| Related scenario | `DiskFull` — on LT-WIN-001: `.\Invoke-LabFault.ps1 -Scenario DiskFull` ([lab scenarios](../docs/06-lab-scenarios.md)) |

## Symptoms

- *"Low Disk Space — You are running out of disk space on Local Disk (C:)."*
- Applications freeze, Windows Update fails, Outlook cannot grow its data file.
- An **automated incident** from the endpoint health check or Zabbix: C: below **15%** (warning) or **10%** (critical).
- "My laptop is slow" — slow start-up, fans running, apps taking minutes to open.

## Likely causes

| Area | Common culprits |
|---|---|
| Disk | Large files in Downloads (installers, ISOs, archives), OneDrive files kept *always on this device*, a large Outlook data file, browser/Teams caches, full Recycle Bin, Windows Update leftovers, memory dumps |
| Uptime | Weeks without a real restart, updates pending a reboot (*Shut down* with Fast Startup does not reset uptime — **Restart** does) |
| Memory | Many browser tabs or heavy apps; memory constantly above 85% |
| Start-up | Too many apps launching at sign-in |
| Hardware | Failing disk, thermal throttling, battery-saver mode |
| Security | Malware or an unexpected process using CPU |

## Quick checks

Run the health check on the laptop (admin recommended, not required):

```powershell
.\Get-EndpointHealth.ps1
.\Get-EndpointHealth.ps1 -Format Html -OutputPath C:\Users\Public\Documents   # report to attach to the ticket
$LASTEXITCODE                                                                 # 0 OK, 1 Warning, 2 Critical
```

It flags disk free space, memory, uptime, pending reboot, Defender, firewall, stopped services and recent system errors.

Find what is using the space (without admin rights you see your own profile and `C:\Users\Public`; other
profiles need an elevated session):

```powershell
Get-Volume -DriveLetter C | Select-Object DriveLetter, @{ n = 'FreeGB'; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } }, @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } }
Get-ChildItem C:\Users -Recurse -File -ErrorAction SilentlyContinue |
  Sort-Object Length -Descending | Select-Object -First 15 FullName, @{ n = 'SizeGB'; e = { [math]::Round($_.Length / 1GB, 2) } }
```

GUI: *Settings › System › Storage* (space by category and *Cleanup recommendations*).

## Resolution (Tier 1)

**Low disk space**

1. **Ask before deleting anything that belongs to the user.** Move business files to the S:/H: drives or OneDrive
   instead of deleting them; delete only what the user confirms (old installers, duplicate archives).
2. Clear temporary files and caches (preview first):

```powershell
.\Invoke-EndpointRemediation.ps1 -Action ClearTemp -WhatIf
.\Invoke-EndpointRemediation.ps1 -Action DiskCleanup -WhatIf
.\Invoke-EndpointRemediation.ps1 -Action DiskCleanup
```

3. Empty the Recycle Bin with the user's consent: `Clear-RecycleBin -DriveLetter C -Force`.
4. OneDrive: right-click large synced folders › **Free up space** (files stay in the cloud).
5. Turn on **Storage Sense**: *Settings › System › Storage › Storage Sense*.
6. *(Tier 2, elevated)* System clean-up: Disk Cleanup › *Clean up system files*, or
   `DISM /Online /Cleanup-Image /StartComponentCleanup`.

**Slow performance**

1. Check uptime and pending reboot in the health-check output — if high, **Restart** (not Shut down).
2. *Task Manager* (**Ctrl + Shift + Esc**) › *Processes*: sort by CPU, Memory and Disk; note any unknown process.
   *Startup apps*: disable non-essential items with the user.
3. Deeper view: `resmon` (Resource Monitor) for disk queue and memory pressure.
4. *Settings › System › Power & battery › Power mode*: not stuck on the most power-saving setting while plugged in.
5. Install pending updates and restart.
6. Disk health:

```powershell
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus
```

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| `HealthStatus` not *Healthy*, or crashes/blue screens | Contoso Desktop Support (hardware) | P3 |
| Memory above 85% during normal work | Contoso Desktop Support — upgrade or refresh ([SOP-003](../sops/SOP-003-laptop-provisioning-refresh.md)) | P4 |
| Unknown process, Defender detection or suspected malware | Contoso Desktop Support + **Security › malware alert** incident | P2/P3 |
| Same device alerts for low disk 3+ times in a week | Contoso Desktop Support → problem record | P4 |
| Many users slow at the same time | Contoso Infrastructure Ops / Network Operations | P2 |

Attach: the HTML health report, the top-15 largest files list (names only), free space before/after and the
Task Manager findings.

## Verification

- C: free space is back above **15%**; `.\Get-EndpointHealth.ps1` returns exit code 0 (or no disk warning).
- The automated alert clears and the incident receives a recovery work note.
- The user confirms normal performance after a restart.

## Prevention

- Storage Sense on; business files on shares or OneDrive, not in Downloads.
- Restart at least weekly — monitoring warns above 14 days of uptime.
- Recurring low-disk alerts on the same model or user group → right-size storage at the next refresh.

## Ticket note example

```text
INC0010051 | Automated: endpoint health Critical - C: free 6% | LT-WIN-001 (emma.carter) | P3
Issue: Endpoint health check raised a Critical alert for C: free space (6%); user reports Outlook freezing.
Steps taken:
  1. Get-EndpointHealth.ps1 -Format Html: C: 6% free (Critical); uptime 3 days; no pending reboot. Report attached.
  2. Largest files: a 21 GB archive in C:\Users\Public\Downloads and 4 GB of old installers in Downloads.
     User confirmed the archive is a copy already stored on S:\Finance - deleted with consent; installers removed.
  3. Invoke-EndpointRemediation.ps1 -Action DiskCleanup (previewed with -WhatIf first); Recycle Bin emptied with consent.
Result: C: free 41%; health check exit code 0; monitoring added a recovery note to the incident.
Next action: Resolve. Enabled Storage Sense; advised storing archives on S:. KB0013 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md) · Alert handling:
[SOP-007](../sops/SOP-007-monitoring-alert-response.md)
