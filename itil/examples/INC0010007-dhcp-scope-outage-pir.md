# INC0010007 Post-Incident Review: DHCP scope inactive, clients fell back to APIPA

> **Example record (simulated)** from the fictional 50-user Contoso environment. Reproduce it on DC01 with
> `Invoke-LabFault.ps1 -Scenario DhcpScopeDown`. On LT-WIN-001, a release/renew then yields a 169.254.x.x address.
> Restore with `-Revert`.
> **This review is blameless.** It looks at how the system allowed the failure and how we detected it, not at
> who made a mistake.

## 1. Summary

| Field | Value |
|---|---|
| Incident | **INC0010007**, major incident · children INC0010008, INC0010009, INC0010010 |
| Date | Thursday 2026-11-05 |
| Service | Office network addressing: DHCP on DC01, scope `CORP-CLIENTS` (10.10.10.100–10.10.10.200) |
| Priority | Opened 09:10 as P3 (Impact 3 × Urgency 1) → **P1** at 09:41 (Impact 1 × Urgency 1) |
| User-facing impact | 09:10 – 10:02 (**52 min**) |
| Scope inactive | 07:55 – 09:59 (2 h 04 min) |
| Major Incident Manager | Service Desk lead (weekly rotation) |
| Technical lead | Contoso Network Operations (on call) |
| Emergency change | **CHG0030002**: re-activate the scope (ECAB verbal approval 09:57) |
| Problem record | **PRB0040002** (opened because the incident was P1) |
| Review held | Monday 2026-11-09, 10:00–10:45 ET · Service Desk, Network Ops, Infrastructure Ops, Desktop Support, Lucas Moreno |

## 2. What happened

Early in the morning, a network engineer turned off (deactivated) the office DHCP scope to change its lease
length, intending to turn it straight back on. The engineer was pulled into another call and the scope stayed
off. Laptops that already had an address kept working. Any device that needed a **new** address got none, and
Windows gave it a self-assigned 169.254.x.x address, which cannot reach anything. Monitoring stayed green
because the DHCP service itself was still running. Users' calls revealed the outage, and it was fixed in
21 minutes once declared.

## 3. Impact

| Who / what | Effect |
|---|---|
| Marcus Reed (Sales), LT-WIN-002 | His lease expired during a 10-day trip; no network after docking, 09:10–10:02 |
| Emma Carter (Finance), LT-WIN-001 | A generic release/renew during an unrelated Outlook call dropped her valid lease; no network 09:24–10:02 |
| New hire (Sales), RITM0010003 | Laptop could not get an address or join the domain; first-hour onboarding started ~25 min late |
| All other users | Not affected (valid 8-day leases), but exposed as leases came up for renewal |
| Data / customers | No data loss; no external customer impact |

## 4. Timeline (ET, 2026-11-05)

| Time | Event |
|---|---|
| 07:55 | Network Ops engineer deactivates `CORP-CLIENTS` on DC01 to shorten the lease before next week's laptop refresh, believing scope properties can only be edited while inactive. **No CHG raised** |
| 08:02 | Engineer joins an urgent vendor call; the scope stays inactive. The DHCP Server service keeps running, so the Zabbix service check stays green |
| 09:10 | **INC0010007**: Marcus Reed reports "No Internet" on LT-WIN-002 after docking. P3 |
| 09:12 | Tier 1 runs `Invoke-NetworkTriage.ps1`: adapter up, IPv4 169.254.x.x, no gateway. KB0005 steps (cable, dock, renew) don't help |
| 09:22 | **INC0010008**: Emma Carter reports Outlook "Disconnected" after resume |
| 09:24 | Tier 1 runs `Invoke-EndpointRemediation.ps1 -Action RenewDhcp` as a generic fix. The lease is released, no offer comes back, and LT-WIN-001 drops to APIPA |
| 09:28 | INC0010007 escalated to Contoso Network Operations (18 min after logging) with triage output: "persistent APIPA, second user on the subnet" |
| 09:31 | **INC0010009** auto-created by Zabbix: *LT-WIN-001 no agent data for 5 min* (Warning → P4, Contoso Desktop Support, `correlation_id` `LT-WIN-001-AgentNoData`) |
| 09:36 | **INC0010010**: Desktop Support reports that the new-hire laptop for RITM0010003 (10:00 start) gets APIPA |
| 09:41 | Service Desk lead sees 3 APIPA incidents plus 1 monitoring incident on 10.10.10.0/24 within 31 minutes. **Major incident declared**: INC0010007 promoted to P1, the other three linked as children, Lucas Moreno informed |
| 09:45 | Bridge open: MIM, Network Ops on-call (technical lead), Infrastructure Ops, communications lead, scribe |
| 09:50 | Initial notice sent; Service Desk phone greeting updated (§6) |
| 09:52 | `Get-DhcpServerv4Scope -ComputerName DC01` → `CORP-CLIENTS` **State: InActive**; DHCPServer service Running |
| 09:55 | The engineer joins the bridge and explains the 07:55 work |
| 09:57 | ECAB (Lucas Moreno + Network Ops on-call lead) approves emergency change **CHG0030002**: re-activate only, no other edits |
| 09:59 | `Set-DhcpServerv4Scope -ComputerName DC01 -ScopeId 10.10.10.0 -State Active` |
| 10:02 | `Get-DhcpServerv4ScopeStatistics` shows leases being issued. LT-WIN-002 and LT-WIN-001 renew to 10.10.10.1xx; `Invoke-NetworkTriage.ps1` passes. **Service restored** |
| 10:06 | Zabbix data from LT-WIN-001 resumes; INC0010009 updated |
| 10:09 | New-hire laptop joins the domain |
| 10:10 | Resolution notice sent |
| 10:15 | INC0010007 resolved; children resolved with the parent. PRB0040002 opened |
| 14:00 | CHG0030002 documented retrospectively (within 1 business day) |

| Measure | Value |
|---|---|
| Time to detect (scope off → first report) | 75 min, with no monitoring signal |
| Time to declare (first report → major incident) | 31 min |
| Time to restore (declaration → restored) | 21 min |
| P1 notice | First notice 9 min after declaration (SOP-005 target: 15 min) |
| P1 resolution target (4 h) | **Met**: resolved 65 min after the first report |

## 5. What went well

- The Service Desk lead connected four tickets into one pattern and declared quickly once it was visible.
- INC0010007 was escalated inside the 20-minute rule, with triage evidence, so Network Ops did not have to
  start over.
- The first notice told users **not to restart or undock working laptops**. That stopped more devices from
  losing valid leases.
- The engineer joined the bridge and explained the earlier work within minutes. Blameless reviews make that safe.
- The fix was minimal, approved through ECAB in two minutes, and verified with commands, not assumptions.

## 6. Communications (as sent)

**09:50 `[P1][INVESTIGATING] Office network – some laptops can't connect – INC0010007`**
> Since about 09:10 ET, some laptops connecting to the office network show "No Internet". If your laptop is
> working, please don't restart or undock it. IT is investigating with priority. Next update by 10:20 ET.
> Questions: Service Desk x1234, mention INC0010007.

**10:10 `[P1][RESOLVED] Office network – some laptops can't connect – INC0010007`**
> Resolved at 10:02 ET. A network setting that gives laptops their address was turned off during maintenance
> and has been turned back on. If your laptop still shows "No Internet", unplug and reconnect it or restart it.
> Still stuck? Call x1234 and mention INC0010007. We will share what we're changing to prevent a repeat.

## 7. What didn't go well

- **No change record.** A "quick" edit skipped peer review and an implementation checklist with a
  verification step. The change schedule showed nothing the bridge could correlate.
- **Monitoring watched the process, not the service.** Zabbix checked that the DHCPServer service was running.
  It did not check that the scope was active or that leases were being issued.
- **A generic fix made one incident worse.** Release/renew on a working laptop (INC0010008) turned a transient
  Outlook disconnect into a full loss of connectivity.
- **The pattern rule wasn't operational.** "3 similar incidents in 30 minutes → major-incident check" was
  in the incident policy but not in the Tier 1 checklist or on a dashboard. It took 31 minutes to declare.

## 8. Root cause

Scope `CORP-CLIENTS` was deactivated during DHCP maintenance performed without a change record, and was not
re-activated. The DHCP Server service stayed running, so monitoring stayed green, and every client that needed
a new lease got no offer and self-assigned an APIPA address.

**Contributing factors:**

1. A common misconception that scope properties can only be edited while the scope is inactive. Lease
   duration and options can be changed live.
2. Change control was bypassed for a small edit.
3. Monitoring covered the process but not the service outcome.
4. Release/renew was used as a generic Tier 1 fix.
5. The pattern-detection rule was not built into daily tools.

## 9. Corrective and preventive actions

| # | Action | Type | Owner | Due | Tracking | Status (11-10) |
|---|---|---|---|---|---|---|
| 1 | Zabbix items and triggers on DC01: scope state ≠ Active (High) and free addresses < 10 (Warning). Later: synthetic DHCP probe from MON01 | Detect | Contoso Infrastructure Ops | 11-13 | **CHG0030004** (CAB 11-11) | Scheduled |
| 2 | Every DHCP, DNS or GPO edit needs a CHG, whatever its size. Weekly unauthorized-change check ([change management §10](../change-management.md#10-separation-of-duties-and-unauthorized-changes)) | Prevent | Lucas Moreno | 11-11 | CAB minutes | In progress |
| 3 | Network Ops runbook: change lease and options live (`Set-DhcpServerv4Scope -LeaseDuration`, `Set-DhcpServerv4OptionValue`); never deactivate a production scope outside a CHG; peer check after DHCP work | Prevent | Contoso Network Operations | 11-12 | Runbook | In progress |
| 4 | [KB0005](../../knowledge-base/KB0005-no-network-apipa-dhcp.md) v1.1: several APIPA reports → escalate as a possible major incident; Tier 3 check `Get-DhcpServerv4Scope`; use `RenewDhcp` only when the device already has no valid address | Respond | Contoso Service Desk + Network Ops | 11-10 | KB0005 | Done |
| 5 | [SOP-004](../../sops/SOP-004-incident-triage-escalation.md): "3 similar incidents in 30 minutes → notify the Service Desk lead". Add a Service Desk dashboard list *Open incidents by subcategory, last 30 min* | Detect | Service Desk lead | 11-10 | SOP-004 | Done |
| 6 | DHCP resilience (second server with DHCP failover) | Resilience | Contoso Infrastructure Ops | — | Risk register: single DC **accepted for the lab** by Lucas Moreno, review 2027-05 | Risk accepted |
| 7 | PRB0040002 tracks actions 1–6; close 30 days after CHG0030004 with no recurrence | — | Problem manager | — | PRB0040002 | Open |

**Proposed monitoring design for CHG0030004** (Zabbix agent 2 on DC01; item timeout 10 s for PowerShell start-up):

```ini
# zabbix_agent2.conf (or an included .conf file) on DC01
UserParameter=dhcp.scope.state[*],powershell.exe -NoProfile -Command "(Get-DhcpServerv4Scope -ScopeId $1).State"
UserParameter=dhcp.scope.free[*],powershell.exe -NoProfile -Command "(Get-DhcpServerv4ScopeStatistics -ScopeId $1).Free"
```

| Trigger (Zabbix 7.0 syntax) | Severity | Incident (alert mapping) |
|---|---|---|
| `last(/DC01/dhcp.scope.state[10.10.10.0])<>"Active"` | High | P2 → Contoso Infrastructure Ops; MIM re-assesses impact |
| `last(/DC01/dhcp.scope.free[10.10.10.0])<10` | Warning | P4 → owning group |

## 10. Lessons learned

- *Up* is not *working*. Monitor the outcome users depend on (leases issued), not only the process.
- A change without a record is invisible during the incident it causes.
- Generic fixes have side effects. Run diagnostics first (`Invoke-NetworkTriage.ps1`) and change state only when
  the evidence calls for it.
- Pattern rules only work when the tools show the pattern.

**Related:** [Incident management](../incident-management.md) ·
[SOP-005 Major incident](../../sops/SOP-005-major-incident-communications.md) ·
[Communication template](../templates/major-incident-communication-template.md) ·
[Monitoring & alerting](../../docs/04-monitoring-alerting.md)
