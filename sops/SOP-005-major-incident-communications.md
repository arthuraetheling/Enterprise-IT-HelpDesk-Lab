# SOP-005 · Major Incident (P1) Management & Communications

| Field | Value |
|---|---|
| SOP ID | SOP-005 |
| Owner | Contoso Service Desk (Major Incident Manager role) |
| Approver | IT Manager (Lucas Moreno) |
| Version / effective date | 1.0 · 2026-11-10 |
| Review cycle | Annually, and after every post-incident review (PIR) |
| Related controls | BC-07, BC-10 |

## 1. Purpose

Restore a critical service as fast as possible with one coordinated team, one source of truth and
predictable communications, then learn from the outage through a post-incident review (PIR).

## 2. Scope

**P1 criteria** (any one is enough):

- Impact 1 × Urgency 1 on the priority matrix: a critical service is down or badly degraded for the
  whole company or several departments. Examples: sign-in/AD DS unavailable, no new DHCP leases,
  file services down during month-end close.
- A Zabbix *Disaster* alert on a server, confirmed by the on-call engineer.
- A security incident with active data exposure (Security leads; communications are need-to-know, see §8).
- Rule of thumb: 10 or more users, or 2 or more departments, reporting the same symptom within
  15 minutes. Evaluate for P1 immediately.

## 3. Roles (RACI)

| Activity | Major Incident Manager (MIM) | Technical lead | Communications lead | Scribe | Resolver engineers | IT Manager | Service Desk |
|---|---|---|---|---|---|---|---|
| Declare P1, open bridge, assign roles | R/A | C | I | I | I | I | R (detects) |
| Diagnose and restore | A | R | – | I | R | I | – |
| Stakeholder and status updates | A | C | R | C | – | I | R (front line) |
| Timeline and decision log | A | C | – | R | C | – | – |
| Emergency change approval (ECAB) | R | C | – | I | C | A | – |
| PIR within 5 business days | A | R | C | R | C | I | C |

The MIM is the Service Desk lead on duty. The IT Manager (Lucas Moreno) acts as MIM if the lead is
unavailable, and is the executive escalation point.

## 4. Prerequisites

- A standing bridge (Teams meeting or phone bridge) and the stakeholder distribution list (§5, step 6).
- Templates: [major-incident-communication-template.md](../itil/templates/major-incident-communication-template.md).
- ServiceNow parent/child incident linking. If the Major Incident workbench is enabled, use it; otherwise
  prefix the short description with `[MAJOR]`.
- Access to Zabbix (`http://zabbix.corp.contoso.internal`) and the change process
  ([itil/change-management.md](../itil/change-management.md)).

## 5. Procedure

### Phase 1 — Declare (target: within 15 minutes of detection)

1. Anyone who suspects a P1 calls the MIM **immediately**. A phone call, not a reassignment.
2. The MIM validates the criteria, sets **Priority 1** on the parent incident (example: **INC0010007**,
   DHCP scope outage) and records the declaration time.
3. Open the bridge and assign roles: MIM, technical lead (from the owning resolver group, e.g. Contoso
   Infrastructure Ops), communications lead, scribe.
4. Service Desk: link every new related call as a **child** of the parent (*Parent incident* field) and
   give callers the scripted holding message. Don't troubleshoot child incidents separately.
5. The communications lead sends the **initial notification** within 15 minutes of declaration. It covers:
   - what is affected and who
   - when it started
   - any workaround
   - when the next update will come
6. Stakeholder list:

   | Audience | Channel |
   |---|---|
   | IT Manager (Lucas Moreno), all resolver groups | Bridge + Teams channel |
   | Department managers: Olivia Bennett (Finance), Hannah Brooks (HR), Marcus Reed (Sales), Daniel Kim (Operations) | Email + phone for P1 start/resolution |
   | All staff (when broadly affected) | Status page / all-staff email |
   | Security (if security-related) | Phone; details on a need-to-know basis |

### Phase 2 — Restore

7. The technical lead drives diagnosis. **Restoration (a workaround) comes before root cause.** Root cause
   is the problem record's job.
8. Any configuration change goes through an **emergency change**:
   - verbal ECAB approval from the IT Manager, recorded in the work notes
   - the CHG record completed retrospectively within 1 business day
   - a backout point first (lab: VMware snapshot)
9. The scribe logs a timestamped timeline in the work notes: every observation, action, decision and owner.
10. Send updates **every 30 minutes**, even when there is no news ("still investigating, next update at
    10:30"). The Service Desk refreshes its scripted message after each update.
11. Not restored within 2 hours: the MIM briefs the IT Manager and engages vendors if needed (record the
    vendor ticket number).

### Phase 3 — Resolve

12. Validate restoration:
    - users from each affected group confirm the service works
    - the Zabbix problem is resolved
    - checks such as `.\endpoint\Invoke-NetworkTriage.ps1` or `Get-DhcpServerv4ScopeStatistics` look normal
13. Send the **resolution notice** within 30 minutes of restoration. It covers:
    - what happened, in plain language
    - when it was fixed
    - what users need to do (e.g. restart or run `ipconfig /renew`)
    - how to report anything still wrong
14. Resolve the parent incident. Child incidents are resolved with the parent's resolution notes.
15. Open a **problem record** (PRB) immediately. Every P1 gets one
    ([itil/problem-management.md](../itil/problem-management.md)).

### Phase 4 — Post-incident review (within 5 business days)

16. The MIM runs a blameless PIR using the timeline. It covers:
    - impact (users, duration)
    - detection (how and when)
    - root cause (from the problem investigation)
    - what went well, and what didn't
    - action items, each with an owner and a due date (changes, monitoring improvements, KB updates)

    Example: [INC0010007 DHCP scope outage PIR](../itil/examples/INC0010007-dhcp-scope-outage-pir.md).
17. Send the PIR summary to the stakeholders and track each action to closure in the problem record.

### Handover during a long P1

18. If the MIM or technical lead changes shift, hand over both verbally and in the work notes:
    - current status and impact
    - working hypotheses
    - actions in flight and who owns each
    - the next update time
    - open questions and key contacts

    The outgoing person stays on the bridge for 15 minutes after the handover.

## 6. Controls & evidence

| Control | Evidence |
|---|---|
| BC-07 Change control | Emergency CHG with ECAB approval recorded, backout plan, retrospective completion ≤ 1 business day |
| BC-10 Logging & monitoring | Parent/child incidents, timestamped timeline, Zabbix problem history, communication log |
| Continual improvement | PIR document and tracked action items in the problem record |

## 7. SLA / OLA

| Item | Target |
|---|---|
| Response (P1 acknowledged, bridge open) | 15 min |
| Initial notification | ≤ 15 min after declaration |
| Updates | Every 30 min until resolved |
| Resolution target | 4 h |
| Resolution notice | ≤ 30 min after restoration |
| PIR held and distributed | ≤ 5 business days |

## 8. Exceptions

| Situation | Handling |
|---|---|
| Security incident | Security is the incident lead. Communications are need-to-know only: no technical details on the status page. Legal/Compliance decide on any external notification. |
| Monitoring platform (MON01) is part of the outage | Confirm status manually (direct checks on DC01, user reports) and say in updates that alerting is degraded |
| Third-party / cloud provider outage | Track the provider's status and ticket number. The MIM keeps the communication cadence even when IT can't fix it. |
| P1 downgraded after investigation | The MIM records the reason, sends a short "downgraded to P2" notice and closes the bridge. No PIR is required unless the IT Manager asks for one. |
| After hours | The on-call engineer pages the on-call MIM. The same cadence applies. |

## 9. Related documents

- [itil/incident-management.md](../itil/incident-management.md) · [itil/problem-management.md](../itil/problem-management.md) ·
  [itil/change-management.md](../itil/change-management.md)
- [Major incident communication template](../itil/templates/major-incident-communication-template.md) ·
  [Example PIR: INC0010007](../itil/examples/INC0010007-dhcp-scope-outage-pir.md)
- [SOP-004 Incident triage & escalation](SOP-004-incident-triage-escalation.md) · [SOP-007 Monitoring alert response](SOP-007-monitoring-alert-response.md)
- [KB0005 No network / APIPA (DHCP)](../knowledge-base/KB0005-no-network-apipa-dhcp.md) ·
  [docs/04-monitoring-alerting.md](../docs/04-monitoring-alerting.md) · [docs/06-lab-scenarios.md](../docs/06-lab-scenarios.md)

## 10. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.9 | 2026-11-03 | Contoso Service Desk | Draft for review |
| 1.0 | 2026-11-10 | Contoso Service Desk | Approved by IT Manager; handover checklist added |
