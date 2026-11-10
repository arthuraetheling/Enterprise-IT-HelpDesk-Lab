# SOP-002 · Employee Offboarding

| Field | Value |
|---|---|
| SOP ID | SOP-002 |
| Owner | Contoso Identity & Access |
| Approver | IT Manager (Lucas Moreno) |
| Version / effective date | 1.0 · 2026-11-10 |
| Review cycle | Annually, after every involuntary termination, and after any audit finding |
| Related controls | BC-02, BC-05, BC-06, BC-11 |

## 1. Purpose

Remove a departing person's access on time, keep their business data available to the manager, recover and
sanitize company devices, and leave an auditable record. Deprovisioning is one of the controls auditors
test most often (BC-05).

## 2. Scope

- **In scope:** planned departures (resignation, retirement, contract end) and immediate/involuntary
  terminations of employees and contractors. Covers every identity the person holds: the standard account
  (`first.last`), any privileged account in `OU=Admins`, device and mobile access, and shared credentials
  they knew.
- **Out of scope:** department transfers and leave of absence (§8).

## 3. Roles (RACI)

| Activity | HR | Manager | Security | Service Desk | Identity & Access | Desktop Support |
|---|---|---|---|---|---|---|
| Raise the termination RITM or call | R/A | C | C | I | I | I |
| Verify an immediate-termination call | C | – | C | R/A | I | – |
| Disable the account and strip access | I | I | I | – | R/A | – |
| End sessions; clean up privileged access | – | – | C | – | R/A | C |
| Hand over data and mailbox | – | A | – | – | R | C |
| Recover the device, wipe or reimage it, update the CMDB | – | R (collects the device) | I | – | I | R/A |
| Close the RITM with evidence | I | I | I | – | A | R |

## 4. Prerequisites

- **Planned departure:** an HR RITM with termination type, effective date/time, manager, data handoff
  instructions and the legal-hold flag. Example: **RITM0010002**, `ava.turner`, effective 2026-11-20 17:00.
- **Immediate termination:** a call from HR or Security. The Service Desk creates the RITM while still on
  the call.
- An Identity & Access analyst account with rights on `OU=Users`, `OU=Admins` and `OU=Disabled` (lab:
  `adm.tech`), in an elevated Windows PowerShell 5.1 session with the AD module, working directory
  `scripts\powershell\`.
- CMDB access to list the devices assigned to the user.

## 5. Procedure

### A. Validate (Service Desk / Identity & Access)

1. **Planned departure:** check that HR raised the RITM and note the effective date/time.
   **Immediate termination:** end the call and **call HR back** on the number in the company directory,
   never on a number the caller gives you. Record who confirmed and when.
2. Check the **legal-hold** flag. If it is set, still disable access, but do not delete or wipe any data
   (see §8).
3. List the person's assets in the CMDB (CIs with *Assigned to* = the user, e.g. `LT-WIN-003`) and add
   them to the RITM.
4. Look for other identities the person holds, and groups they manage:
   ```powershell
   Get-ADUser -Filter "GivenName -eq 'Ava' -and Surname -eq 'Turner'" -SearchBase "OU=Contoso,DC=corp,DC=contoso,DC=internal" |
       Select-Object SamAccountName, DistinguishedName
   Get-ADGroup -Filter * -Properties ManagedBy | Where-Object ManagedBy -like 'CN=Ava Turner,*' | Select-Object Name
   ```
   Reassign any group the person manages to the manager before you continue.

### B. Disable access (at the effective time; immediate terminations within 1 hour of the verified call)

5. Do a dry run:
   ```powershell
   .\helpdesk\Remove-Employee.ps1 -SamAccountName ava.turner -TicketNumber RITM0010002 -WhatIf
   ```
6. Run it without `-WhatIf`. The script:
   - disables the account
   - resets the password to a random value
   - exports the group memberships to CSV, then removes them
   - moves the account to `OU=Disabled`
   - stamps the description with the ticket number and date

   Keep the CSV. It is your audit evidence and your rollback record.
7. Verify:
   ```powershell
   Get-ADUser ava.turner -Properties Description, MemberOf |
       Select-Object SamAccountName, Enabled, DistinguishedName, Description, @{n='GroupCount';e={$_.MemberOf.Count}}
   ```
   Expected results:
   - `Enabled = False`
   - DN under `OU=Disabled,OU=Contoso`
   - description contains `RITM0010002`
   - `GroupCount = 0` (*Domain Users* is the primary group, isn't listed in `MemberOf`, and stays)
8. End live sessions. Disabling the account does not end a session that is already open, and Kerberos tickets
   already issued keep working until they expire.
   ```powershell
   quser /server:LT-WIN-003              # note the session ID
   logoff <ID> /server:LT-WIN-003
   ```
   **(production)** Revoke cloud sign-in sessions and MFA methods, and ask Contoso Network Operations to drop
   any VPN session.
9. **Privileged staff (IT):**
   - Repeat steps 5–7 for each of their accounts in `OU=Admins`.
   - If they were in `GG-HelpDesk-Tier2`, expire the LAPS passwords of the devices they used, so the
     passwords rotate at the next policy processing:
     ```powershell
     Set-LapsADPasswordExpirationTime -Identity LT-WIN-001
     ```
   - Rotate any shared or service credential they knew (e.g. `svc-scanner`) under a change record
     ([itil/change-management.md](../itil/change-management.md)).

### C. Hand over data (Identity & Access with the manager)

10. Home folder `\\DC01\Home$\ava.turner`: do what the manager asked. Either copy business files into the
    department share, or give the manager read access for a limited time (30 days, recorded in the RITM).
    Then archive the folder.
11. **(production)** Convert the mailbox to a shared mailbox, give the manager access and set an auto-reply.
    Transfer OneDrive content. Remove licenses after 30 days.

### D. Recover and sanitize devices (Desktop Support)

12. Collect every listed device on the last day. Remote staff get a prepaid shipping box with tracking.
    - Not returned within 5 business days: escalate to the manager and HR.
    - Not returned after 10 business days: treat the device as lost ([SOP-006](SOP-006-lost-stolen-device.md)).
13. Laptop: check that there is no legal hold, then sanitize and reimage it per
    [SOP-003 §D](SOP-003-laptop-provisioning-refresh.md). Things to know:
    - BitLocker recovery passwords are stored under the computer object in AD, and reimaging creates new
      ones. Do **not** delete the computer object to clean up, or the old keys are lost during the
      retention period.
    - Windows LAPS gives the reimaged device a new local admin password, so nothing needs rotating across
      the fleet (BC-02).
14. Mobile device:
    - corporate device: full wipe and removal from MDM
    - BYOD: selective wipe of corporate apps and data only
15. CMDB: clear *Assigned to*. Set *Status* to *In stock* after a reimage, or to *Retired* at end of life.
    Link the RITM.

### E. Close

16. Attach the evidence listed in §6, add the work note
    ([template](../itil/templates/ticket-work-note-template.md)) and close the RITM.
17. Disabled accounts stay in `OU=Disabled` for the retention period (lab: 90 days). The quarterly access
    review ([SOP-008](SOP-008-quarterly-access-review.md)) confirms they no longer hold any groups.

## 6. Controls & evidence

| Control | Evidence |
|---|---|
| BC-05 Timely deprovisioning | Script output with timestamp compared to the effective time (planned: same business day; immediate: ≤ 1 hour) |
| BC-06 Periodic access review | Group-membership export CSV (input to the next review) |
| BC-02 Unique local admin passwords | `Set-LapsADPasswordExpirationTime` output (privileged IT staff only) |
| BC-11 CMDB accuracy | CI status change, device return record, wipe confirmation |
| Session termination | `quser` / `logoff` output in the work notes |

## 7. SLA / OLA

| Step | Target |
|---|---|
| Immediate termination: account disabled and sessions ended | ≤ 1 hour from verified notification |
| Planned departure: account disabled | At the effective time, same business day |
| Data handoff completed | ≤ 5 business days |
| Devices returned | ≤ 5 business days (treated as lost after 10) |
| Device sanitized and CMDB updated | ≤ 10 business days after return |
| RITM closed | ≤ 10 business days |

## 8. Exceptions

| Situation | Handling |
|---|---|
| Legal hold | Disable access as normal. Do not wipe devices or delete mailboxes or home folders. Label the assets *Legal hold* in the CMDB. Legal approves the release. |
| Leave of absence | Not an offboarding. Run `Disable-ADAccount ava.turner` only and keep the groups. Re-enable on return once the manager confirms. |
| Department transfer | Handle as an access-change request: remove the old department group, add the new one. Do not disable the account. |
| HR notified IT late (termination already effective) | Run the procedure immediately. Record the gap and report it to the IT Manager as a control exception. |
| Departing privileged/IT staff | Consult Security. Review their recent privileged activity. Rotate every shared secret under a change. |

## 9. Related documents

- [SOP-003 Laptop provisioning, refresh & retirement](SOP-003-laptop-provisioning-refresh.md) ·
  [SOP-006 Lost or stolen device](SOP-006-lost-stolen-device.md) ·
  [SOP-008 Quarterly access review](SOP-008-quarterly-access-review.md)
- [KB0017 Mobile enrollment, email & lost device](../knowledge-base/KB0017-mobile-enrollment-email-lost-device.md)
- [docs/01-lab-design.md](../docs/01-lab-design.md) §4 (AD design), §10 (business controls)
- Script: [`Remove-Employee.ps1`](../scripts/powershell/helpdesk/Remove-Employee.ps1)

## 10. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.9 | 2026-11-03 | Contoso Identity & Access | Draft for review |
| 1.0 | 2026-11-10 | Contoso Identity & Access | Approved by IT Manager; 1-hour target for immediate terminations added |
