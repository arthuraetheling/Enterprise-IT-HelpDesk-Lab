# CHG0030001: Deploy workstation security baseline GPO to OU=Workstations

> **Example record (simulated).** It shows how the lab's `CON-C-Workstation-Baseline` GPO is rolled out under
> change control: a pilot through security filtering, then production. To rehearse it, build the GPO
> (`05-Configure-GroupPolicy.ps1` creates the same settings), scope it to LT-WIN-002 first, and follow §6.
> Template: [RFC template](../templates/RFC-template.md) · rules: [change management](../change-management.md).

## 1. Summary

| Field | Value |
|---|---|
| Change number | CHG0030001 |
| Type | **Normal** · risk **Medium (9/15)** → CAB |
| Category | Group Policy |
| Requested by | Contoso Desktop Support lead |
| Implementer | Lab administrator (`adm.tech`), Contoso Infrastructure Ops |
| Peer reviewer | Contoso Identity & Access engineer |
| Approver | CAB, chaired by Lucas Moreno (IT Manager) |
| Affected CIs | DC01 (AD DS / SYSVOL holds the GPO) · LT-WIN-001 · LT-WIN-002 |
| Control objectives | BC-09 Endpoint security baseline · BC-10 Logging & monitoring · BC-07 Change control |
| Pilot | Thu 2026-10-08 18:00–18:30 ET (LT-WIN-002 only) · pilot period to Mon 2026-10-12 17:00 |
| Production | Tue 2026-10-13 18:00–19:00 ET (all of OU=Workstations) |
| Window / freeze | Inside the Tue/Thu window; the Q3-close freeze ended 2026-10-02; no conflicting changes on these CIs |

## 2. Description and justification

The Q3 control self-assessment found that workstation hardening relied on defaults that users could change: no
enforced screen lock, no logon banner, firewall and Defender user-controllable, and no PowerShell logging. This
change enforces them through one GPO linked to `OU=Workstations,OU=Computers,OU=Contoso,DC=corp,DC=contoso,DC=internal`.

| Setting | Before | After (enforced) |
|---|---|---|
| Windows Firewall: Domain, Private, Public | On by default, user can disable | On, not user-changeable |
| Machine inactivity lock | None | 900 seconds |
| Logon banner | None | Caption "Authorized use only" + acceptable-use text |
| Windows Update | Default behavior | Auto-download and install daily at 03:00 |
| Defender real-time protection | User can disable | Enforced on |
| PowerShell script-block logging | Off | On (events in *Microsoft-Windows-PowerShell/Operational*) |

**If we don't:** unlocked unattended laptops, inconsistent patching, and no record of PowerShell activity
during a security investigation.

## 3. Risk and impact assessment

| Factor | Score | Reason |
|---|---|---|
| Blast radius | 3 | Every Windows laptop (all 50 users in the scenario) |
| Criticality of CIs | 2 | Endpoints are business-important; no core service changes |
| Testing | 1 | Pilot on LT-WIN-002 with evidence before production |
| Backout | 1 | Unlink + `gpupdate /force`, < 15 min, rehearsed during the pilot |
| Complexity / experience | 2 | GPO deployment done before; six settings in one GPO |
| **Total** | **9 / 15 → Medium → CAB** | |

| Risk | Likelihood | Mitigation |
|---|---|---|
| Firewall blocks a management tool | Low | Zabbix agent 2 uses **active** checks (outbound to MON01:10051); confirm data keeps arriving during the pilot |
| Overnight update restarts lose unsaved work | Medium | Comms: save work at end of day; review the restart behavior in the PIR |
| 15-minute lock annoys presenters | Medium | By design; Service Desk FAQ |
| Policy conflicts with another GPO | Low | `Get-GPInheritance -Target "<Workstations OU DN>"` reviewed: only Default Domain Policy is inherited |

## 4. Communication plan

| Audience | Message | Channel | When |
|---|---|---|---|
| Marcus Reed (pilot user, LT-WIN-002) | Logon notice, 15-minute lock, 03:00 updates; how to report problems | Email + call | 2026-10-08 |
| All staff | Same changes from Oct 13; save work at end of day | Email from Lucas Moreno | 2026-10-09 |
| Contoso Service Desk | FAQ: banner text, lock timer, update schedule; route issues to this CHG | Huddle | 2026-10-12 |

## 5. Pre-implementation checklist

- [x] Peer review: Identity & Access engineer, 2026-10-06 11:20
- [x] CAB approval recorded, 2026-10-07
- [x] VMware snapshots `pre-CHG0030001` of DC01 and LT-WIN-002
- [x] Baseline captured: `gpresult /h` on both laptops before the change
- [x] Service Desk FAQ ready before production (CAB condition)

## 6. Implementation plan

**Pilot (2026-10-08):**

```powershell
$gpo = 'CON-C-Workstation-Baseline'
$ou  = 'OU=Workstations,OU=Computers,OU=Contoso,DC=corp,DC=contoso,DC=internal'
Backup-GPO -Name $gpo -Path C:\GPOBackups -Comment 'CHG0030001 pilot'
# Scope to the pilot device: Authenticated Users keep Read (no Apply); LT-WIN-002 gets Read + Apply
Set-GPPermission -Name $gpo -TargetName 'Authenticated Users' -TargetType Group -PermissionLevel GpoRead -Replace
Set-GPPermission -Name $gpo -TargetName 'LT-WIN-002' -TargetType Computer -PermissionLevel GpoApply
New-GPLink -Name $gpo -Target $ou -LinkEnabled Yes      # skip if the GPO is already linked
```

Then run `gpupdate /force` on LT-WIN-002 and restart it, because the lock and banner settings apply at the next sign-in.

**Production (2026-10-13), after the pilot exit criteria are met:**

```powershell
Backup-GPO -Name $gpo -Path C:\GPOBackups -Comment 'CHG0030001 pre-production'
Set-GPPermission -Name $gpo -TargetName 'Authenticated Users' -TargetType Group -PermissionLevel GpoApply -Replace
Set-GPPermission -Name $gpo -TargetName 'LT-WIN-002' -TargetType Computer -PermissionLevel None -Replace
```

Then run `gpupdate /force` and restart LT-WIN-001, and verify both laptops.

## 7. Test and verification plan

| # | Check (on the target laptop) | Pass criteria | Pilot | Prod |
|---|---|---|---|---|
| 1 | `gpresult /r /scope computer` | `CON-C-Workstation-Baseline` under *Applied Group Policy Objects* | ✅ | ✅ |
| 2 | `Get-NetFirewallProfile \| Select-Object Name, Enabled` | Domain, Private, Public = True | ✅ | ✅ |
| 3 | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'` | `InactivityTimeoutSecs` = 900; `legalnoticecaption` = "Authorized use only" | ✅ | ✅ |
| 4 | `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'` | `AUOptions` 4, `ScheduledInstallDay` 0, `ScheduledInstallTime` 3 | ✅ | ✅ |
| 5 | `(Get-MpComputerStatus).RealTimeProtectionEnabled` | True | ✅ | ✅ |
| 6 | `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'` | `EnableScriptBlockLogging` = 1 | ✅ | ✅ |
| 7 | `.\Test-EndpointCompliance.ps1` | Firewall and screen-lock checks PASS | ✅ | ✅ |
| 8 | Sign-in as the user | Banner shown; screen locks after 15 idle minutes | ✅ | ✅ |
| 9 | Zabbix *Latest data* for the laptop | Data continues after the change | ✅ | ✅ |
| 10 | **Pilot only:** `gpresult /r /scope computer` on LT-WIN-001 | GPO listed under *filtered out*, `Filtering: Denied (Security)` | ✅ | n/a |

Evidence excerpt (LT-WIN-002, pilot):

```
COMPUTER SETTINGS
    CN=LT-WIN-002,OU=Workstations,OU=Computers,OU=Contoso,DC=corp,DC=contoso,DC=internal
    Applied Group Policy Objects
    -----------------------------
        CON-C-Workstation-Baseline
        Default Domain Policy
```

## 8. Backout plan

- **Triggers:** any user cannot sign in; a business application is blocked by the firewall; Zabbix stops
  receiving data from a laptop; or more than 2 incidents are attributed to this change within 48 hours.
- **Decision point:** pilot, any time until 2026-10-12 17:00. Production, 20:30 ET in the window.
- **Steps:** `Set-GPLink -Name $gpo -Target $ou -LinkEnabled No`, then `gpupdate /force` and restart each
  laptop. Pilot only: alternatively revert LT-WIN-002 to snapshot `pre-CHG0030001`.
- **Time:** < 15 minutes. **Rehearsed** on LT-WIN-002 on 2026-10-09 (unlink → `gpupdate` → settings
  removed in 6 minutes → re-linked). The rehearsal was part of the approved pilot plan, and the pilot user
  was informed.
- **Verify:** `gpresult` no longer lists the GPO; checks 3–6 show the values removed. These settings live
  under policy keys, so they are not tattooed.

## 9. Approvals

| Role | Name | Decision | Date / time | Conditions |
|---|---|---|---|---|
| Peer reviewer | Identity & Access engineer | Approved | 2026-10-06 11:20 | None |
| CAB | Lucas Moreno (chair) + Desktop Support, Network Ops, Service Desk leads | **Approved with conditions** | 2026-10-07 14:15 | Pilot ≥ 2 business days; FAQ before production; production in the Tue/Thu window |

## 10. Implementation record

| Time (ET) | Step / event | Result |
|---|---|---|
| 10-08 18:02 | Snapshots taken (DC01, LT-WIN-002) | OK |
| 10-08 18:06 | GPO configured; `Backup-GPO` (pilot) | OK |
| 10-08 18:10 | Filtering → LT-WIN-002; link enabled on OU=Workstations | OK |
| 10-08 18:14 | LT-WIN-002 `gpupdate /force` + restart | OK |
| 10-08 18:24 | Checks 1–10 passed | OK |
| 10-09 10:30 | Backout rehearsal on LT-WIN-002 (6 min), re-linked | OK |
| 10-12 17:00 | Pilot exit review: 0 incidents, Zabbix data continuous, pilot user feedback positive | Go |
| 10-13 18:01 | `Backup-GPO` (pre-production) | OK |
| 10-13 18:05 | Filtering → Authenticated Users (Apply); LT-WIN-002 entry removed | OK |
| 10-13 18:12 | LT-WIN-001 `gpupdate /force` + restart | OK |
| 10-13 18:31 | Checks 1–9 passed on both laptops; compliance output attached | OK |
| 10-13 18:40 | Implemented; Service Desk notified | Closed for PIR |

## 11. Post-implementation review (2026-10-15)

| Item | Value |
|---|---|
| Outcome | **Successful** |
| Incidents caused | None. Two how-to calls about the lock timer were answered from the FAQ |
| Deviations from plan | None. Production took 40 minutes against 60 planned |
| Lessons and follow-ups | (1) On 2026-10-10, Windows Update restarted LT-WIN-002 at 03:00 and lost unsaved Notepad text. Evaluate a *no auto-restart with signed-in users* setting in a future normal change. (2) Add the banner and lock timer to the new-hire FAQ ([SOP-001](../../sops/SOP-001-new-hire-onboarding.md)). (3) For future GPO pilots, use a pilot computer group instead of per-computer filtering |
| CMDB | No CI attributes changed; LT-WIN-001, LT-WIN-002 and DC01 linked as affected CIs |
| Close code | Successful |
