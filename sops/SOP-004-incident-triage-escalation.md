# SOP-004 · Incident Intake, Triage & Escalation

| Field | Value |
|---|---|
| SOP ID | SOP-004 |
| Owner | Contoso Service Desk |
| Approver | IT Manager (Lucas Moreno) |
| Version / effective date | 1.0 · 2026-11-10 |
| Review cycle | Every 6 months, or when the KPI review shows FCR < 70% or a reopen rate > 5% |
| Related controls | BC-01, BC-07, BC-10 |

## 1. Purpose

Handle every reported disruption the same way, from first contact to closure: log it, verify who is
calling, prioritize it with the Impact × Urgency matrix, fix it at the lowest capable tier, escalate with a
complete handoff, and keep the customer informed at the agreed cadence.

## 2. Scope

- **In scope:** incidents (something is broken or degraded) reported by phone, email, self-service
  portal, chat or walk-up, for Windows, macOS, mobile, network, account and application issues.
- **Out of scope:** service requests (onboarding [SOP-001](SOP-001-new-hire-onboarding.md), offboarding
  [SOP-002](SOP-002-employee-offboarding.md), access requests). Monitoring alerts start in
  [SOP-007](SOP-007-monitoring-alert-response.md) and return here when a person has to troubleshoot.

## 3. Roles (RACI)

| Activity | Service Desk (Tier 1) | Desktop Support (Tier 2) | Resolver groups (Tier 3) | Team lead | Major Incident Manager | Caller |
|---|---|---|---|---|---|---|
| Log, verify identity, categorize, prioritize | R/A | – | – | I | – | C |
| Troubleshoot with KB articles and tools | R/A | C | – | – | – | C |
| Functional escalation with handoff | R | A (accepts) | A (accepts) | I | – | I |
| Hierarchical escalation (SLA risk, P1) | R | R | R | A | R (P1) | I |
| Customer updates at the agreed cadence | A | R | R | I | R (P1) | I |
| Resolve, confirm, close | R | R | R | A | – | C |

## 4. Prerequisites

- ServiceNow access with the `itil` role, plus access to the knowledge base ([../knowledge-base/](../knowledge-base/)).
- Tier 1 uses `hd.tier1` for delegated actions: password reset and unlock in `OU=Users` only. Tier 2 uses
  `hd.tier2`. Never use `adm.tech` for ticket work.
- Diagnostic scripts on the technician workstation (`scripts\powershell\`), and remote assistance tooling
  (lab: Quick Assist). The user must consent before you connect.
- The priority matrix and SLA table ([itil/incident-management.md](../itil/incident-management.md)).

## 5. Procedure

1. **Log every contact.** Every contact gets a ticket, including "quick questions". Set the contact type
   (phone, email, self-service, chat, walk-in).
2. **Identify the caller and the device:**
   - name and `sAMAccountName`
   - department
   - callback number from the directory
   - the CI: look up the device assigned to the caller in the CMDB, e.g. `emma.carter` → `LT-WIN-001`
3. **Verify identity** before any account action (password reset, unlock, MFA change), using an approved
   method from [KB0002](../knowledge-base/KB0002-password-reset-identity-verification.md): callback to the
   directory number, manager verification, or in person with a badge. Record the method.
   `Reset-UserPassword.ps1 -VerificationMethod` writes it into the audit line.
4. **Capture the symptom:**
   - what happened and when it started
   - the exact error text, plus a screenshot
   - what changed recently
   - who else is affected
   - business impact, and any workaround
5. **Check scope before you troubleshoot.** Look for open incidents on the same CI or service, a running
   major incident, recent changes, and red items on the Zabbix dashboard. If the caller is part of a
   bigger issue, link the ticket as a child of the parent incident.
6. **Search the knowledge base** using the symptom wording. Link the KB article you use. If none fits,
   mark the ticket as a *KB candidate* ([itil/knowledge-management.md](../itil/knowledge-management.md)).
7. **Categorize** using the lab taxonomy, for example *Account & Access → account lockout* or
   *Network → dns*. Set the CI.
8. **Prioritize** with Impact × Urgency:

   | Impact ↓ / Urgency → | 1 – High | 2 – Medium | 3 – Low |
   |---|---|---|---|
   | 1 – High (enterprise, a critical service, many users) | **P1** | P2 | P3 |
   | 2 – Medium (a department or group, or a VIP) | P2 | P3 | P4 |
   | 3 – Low (a single user) | P3 | P4 | P5 |

   **VIP rule:** VIPs (for example Finance Manager `olivia.bennett`) are rated at least Impact 2. Don't
   raise a priority beyond the matrix without team lead approval.
9. **P1 check.** If the incident meets P1 criteria, call the Major Incident Manager **now** and follow
   [SOP-005](SOP-005-major-incident-communications.md). Don't wait to finish the ticket first.
   **3-in-30 rule:** three or more callers reporting the same symptom within 30 minutes (for example
   several "no network / 169.254" calls, [KB0005](../knowledge-base/KB0005-no-network-apipa-dhcp.md)) is a
   potential major incident even if each ticket looks like P3. Create a parent incident and call the MIM.
10. **Troubleshoot within delegated rights**, using the KB steps and these tools:
    ```powershell
    .\endpoint\Invoke-NetworkTriage.ps1 -InternalHost dc01.corp.contoso.internal   # layered network verdict
    .\endpoint\Get-EndpointHealth.ps1 -Format Html -OutputPath C:\Temp            # disk, memory, uptime, Defender, services
    .\helpdesk\Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter             # lockout state + source computer
    .\endpoint\Invoke-EndpointRemediation.ps1 -Action FlushDns -WhatIf            # dry-run first, then run without -WhatIf
    ```
11. **20-minute rule (functional escalation).** Escalate when either of these is true:
    - there has been no progress after 20 minutes
    - the fix needs physical access, rights you don't have, or an infrastructure change

    Never work around your rights (BC-01), and never change servers, GPOs, DNS or DHCP without a change
    record (BC-07).
12. **Route to the right group:**

    | Symptom area | Escalate to |
    |---|---|
    | Hardware, OS repair or reimage, BitLocker recovery, LAPS, printers, macOS, mobile devices | Contoso Desktop Support |
    | Account or group problems a reset or unlock doesn't fix, access errors, privileged access | Contoso Identity & Access |
    | DNS, DHCP, VPN or Wi-Fi beyond the endpoint (triage points at the network) | Contoso Network Operations |
    | Servers (DC01, MON01), AD DS health, file services, the monitoring platform | Contoso Infrastructure Ops |

13. **Complete the handoff checklist in the work notes** before you reassign:
    - [ ] caller, verified callback number, availability window
    - [ ] device/CI, OS, location (onsite or remote)
    - [ ] exact error text and screenshot attached; start time; how many users affected
    - [ ] steps already taken and the result of each (so Tier 2 doesn't repeat them)
    - [ ] script output attached: `Invoke-NetworkTriage.ps1`, `Get-EndpointHealth.ps1` report,
      `Get-AccountLockoutInfo.ps1` (whichever apply)
    - [ ] KB article used; why the priority was chosen; why you are escalating

    For P1/P2, do a **warm handoff**: call the receiving group's queue or on-call person, don't just
    reassign. Tell the caller who now owns the ticket and when they will hear next.
14. **Hierarchical escalation:**
    - Any ticket at 75% of its resolution SLA: notify the team lead.
    - A P2 with no progress for 1 hour: notify the team lead.
    - A P1: notify the Major Incident Manager immediately.
15. **Keep the customer updated** through *Additional comments* (customer-visible). Internal detail goes in
    *Work notes*. Update cadence: P1 every 30 min, P2 every 2 h, P3 daily, P4 every 2 days, P5 weekly.
16. **Resolve:**
    - Write the resolution as cause + fix, and set the resolution code.
    - Link or update the KB article.
    - Confirm the fix with the caller where possible.
    - Set the state to *Resolved*. The ticket closes automatically after the period defined in
      [itil/incident-management.md](../itil/incident-management.md).
17. **Reopen** if the caller reports during that window that the problem is still there. Reopens count
    toward the ≤ 5% KPI, so write down why the first fix didn't hold.
18. **Spot trends.** Repeated symptoms on the same CI or service (for example, three or more similar
    incidents in 7 days) go to the problem manager ([itil/problem-management.md](../itil/problem-management.md)).
    **Repeat-lockout rule:** if the same account is locked out a second time within 7 days, don't just
    unlock it. Run `Get-AccountLockoutInfo.ps1`, remove the source (saved credentials, `net use`
    mappings, phone mail app; see KB0001 "Repeat lockouts") and link the ticket to the open problem
    record (for example [PRB0040001](../itil/examples/PRB0040001-recurring-account-lockouts.md)).

**Work note standard** — *Issue → Steps taken → Result → Next action*
([template](../itil/templates/ticket-work-note-template.md)). Example for **INC0010001**:

```text
Issue:        Emma Carter (Finance) cannot sign in to LT-WIN-001 since 09:05 - "The referenced account is currently locked out."
Steps taken:  Identity verified by callback to directory number. Get-AccountLockoutInfo.ps1: LockedOut=True,
              BadLogonCount=5, lockout source LT-WIN-001 (event 4740 on PDC emulator). Stale saved credential found in
              Credential Manager and removed. Unlocked with -Unlock.
Result:       User signed in at 09:18; no new bad-password events after 15 minutes.
Next action:  Resolved with KB0001 linked. If lockouts recur within 7 days, raise to problem management.
```

## 6. Controls & evidence

| Control | How this SOP meets it | Evidence |
|---|---|---|
| BC-01 Least privilege | Tier 1/Tier 2 act only through delegated accounts; escalate instead of borrowing rights | Ticket shows which account performed each action |
| BC-07 Change control | No infrastructure change without a CHG; emergency fixes during a P1 follow SOP-005 | CHG reference in the work notes |
| BC-10 Logging & monitoring | Every contact is logged; identity verification and actions are recorded | Incident record, audit lines from scripts |

## 7. SLA / OLA

| Priority | Response | Resolution | Customer updates |
|---|---|---|---|
| P1 Critical | 15 min | 4 h | Every 30 min |
| P2 High | 30 min | 8 h | Every 2 h |
| P3 Moderate | 2 h | 24 h | Daily |
| P4 Low | 8 h | 72 h | Every 2 days |
| P5 Planning | 24 h | 120 h | Weekly |

**OLA:** a resolver group acknowledges an escalated ticket within the response target of its priority.
The SLA clock does **not** reset when a ticket is reassigned. Tier 1 target: FCR ≥ 70%.

## 8. Exceptions

| Situation | Handling |
|---|---|
| Caller's identity can't be verified | No account changes. Offer a callback to the directory number or ask the manager to verify. Record the attempt. |
| Possible security incident (phishing click, malware alert, suspicious sign-in) | Category *Security*. Tell the user not to delete anything. Disconnect the device from the network if malware is suspected. Escalate immediately; don't troubleshoot on your own. |
| Lost or stolen device | Switch to [SOP-006](SOP-006-lost-stolen-device.md) |
| After hours | P1/P2 go to the on-call person by phone. P3–P5 are logged and handled the next business day, and the caller is told so. |
| Caller unreachable before resolving | Three contact attempts on different days, then resolve with the code for no response. The caller can reopen the ticket. |

## 9. Related documents

- [itil/incident-management.md](../itil/incident-management.md) · [itil/problem-management.md](../itil/problem-management.md) ·
  [itil/knowledge-management.md](../itil/knowledge-management.md) · [Work note template](../itil/templates/ticket-work-note-template.md)
- [SOP-005 Major incident](SOP-005-major-incident-communications.md) · [SOP-007 Monitoring alert response](SOP-007-monitoring-alert-response.md)
- Frequent KBs: [KB0001](../knowledge-base/KB0001-account-lockout.md) · [KB0004](../knowledge-base/KB0004-dns-resolution-failure.md) ·
  [KB0005](../knowledge-base/KB0005-no-network-apipa-dhcp.md) · [KB0007](../knowledge-base/KB0007-mapped-drive-access-denied.md) ·
  [KB0013](../knowledge-base/KB0013-low-disk-space-slow-performance.md)
- Practice scenarios: [docs/06-lab-scenarios.md](../docs/06-lab-scenarios.md)

## 10. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.9 | 2026-11-03 | Contoso Service Desk | Draft for review |
| 1.0 | 2026-11-10 | Contoso Service Desk | Approved by IT Manager; handoff checklist and routing table added |
