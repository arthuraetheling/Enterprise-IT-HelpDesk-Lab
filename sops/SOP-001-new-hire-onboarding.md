# SOP-001 · New Hire Onboarding

| Field | Value |
|---|---|
| SOP ID | SOP-001 |
| Owner | Contoso Identity & Access |
| Approver | IT Manager (Lucas Moreno) |
| Version / effective date | 1.0 · 2026-11-10 |
| Review cycle | Annually, or after any related audit finding |
| Related controls | BC-01, BC-03, BC-04, BC-09, BC-11 |

## 1. Purpose

Give every new employee an identity with only the access they need, a compliant laptop, and a Day 1 that
works. The process also produces the evidence auditors ask for: approvals, group membership, encryption
status and asset assignment.

## 2. Scope

- **In scope:** employees and contractors joining Finance, HR, IT, Sales or Operations; Windows
  (`LT-WIN-###`) and Mac (`LT-MAC-###`) laptops; corporate or BYOD mobile devices.
- **Out of scope:** department transfers (access-change request), privileged/admin accounts (separate
  request approved by the IT Manager), rehires whose old account is still in `OU=Disabled` (see §8).

## 3. Roles (RACI)

| Activity | HR | Hiring manager | Identity & Access | Desktop Support | Service Desk | New hire |
|---|---|---|---|---|---|---|
| Submit the new-hire RITM ≥ 5 business days before the start date | R/A | C | I | I | I | – |
| Approve default and extra access | C | A | R | – | – | – |
| Create the account, groups and home folder | I | I | R/A | – | – | – |
| Provision the laptop and update the CMDB ([SOP-003](SOP-003-laptop-provisioning-refresh.md)) | – | I | I | R/A | – | – |
| Day 1 session (sign-in, MFA, apps, mobile) | – | I | – | R/A | C | R |
| Close the RITM with evidence | I | I | A | R | – | – |

## 4. Prerequisites

- An approved RITM from the *New Hire Onboarding* catalog item with: legal and preferred name, department,
  title, manager (`sAMAccountName`), start date, employment type (employee, or contractor + end date),
  hardware profile (Windows/Mac), mobile (corporate/BYOD/none), and any **extra** access with the data
  owner's approval.
- An Identity & Access analyst account that can create users in `OU=Users,OU=Contoso` (lab: `adm.tech`;
  the approved RITM is the authorization record), plus a Desktop Support analyst (`hd.tier2`) for the device.
- An elevated Windows PowerShell 5.1 session with the Active Directory module (DC01 or an RSAT workstation),
  working directory `scripts\powershell\`.
- A laptop provisioned per SOP-003 with CMDB status *In stock*, and ServiceNow access.

## 5. Procedure

### A. Validate the request (Identity & Access, start date −5 business days)

1. Open the RITM. Example: **RITM0010001**, Ava Turner, Sales, Account Executive, manager `marcus.reed`.
2. Check that HR raised the request, the hiring manager approved it, and the department is one of the five
   standard departments. If any of these is missing, return the RITM to HR.
3. Check for an existing account:
   ```powershell
   Get-ADUser -Filter "GivenName -eq 'Ava' -and Surname -eq 'Turner'" |
       Select-Object SamAccountName, Enabled, DistinguishedName
   ```
   - No result: continue.
   - Account found in `OU=Disabled`: this is a rehire. Stop and follow §8.
   - `ava.turner` belongs to someone else: stop and follow the *name collision* row in §8.

### B. Create the identity (Identity & Access)

4. Do a dry run and review what the script plans to do:
   ```powershell
   .\helpdesk\New-Employee.ps1 -FirstName Ava -LastName Turner -Department Sales -Title "Account Executive" `
       -Manager marcus.reed -TicketNumber RITM0010001 -WhatIf
   ```
5. Run the same command without `-WhatIf`. The script:
   - creates the account in `OU=Sales,OU=Users,OU=Contoso`
   - adds it to the department and all-staff groups
   - sets title, department and manager
   - creates `\\DC01\Home$\ava.turner` (the H: drive)
   - generates a temporary password
   - prints a ticket note

   For several hires with the same start date, use `.\helpdesk\New-Employee.ps1 -CsvPath .\new-hires.csv`
   (one row per hire, with the same fields as the parameters).
6. Treat the temporary password as a secret. **Never** put it in the ticket, an email or a chat message. Seal
   it for the Day 1 handover. The ticket note you paste must not contain it.
7. Verify the account:
   ```powershell
   Get-ADUser ava.turner -Properties Department, Title, Manager, HomeDirectory, HomeDrive, pwdLastSet |
       Select-Object SamAccountName, Enabled, DistinguishedName, Department, Title, Manager, HomeDirectory, HomeDrive, pwdLastSet
   Get-ADPrincipalGroupMembership ava.turner | Select-Object -ExpandProperty Name
   Get-ADUserResultantPasswordPolicy ava.turner     # expect PSO-Standard-Users
   Test-Path \\DC01\Home$\ava.turner
   ```
   Expected results:
   - DN under `OU=Sales,OU=Users,OU=Contoso`
   - groups `GG-Sales`, `GG-AllStaff` and `Domain Users`
   - `HomeDrive` = `H:`
   - `pwdLastSet` = `0` (password must change at next logon). If it isn't, run
     `Set-ADUser ava.turner -ChangePasswordAtLogon $true`.
8. Extra access listed in the RITM: add only the approved **global** (`GG-`) group, following AGDLP. Never
   add the user directly to a folder ACL or to a `DL-` group. Record who approved it.
9. Contractors: set the end date from the RITM, for example
   `Set-ADAccountExpiration -Identity ava.turner -DateTime '2027-07-01'`. Expiry blocks sign-in, but
   [SOP-002](SOP-002-employee-offboarding.md) must still run on the end date.

### C. Prepare and assign the device (Desktop Support, ≥ 1 business day before the start date)

10. Take a laptop provisioned per [SOP-003](SOP-003-laptop-provisioning-refresh.md), for example `LT-WIN-003`.
    Mac hardware profile: see SOP-003 §B.
11. On the laptop, refresh the inventory and push it to the CMDB:
    ```powershell
    .\endpoint\Get-EndpointInventory.ps1 -OutputPath C:\ProgramData\Contoso\Inventory
    .\integration\Sync-InventoryToCmdb.ps1 -InventoryPath C:\ProgramData\Contoso\Inventory\LT-WIN-003.json `
        -InstanceUrl https://devNNNNN.service-now.com -Credential (Get-Credential)
    ```
12. In ServiceNow, open the CI and check that serial number, model, OS and RAM match the device. Then set
    **Assigned to** = `ava.turner`, **Department** = Sales, **Status** = *Installed*.
13. Compliance gate. Every check must pass before handover:
    ```powershell
    .\endpoint\Test-EndpointCompliance.ps1     # BitLocker, Defender, firewall, OS build, patch age, screen lock, local admins, LAPS
    .\endpoint\Get-EndpointHealth.ps1 -Format Html -OutputPath C:\ProgramData\Contoso\Reports
    $LASTEXITCODE                              # 0 = OK
    ```
    If anything fails, fix it per SOP-003 and run the checks again. Attach both reports to the RITM.

### D. Day 1 (Desktop Support with the new hire)

14. Verify identity in person, matching photo ID or badge to the HR record, before you hand over the sealed
    temporary password.
15. The new hire signs in to the laptop as `CONTOSO\ava.turner` on the office network. Windows forces a
    password change. The new password must meet `PSO-Standard-Users`: at least 12 characters, complex, and
    not one of the last 24.
16. Confirm the drives:
    - **H:** is the home folder.
    - **S:** (`\\DC01\Departments`) shows only the Sales folder (access-based enumeration).
17. **(production)** Enroll MFA (Authenticator app plus a backup method). Sign in to Outlook and Teams.
    Problems: [KB0003](../knowledge-base/KB0003-mfa-reregistration-new-phone.md),
    [KB0014](../knowledge-base/KB0014-outlook-m365-sync-profile.md).
18. Add the department printer and print a test page. If the job gets stuck, use
    [KB0012](../knowledge-base/KB0012-print-queue-stuck.md).
19. Mobile:
    - corporate phone: MDM enrollment
    - BYOD: app protection only

    See [KB0017](../knowledge-base/KB0017-mobile-enrollment-email-lost-device.md).
20. Give a five-minute security briefing:
    - what the logon banner means
    - the 15-minute screen lock
    - never share passwords
    - how to report phishing
    - how to reach the Service Desk

    Finance hires: removable storage is blocked by `CON-U-Finance-USB-Deny`.
21. The new hire and the technician sign the Day 1 checklist below.

### E. Close (Identity & Access)

22. Add the work note in the format *Issue → Steps taken → Result → Next action*
    ([template](../itil/templates/ticket-work-note-template.md)). Attach the evidence listed in §6 and
    close the RITM.

**Day 1 checklist**

| # | Item | Done |
|---|---|---|
| 1 | Identity verified in person; sealed temporary password handed over | ☐ |
| 2 | Password changed at first sign-in | ☐ |
| 3 | H: and S: visible; only own department folder listed | ☐ |
| 4 | MFA enrolled (production) | ☐ |
| 5 | Outlook and Teams signed in (production) | ☐ |
| 6 | Printer test page printed | ☐ |
| 7 | Mobile enrolled or app protection applied | ☐ |
| 8 | Security briefing delivered | ☐ |

## 6. Controls & evidence

| Control | How this SOP meets it | Evidence attached to the RITM |
|---|---|---|
| BC-01 Least privilege | Only department defaults plus approved extra groups; technicians use their own accounts | Approvals, `Get-ADPrincipalGroupMembership` output |
| BC-04 Password standards | `PSO-Standard-Users` applies through `GG-AllStaff`; password change forced at first sign-in | `Get-ADUserResultantPasswordPolicy` output |
| BC-03 / BC-09 Encryption & baseline | Device passes `Test-EndpointCompliance.ps1` before handover | Compliance report, health report |
| BC-11 CMDB accuracy | CI assigned to the new hire with status *Installed* | CI link, inventory sync output |
| Secret handling | Temporary password never stored in any system | Work note: "temp password delivered in person" |

## 7. SLA / OLA

| Step | Target |
|---|---|
| HR submits the request | ≥ 5 business days before the start date |
| Account created and verified (Identity & Access OLA) | ≤ 2 business days after approval |
| Device provisioned, compliant and assigned in the CMDB (Desktop Support OLA) | ≥ 1 business day before the start date |
| Day 1 session | Within the first 2 working hours of the start date |
| RITM closed with evidence | ≤ 1 business day after Day 1 |

## 8. Exceptions

| Situation | Handling |
|---|---|
| Late request (< 5 business days) | Proceed only with hiring manager and IT Manager approval recorded in the RITM. Day 1 may start on a loaner laptop. |
| Name collision | The Identity & Access lead picks a unique `sAMAccountName` (e.g. `ava.turner2`), creates the account by hand to the same OU and group standards, and records why |
| Rehire (old account in `OU=Disabled`) | Never re-enable automatically. The Identity & Access lead decides whether to re-enable with a fresh access approval or create a new account. |
| Remote hire | Ship the laptop with tracking. Verify identity on a video call against photo ID. Deliver the temporary password by phone to the verified number. |
| Device fails compliance | Do not hand it over. Issue a compliant loaner and fix the device under SOP-003. |

## 9. Related documents

- [SOP-002 Employee offboarding](SOP-002-employee-offboarding.md) · [SOP-003 Laptop provisioning, refresh & retirement](SOP-003-laptop-provisioning-refresh.md)
- [KB0002 Password reset & identity verification](../knowledge-base/KB0002-password-reset-identity-verification.md) ·
  [KB0007 Mapped drive missing / access denied](../knowledge-base/KB0007-mapped-drive-access-denied.md)
- [docs/01-lab-design.md](../docs/01-lab-design.md) (§4 AD design, §6 file services, §10 controls) ·
  [docs/05-endpoint-management.md](../docs/05-endpoint-management.md)
- Scripts: [`New-Employee.ps1`](../scripts/powershell/helpdesk/New-Employee.ps1),
  [`Get-EndpointInventory.ps1`](../scripts/powershell/endpoint/Get-EndpointInventory.ps1),
  [`Sync-InventoryToCmdb.ps1`](../scripts/powershell/integration/Sync-InventoryToCmdb.ps1),
  [`Test-EndpointCompliance.ps1`](../scripts/powershell/endpoint/Test-EndpointCompliance.ps1)

## 10. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.9 | 2026-11-03 | Contoso Identity & Access | Draft for review |
| 1.0 | 2026-11-10 | Contoso Identity & Access | Approved by IT Manager; Day 1 checklist added |
