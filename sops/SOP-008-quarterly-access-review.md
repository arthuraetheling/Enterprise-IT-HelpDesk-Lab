# SOP-008 · Quarterly Access Review

| Field | Value |
|---|---|
| SOP ID | SOP-008 |
| Owner | Contoso Identity & Access |
| Approver | IT Manager (Lucas Moreno) |
| Version / effective date | 1.0 · 2026-11-10 |
| Review cycle | Annually, or after an audit finding on access management |
| Related controls | BC-06 (primary), BC-01, BC-04, BC-05 |

## 1. Purpose

Find and fix access that is no longer appropriate: stale accounts, unmanaged exceptions, leftovers from
offboarding, and excess privilege. Managers attest to their teams' access, and the result is an evidence
package an auditor can re-perform.

## 2. Scope

- Every account in `corp.contoso.internal`:
  - standard users in `OU=Users,OU=Contoso`
  - privileged accounts: `OU=Admins`, `Domain Admins`, `Enterprise Admins`, `Schema Admins`,
    `Administrators`, `GG-HelpDesk-Tier1`, `GG-HelpDesk-Tier2`
  - service accounts in `OU=ServiceAccounts`
  - disabled accounts in `OU=Disabled`
- Department access through `GG-<Dept>` → `DL-FS-<Dept>-RW` (AGDLP), help desk delegation, and Windows
  LAPS read rights.
- **Schedule:** the first 10 business days of January, April, July and October.

## 3. Roles (RACI)

| Activity | Identity & Access | Department managers | IT Manager | Security / Compliance | Internal audit |
|---|---|---|---|---|---|
| Open the review RITM, run the report | R/A | – | I | I | – |
| Attest standard users and department groups | C | R/A | I | – | – |
| Attest privileged access and delegation | R | – | A | C | – |
| Remediate findings | R/A | C | I | I | – |
| Approve exceptions | R | C | A | C | I |
| Assemble the evidence package and sign off | R | – | A | C | I |

Department managers: Olivia Bennett (Finance), Hannah Brooks (HR), Lucas Moreno (IT), Marcus Reed (Sales),
Daniel Kim (Operations).

## 4. Prerequisites

- An elevated Windows PowerShell 5.1 session with the AD module, working directory `scripts\powershell\`,
  run under an Identity & Access analyst account.
- The previous quarter's evidence package and the current exception register (§8).
- A review RITM with one catalog task per manager. Example: **RITM0010050** *Q4-2026 quarterly access
  review*, tasks `SCTASK0010051`–`SCTASK0010055`.

## 5. Procedure

1. **Open the cycle (business day 1).** Create the RITM and set the review cut-off date and time. All
   evidence refers to that point in time.
2. **Run the report:**
   ```powershell
   .\helpdesk\Get-ADAccessReview.ps1 -InactiveDays 90
   ```
   Save the HTML and CSV reports it produces to the RITM, without editing them. They are the "before"
   evidence.
   > Last-logon data comes from `lastLogonTimestamp`, which only replicates every 9–14 days. A 90-day
   > threshold is safe; don't use thresholds under 14 days.
3. **Collect the supporting evidence** for password policy (BC-04) and delegation (BC-01):
   ```powershell
   Get-ADFineGrainedPasswordPolicy -Filter * | Select-Object Name, Precedence, MinPasswordLength, LockoutThreshold
   Get-ADFineGrainedPasswordPolicySubject -Identity PSO-Standard-Users | Select-Object Name
   Get-ADFineGrainedPasswordPolicySubject -Identity PSO-Privileged-Admins | Select-Object Name
   Get-ADGroupMember -Identity 'Domain Admins' -Recursive | Select-Object SamAccountName
   dsacls "OU=Users,OU=Contoso,DC=corp,DC=contoso,DC=internal" | Select-String "HelpDesk"
   Find-LapsADExtendedRights -Identity "OU=Workstations,OU=Computers,OU=Contoso,DC=corp,DC=contoso,DC=internal"
   ```
4. **Triage each finding by category:**

   | Finding | What it means | Expected action | Remediation SLA |
   |---|---|---|---|
   | **Stale / inactive** | Enabled account with no sign-in in the last 90 days (or never used) | Ask the manager. If the person has left: [SOP-002](SOP-002-employee-offboarding.md). If on leave: record it in the exception register. | 10 business days |
   | **Password never expires** | `PasswordNeverExpires = True` | Allowed only for documented service accounts. `svc-scanner` is exception **EXC-001**. Anyone else: `Set-ADUser <sam> -PasswordNeverExpires $false`. | 10 business days |
   | **Expired but enabled** | The account expiration date has passed but the account is still enabled and keeps its groups (e.g. `legacy.contractor`) | Offboard properly: `.\helpdesk\Remove-Employee.ps1 -SamAccountName legacy.contractor -TicketNumber RITM0010050` | 10 business days |
   | **Disabled with groups** | Offboarding left group memberships behind | Export with `Get-ADPrincipalGroupMembership <sam>`, then `Remove-ADGroupMember`. Record the gap against SOP-002. | 10 business days |
   | **Privileged membership** | Members of privileged or help desk groups | The IT Manager attests each one. Expected members: built-in `Administrator` (break-glass) and `adm.tech` in Domain Admins, `hd.tier1` / `hd.tier2` in their tiers. A daily-use `first.last` account in a privileged group is always a finding. | **2 business days** |

   > **Control test (lab):** `svc-scanner` and `legacy.contractor` are seeded on purpose. If the report
   > doesn't flag both, the review has failed its test of design. Fix the tooling before you continue.
5. **Manager attestation (business days 3–7).** Send each manager their department's users and groups
   (filtered from the CSV) through their catalog task. For each user they answer *Keep*, *Remove* or
   *Change*, with a reason for anything unusual. Remind them on day 5. If there is no answer by day 8,
   escalate to the IT Manager. A missing response never counts as approval.
6. **Remediate.** Do each *Remove*/*Change* decision and each finding under the RITM, with the ticket
   number in every action (Remove-Employee.ps1 stamps it automatically). Privileged findings must be
   closed within 2 business days of identification. All other findings within 10.
7. **Re-run the report** after remediation:
   ```powershell
   .\helpdesk\Get-ADAccessReview.ps1 -InactiveDays 90
   ```
   Only approved exceptions may remain. Attach this "after" report. This is the test of effectiveness.
8. **Assemble the evidence package (by business day 15)** and attach it to the RITM:
   1. "Before" report (HTML + CSV) with run date and operator
   2. Supporting output from step 3
   3. Manager attestations from the catalog tasks
   4. Remediation actions with ticket numbers and timestamps
   5. "After" report
   6. Exception register snapshot
   7. IT Manager sign-off
9. **Close** the RITM with summary metrics:
   - accounts reviewed
   - findings by category
   - percentage remediated within SLA
   - open exceptions
   - attestation completion rate

   Retain the evidence according to the records-retention schedule (lab assumption: 7 years).

## 6. Controls & evidence

| Control | How this SOP meets it | Evidence |
|---|---|---|
| BC-06 Periodic access review | Quarterly report, manager attestation, remediation, re-test | Evidence package (§5 step 8) |
| BC-01 Least privilege | Privileged and delegated rights re-attested by the IT Manager | `Get-ADGroupMember`, `dsacls`, `Find-LapsADExtendedRights` output |
| BC-04 Password & lockout standards | FGPP settings and subjects confirmed every quarter | `Get-ADFineGrainedPasswordPolicy` output |
| BC-05 Timely deprovisioning | *Expired but enabled* and *disabled with groups* findings expose offboarding gaps | Findings traced back to their offboarding RITMs |

## 7. SLA / OLA

| Step | Target |
|---|---|
| Report run and RITM opened | Business days 1–2 of the quarter |
| Manager attestation returned | 5 business days after it is sent |
| Privileged findings remediated | ≤ 2 business days after identification |
| All other findings remediated | ≤ 10 business days after identification |
| Evidence package complete with IT Manager sign-off | By business day 15 |

## 8. Exceptions

Exceptions are recorded in the **exception register**, reviewed every quarter, and expire after 12 months
at most.

| ID | Account | Finding | Justification | Compensating controls | Owner | Approved by / date | Review by |
|---|---|---|---|---|---|---|---|
| EXC-001 | `svc-scanner` | Password never expires | Scan-to-folder device can't rotate its credential automatically | Long random password stored in the IT vault; no privileged groups; rotated yearly under a standard change; account limited to scanning | Contoso Infrastructure Ops | IT Manager · 2026-11-10 | 2027-11-10 |

| Situation | Handling |
|---|---|
| Manager unavailable | Their manager (or the IT Manager for IT) attests. Record the delegation. |
| Manager disputes a finding | Identity & Access and the manager agree within the SLA. Unresolved disputes go to the IT Manager, whose decision is final and recorded. |
| Account under legal hold | Keep it disabled and retained. Mark it in the register; don't delete it. |
| Urgent risk found mid-review (e.g. unknown Domain Admin) | Remove access **immediately**, raise a Security incident, and continue the review |

## 9. Related documents

- [SOP-002 Employee offboarding](SOP-002-employee-offboarding.md) · [SOP-001 New hire onboarding](SOP-001-new-hire-onboarding.md)
- [docs/01-lab-design.md](../docs/01-lab-design.md) §4 (AD design, FGPP, delegation), §10 (business controls)
- [itil/change-management.md](../itil/change-management.md) (standard change for `svc-scanner` rotation)
- Script: [`Get-ADAccessReview.ps1`](../scripts/powershell/helpdesk/Get-ADAccessReview.ps1)

## 10. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.9 | 2026-11-03 | Contoso Identity & Access | Draft for review |
| 1.0 | 2026-11-10 | Contoso Identity & Access | Approved by IT Manager; exception register and control-test note added |
