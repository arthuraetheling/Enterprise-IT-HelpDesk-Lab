# CHG00#####: <Short description: what changes, where>

> **How to use:** copy this file to `itil/examples/CHG00#####-<slug>.md`, or paste each section into the
> matching ServiceNow change field ([field mapping](../change-management.md#6-rfc-contents-servicenow-field-mapping)).
> Delete the *italic guidance* as you fill it in. Rules: [change management](../change-management.md).

## 1. Summary

| Field | Value |
|---|---|
| Change number | CHG00##### |
| Type | Standard / Normal / Emergency |
| Category | *Group Policy · DNS · DHCP · Active Directory · Endpoint · Monitoring · ITSM integration* |
| Requested by | |
| Implementer (assigned to) | *Privileged work uses `adm.tech`* |
| Assignment group | *e.g. Contoso Infrastructure Ops* |
| Peer reviewer | *Must not be the implementer* |
| Approval route | *Low: peer + change manager · Medium: CAB · High: CAB + IT Manager + business owner · Emergency: ECAB* |
| Affected CIs (CMDB) | *e.g. DC01, LT-WIN-001, LT-WIN-002* |
| Linked records | *PRB / INC / RITM numbers* |
| Planned start – end | YYYY-MM-DD HH:MM – HH:MM ET |
| Window / freeze check | *Tue/Thu 18:00–21:00 ET; not in a freeze period; no conflicting change on the same CIs* |

## 2. Description and justification

- **What exactly changes:** *objects, settings and values, before → after*
- **Why:** *business reason, linked problem, control objective (BC-xx)*
- **If we don't:** *risk of not changing*

## 3. Risk and impact assessment

| Factor | 1 | 2 | 3 | Score |
|---|---|---|---|---|
| Blast radius | ≤ 5 users/devices | a department / ≤ 25 | enterprise / > 25 or core service | |
| Criticality of CIs | non-critical | business-important | core (AD DS, DNS, DHCP, network, monitoring) | |
| Testing | tested with evidence | partially tested | untested | |
| Backout | scripted and tested, < 15 min | documented but untested, or 15–60 min | none, or > 60 min | |
| Complexity / experience | done before, ≤ 5 steps | done before, complex | first time / multiple teams | |
| **Total** (5–7 Low · 8–11 Medium · 12–15 High) | | | | **__ / 15** |

- **User impact during implementation:** *outage? reboot? sign-out needed?*
- **User impact after implementation:** *what users will notice*
- **Conflicts checked:** *change schedule, other changes on the same CIs*

## 4. Communication plan

| Audience | Message | Channel | When | Owner |
|---|---|---|---|---|
| Affected users | | Email / Teams | | |
| Contoso Service Desk | FAQ and expected calls | Huddle / KB | Before start | |

## 5. Pre-implementation checklist

- [ ] Peer review complete (name, date)
- [ ] Approval recorded on the CHG
- [ ] Backups: VM snapshot `pre-CHG00#####` · `Backup-GPO` · `Export-DhcpServer` · current values recorded
- [ ] Pilot evidence attached (if applicable)
- [ ] Service Desk briefed; KB updated or drafted if the procedure changes

## 6. Implementation plan

| # | Action (command or console path) | Owner | Expected result |
|---|---|---|---|
| 1 | | | |
| 2 | | | |

## 7. Test and verification plan

| Check | How | Pass criteria | Actual |
|---|---|---|---|
| | *e.g. `gpresult /r /scope computer` on LT-WIN-002* | *GPO listed under Applied Group Policy Objects* | |

## 8. Backout plan

- **Trigger:** *observable condition that forces backout (e.g. users cannot sign in)*
- **Decision point:** *latest time in the window to decide (e.g. 20:30 ET)*
- **Steps:**
- **Time to back out:** *minutes*
- **Verification after backout:**

## 9. Approvals

| Role | Name | Decision | Date / time | Conditions |
|---|---|---|---|---|
| Peer reviewer | | | | |
| Change manager / CAB | | | | |

## 10. Implementation record

| Time (ET) | Step / event | Result |
|---|---|---|
| | | |

## 11. Post-implementation review

| Item | Value |
|---|---|
| Outcome | Successful / Successful with issues / Unsuccessful (backed out) |
| Incidents caused | *INC numbers or "none"* |
| Deviations from plan | |
| Lessons and follow-ups | |
| CMDB updated | *Yes / N/A: which CIs* |
| Close code | |
