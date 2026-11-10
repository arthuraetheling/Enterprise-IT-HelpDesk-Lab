# KB0005 · No network / 169.254.x.x address (APIPA — DHCP failure)

| Field | Value |
|---|---|
| KB ID | KB0005 |
| Applies to | Windows 11 laptops that receive addresses from DHCP scope `CORP-CLIENTS` (10.10.10.100 – 10.10.10.200) on DC01 |
| Category | Network › dhcp |
| Audience | Tier 1 (Contoso Service Desk) → Contoso Network Operations |
| Owner | Contoso Network Operations |
| Last reviewed | 2026-11 |
| Typical priority | P3 single user · **P2/P1 when several users are affected** (see Escalation) |
| Related scripts | [`Invoke-NetworkTriage.ps1`](../scripts/powershell/endpoint/Invoke-NetworkTriage.ps1), [`Invoke-EndpointRemediation.ps1`](../scripts/powershell/endpoint/Invoke-EndpointRemediation.ps1) (`-Action RenewDhcp`) |
| Related scenarios | `DhcpScopeDown`, `DhcpServiceDown` — on DC01: `.\Invoke-LabFault.ps1 -Scenario DhcpScopeDown` ([lab scenarios](../docs/06-lab-scenarios.md)) |

## Symptoms

- Network icon shows **No internet** / a globe; nothing internal or external opens.
- `ipconfig` shows **Autoconfiguration IPv4 Address 169.254.x.x** and an empty **Default Gateway**.
- `ipconfig /renew` returns: *"An error occurred while renewing interface Ethernet0 : unable to contact your DHCP
  server. Request has timed out."*
- Often starts after a reboot, a dock change or waking from sleep.

## Likely causes

| Cause | Typical clue |
|---|---|
| DHCP scope deactivated or DHCP Server service stopped on DC01 | Several users report it within minutes; monitoring alert on DC01 |
| Scope exhausted (no free leases) | New devices and guests fail first |
| Physical / link problem (cable, dock, Wi-Fi not associated) | Adapter status *Disconnected* or *Media disconnected* |
| Network access control (802.1X) rejected the device | Link is up, but no address is ever offered |
| Adapter disabled or driver fault | Only this device; other devices on the same port work |

> Leases last **8 days** and are renewed at the halfway point, so a laptop that already has a valid lease usually
> keeps working during a short DHCP outage. APIPA appears on devices that join, reboot without a valid lease, or are
> released. A **sudden cluster** of APIPA tickets means a DHCP outage — not twenty broken laptops.

## Quick checks

```powershell
ipconfig /all
Get-NetAdapter | Select-Object Name, Status, LinkSpeed, MediaConnectionState
Get-NetIPConfiguration
```

- Link **Up**? If not, fix the physical layer first.
- **Who else is affected?** Check tickets opened in the last 15–30 minutes and the monitoring dashboard (Zabbix alerts
  for DC01, e.g. the DHCP Server service).

## Resolution (Tier 1)

**1. Physical layer.** Reseat the cable or dock, confirm the corporate Wi-Fi network is connected and airplane mode
is off. *(Lab: in VMware, confirm the VM's network adapter is connected.)*

**2. Renew the lease.**

```powershell
ipconfig /renew
# or: .\Invoke-EndpointRemediation.ps1 -Action RenewDhcp
```

> If you are connected to the laptop remotely, do **not** run `ipconfig /release` — the remote session drops and may
> not come back.

**3. Capture evidence** for the ticket:

```powershell
.\Invoke-NetworkTriage.ps1
```

**4. Single user, others fine:** disable/enable the adapter or restart the laptop. Still APIPA → Tier 2 (driver,
hardware, network access control).

**5. More than one user:** stop troubleshooting individual laptops. Raise **one parent incident**, link the
others as children and escalate immediately.

### Reference — resolver checks on DC01 (Network / Infrastructure Ops)

```powershell
Get-Service DHCPServer
Get-DhcpServerv4Scope | Select-Object ScopeId, Name, State, StartRange, EndRange
Get-DhcpServerv4ScopeStatistics | Select-Object ScopeId, Free, InUse, PercentageInUse
Get-DhcpServerInDC                                   # server still authorized in AD?

# Restore service (configuration changes are recorded as an emergency change)
Start-Service DHCPServer
Set-DhcpServerv4Scope -ScopeId 10.10.10.0 -State Active
```

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| 2+ users with APIPA within ~15 minutes, or a monitoring alert for DHCP on DC01 | Contoso Network Operations — parent incident | P2 (Impact 2 × Urgency 1); P1 if company-wide → [SOP-005](../sops/SOP-005-major-incident-communications.md) |
| Single device, link up, others fine, renew still fails | Contoso Desktop Support | P3 |
| Wired port or dock dead for this user but working for others | Contoso Desktop Support (hardware) | P3 |

Attach: number and names of affected users, departments/locations, time of the first report, `ipconfig /all`,
`Invoke-NetworkTriage.ps1` output and any monitoring alerts seen.

## Verification

- `ipconfig /all` shows an address in **10.10.10.100 – 10.10.10.200**, gateway **10.10.10.2**, DNS **10.10.10.10**.
- `Test-NetConnection dc01.corp.contoso.internal -Port 389` → `TcpTestSucceeded : True`.
- For an outage: every child incident is confirmed working before the parent is resolved.

## Prevention

- Monitor scope utilisation (alert at 80% in use) and the DHCP Server service (Zabbix → incident).
- Scope and option edits are **normal changes**; restoring a deactivated scope during an outage is an **emergency change**.
- Production design: DHCP failover between two servers removes this single point of failure.

## Ticket note example

```text
INC0010024 | No network, 169.254 address | emma.carter (Finance) | P3 -> child of INC0010025 (P2)
Issue: After a reboot at 13:02 LT-WIN-001 has 169.254.12.7, no gateway; no internal or external access.
Steps taken:
  1. Adapter status Up; ipconfig /renew -> "unable to contact your DHCP server".
  2. Invoke-NetworkTriage.ps1 output attached (APIPA detected, DHCP unreachable).
  3. Two more calls (Sales, Operations) with the same symptom by 13:12 -> raised parent INC0010025 (P2),
     linked children, escalated to Contoso Network Operations.
  4. Network Ops: scope CORP-CLIENTS was inactive; re-activated under emergency change CHG0030005.
Result: ipconfig /renew -> 10.10.10.118, gateway 10.10.10.2, DNS 10.10.10.10; all three users confirmed working.
Next action: Resolve child; parent stays open for the post-incident review. KB0005 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md) · Process:
[incident management](../itil/incident-management.md)
