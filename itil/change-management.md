# Change Enablement (Change Management)

| | |
|---|---|
| **ITIL 4 practice** | Change enablement (earlier ITIL 4 material: *change control*; ITIL v3: *change management*) |
| **Change manager / CAB chair** | Lucas Moreno, IT Manager |
| **Tool** | ServiceNow PDI → Change · template: [RFC](templates/RFC-template.md) |
| **Business control** | BC-07 Change control ([lab design §10](../docs/01-lab-design.md)) |

## 1. Objective

Get changes done quickly **and** safely. Every change to production configuration is assessed for risk,
approved at the right level, implemented with a tested backout, and reviewed. "Production" in this lab means
DC01, MON01, the GPOs, the ServiceNow integration and every enrolled endpoint.

## 2. What needs a change record

| Needs a CHG | Does not need a CHG |
|---|---|
| Creating, editing, linking or re-scoping any `CON-*` GPO | Password reset, account unlock (incident or request work) |
| DNS zones, records, forwarders on DC01 | Restarting a service on one workstation during an incident |
| DHCP scope state, options, lease duration, reservations | Running read-only diagnostics (`Get-*`, `gpresult`, `Invoke-NetworkTriage.ps1`) |
| FGPP / PSO settings, delegation (`dsacls`), LAPS policy | Creating KB articles or SOP revisions (knowledge lifecycle) |
| Zabbix triggers and thresholds that change incident creation; ServiceNow integration settings | Adding a user to a department group via an **approved request** (standard change model; see §3) |

When unsure, raise a CHG. An unrecorded change caused [INC0010007](examples/INC0010007-dhcp-scope-outage-pir.md).

## 3. Change types

| Type | Definition | Approval | Lab examples |
|---|---|---|---|
| **Standard** | Low-risk, repeatable, documented procedure, **pre-approved** as a model | None per instance; logged on the request or CHG | Add a user to `GG-<Dept>` per an approved access request; laptop reimage ([SOP-003](../sops/SOP-003-laptop-provisioning-refresh.md)); onboarding/offboarding account actions ([SOP-001](../sops/SOP-001-new-hire-onboarding.md), [SOP-002](../sops/SOP-002-employee-offboarding.md)) |
| **Normal** | Anything else that is planned | Risk-based (§5): peer + change manager, or CAB | New or edited GPO ([CHG0030001](examples/CHG0030001-deploy-workstation-baseline-gpo.md)); DNS forwarder change; DHCP scope options; Zabbix DHCP scope monitoring (CHG0030004) |
| **Emergency** | Needed now to restore service or stop active harm | **ECAB**, verbal allowed, documented within 1 business day | Re-activate the DHCP scope during an outage (CHG0030002 / INC0010007); roll back a GPO that blocks sign-in |

**Standard change catalogue (pre-approved models)**

| Model | Procedure | Executed by | Evidence |
|---|---|---|---|
| Department share access | Approved RITM (approver in `GG-Managers`) → `Add-ADGroupMember GG-<Dept>` → user signs out/in | Contoso Identity & Access | RITM approval + work note |
| Laptop reimage / refresh | SOP-003 | Contoso Desktop Support | Inventory JSON + CMDB update |
| New hire / leaver account actions | `New-Employee.ps1` / `Remove-Employee.ps1` per SOP-001/002 | Contoso Identity & Access | Script log with ticket number |

A model is reviewed every 6 months. A model that causes an incident loses its standard status until the
next CAB re-approves it.

## 4. Risk and impact assessment

Score every normal and emergency change. The total sets the approval route.

| Factor | 1 | 2 | 3 |
|---|---|---|---|
| **Blast radius** | ≤ 5 users/devices | a department / ≤ 25 | enterprise / > 25, or a core service |
| **Criticality of the CIs** | non-critical | business-important (shares, printing, one app) | core (AD DS, DNS, DHCP, network, monitoring) |
| **Testing** | tested in lab/pilot with evidence | partially tested | untested |
| **Backout** | scripted and tested, < 15 min | documented but untested, or 15–60 min | none, or > 60 min |
| **Complexity / experience** | done before, ≤ 5 steps | done before, complex | first time or multiple teams |

| Total | Risk | Approval route |
|---|---|---|
| 5–7 | **Low** | Peer review + change manager (asynchronous) |
| 8–11 | **Medium** | CAB |
| 12–15 | **High** | CAB + explicit IT Manager sign-off + business owner (e.g. Olivia Bennett for Finance-impacting changes) |

## 5. CAB and ECAB

| | CAB | ECAB |
|---|---|---|
| **When** | Weekly, Wednesday 14:00 ET (30 min). RFC deadline Monday 17:00 ET | On demand, any time |
| **Members** | Lucas Moreno (chair), leads of Service Desk, Desktop Support, Identity & Access, Network Operations, Infrastructure Ops; Security for security-relevant changes | Lucas Moreno (or delegate) + on-call lead of the affected group |
| **Quorum** | Chair + 2 leads | 2 people |
| **Output** | Approve / approve with conditions / reject / defer, recorded on the CHG | Verbal approval, recorded on the CHG within 1 business day |

The CAB asks: Is the risk score honest? Is the backout tested? Who is affected, and do they know? Does
anything conflict on the change schedule? Is the Service Desk ready for the calls?

> **Lab tip (one-person lab):** in the PDI, create a user *lucas.moreno* with the `itil` role and add
> them to the CAB approval group. Approve your own RFCs while impersonating that user, so the record shows
> separate requester, implementer and approver accounts.

## 6. RFC contents (ServiceNow field mapping)

| RFC section | ServiceNow change field |
|---|---|
| Summary, type, category | Short description, Type, Category |
| Affected CIs | Configuration item + *Affected CIs* related list |
| Business justification | Justification |
| Implementation steps (exact commands / console paths) | Implementation plan |
| Risk score and impact (users, services, downtime) | Risk and impact analysis, Risk, Impact |
| Backout steps, trigger and time | Backout plan |
| Test and verification evidence | Test plan |
| Schedule | Planned start / end date |
| Linked records | Problem, Incident, Requested item |

**Test plan expectations:** pilot first (one device via GPO security filtering, or one VM snapshot), capture
evidence (`gpresult`, script output, screenshots), and define the pass criteria **before** implementing.

## 7. Scheduling

- **Change window** for user-impacting normal changes: **Tuesday and Thursday, 18:00–21:00 ET**.
- **Freeze periods** (emergency changes only): the last 3 business days of each quarter plus the first 2 of
  the next (Finance close), and **December 21 – January 2**.
- Check the change schedule for conflicts on the same CIs before submitting.

## 8. Backout toolkit

| Change area | Before the change | Backout |
|---|---|---|
| Any VM | VMware snapshot named `pre-CHG00#####` | Revert to the snapshot (lab only; mind AD replication and time) |
| Group Policy | `Backup-GPO -Name "<GPO>" -Path C:\GPOBackups -Comment "pre-CHG00#####"` | `Set-GPLink -Name "<GPO>" -Target "<OU DN>" -LinkEnabled No` then `gpupdate /force` on clients; or `Restore-GPO -Name "<GPO>" -Path C:\GPOBackups` (restores settings, not links) |
| DNS forwarders | `Get-DnsServerForwarder -ComputerName DC01` (record the values) | `Set-DnsServerForwarder -ComputerName DC01 -IPAddress 10.10.10.2,1.1.1.1` |
| DHCP | `Export-DhcpServer -ComputerName DC01 -File C:\Backup\dhcp-pre-CHG00#####.xml -Leases` | Re-apply the recorded values (`Set-DhcpServerv4OptionValue`, `Set-DhcpServerv4Scope`); full restore with `Import-DhcpServer` |
| AD objects | Export the objects' attributes (`Get-ADObject ... -Properties *` → CSV) | Re-apply from the export; deleted objects come back with `Restore-ADObject` only if the AD Recycle Bin is enabled |

Every RFC states a **backout trigger**: the observable condition (e.g. "any user cannot sign in",
"Zabbix agent stops reporting") and the deadline in the window after which the change is backed out.

## 9. Post-implementation review (PIR)

A PIR is required for **emergency**, **failed or backed-out**, and **incident-causing** changes, within
**5 business days**. Successful high-risk changes get one too. Record: outcome, incidents caused,
deviations from plan, lessons, follow-up actions. Close codes: *Successful*, *Successful with issues*,
*Unsuccessful (backed out)*.

## 10. Separation of duties and unauthorized changes

- The **implementer never approves** their own change. The **peer reviewer is not the implementer**.
  When the CAB chair raises a change, another CAB member approves it.
- Privileged work uses `adm.tech` only under a CHG number, recorded in the implementation record.
- **Weekly unauthorized-change check** (Infrastructure Ops). Every result must map to a CHG:

```powershell
Get-GPO -All | Where-Object ModificationTime -gt (Get-Date).AddDays(-7) |
    Select-Object DisplayName, ModificationTime
Get-DhcpServerv4Scope -ComputerName DC01 | Select-Object ScopeId, Name, State, LeaseDuration
Get-DhcpServerv4OptionValue -ComputerName DC01 -ScopeId 10.10.10.0
Get-DnsServerForwarder -ComputerName DC01
```

## 11. Change and the CMDB

Every CHG lists its affected CIs (DC01, MON01, LT-WIN-###). After implementation, update the CI records
the change touched: new attributes, new relationships, retired CIs. Re-run `Sync-InventoryToCmdb.ps1` and
`cmdb_reconcile.py` after endpoint-wide changes (BC-11).

## 12. KPIs

| KPI | Definition | Target |
|---|---|---|
| Change success rate | Implemented without backout or incident | ≥ 95% |
| Emergency change rate | Emergency ÷ all changes | ≤ 10% |
| Changes causing incidents | Changes linked as the cause of ≥ 1 incident | ≤ 5% |
| Unauthorized changes | Configuration changes found with no CHG | 0 |
| PIR completion | Required PIRs done within 5 business days | 100% |
| RFC lead time | Normal RFCs submitted before the CAB deadline | ≥ 90% |

## 13. RACI

| Activity | Requester | Implementer | Peer reviewer | Change manager (Lucas Moreno) | CAB / ECAB | Service Desk |
|---|---|---|---|---|---|---|
| Raise RFC | R | R | | I | | |
| Risk assessment | C | R | C | A | | |
| Peer review | | C | R | A | | |
| Approve (normal) | | | | A | R | I |
| Approve (emergency) | | | | A | R | I |
| Communicate to users | | R | | A | | R |
| Implement and verify | | R | C | A | | I |
| Backout decision | | R | C | A | | I |
| PIR | C | R | C | A | C | C |

## Related

[RFC template](templates/RFC-template.md) · [Example CHG0030001](examples/CHG0030001-deploy-workstation-baseline-gpo.md) ·
[Problem management](problem-management.md) · [Incident management](incident-management.md) ·
[Lab design §5 Group Policy](../docs/01-lab-design.md)
