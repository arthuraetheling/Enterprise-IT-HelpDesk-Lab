# KB0009 · "The trust relationship between this workstation and the primary domain failed"

| Field | Value |
|---|---|
| KB ID | KB0009 |
| Applies to | Domain-joined Windows 11 laptops (`LT-WIN-###`) in `corp.contoso.internal` |
| Category | Software › OS |
| Audience | Tier 2 (Contoso Desktop Support) — Tier 1 performs intake |
| Owner | Contoso Desktop Support |
| Last reviewed | 2026-11 |
| Typical priority | P3 (one user cannot sign in) · P2 for a VIP · P1/P2 if many devices fail at once |
| Related scripts | [`Invoke-EndpointRemediation.ps1`](../scripts/powershell/endpoint/Invoke-EndpointRemediation.ps1) (`-Action RepairSecureChannel`); Windows LAPS cmdlet `Get-LapsADPassword` |
| Related scenario | `BrokenTrust` — on DC01: `.\Invoke-LabFault.ps1 -Scenario BrokenTrust -ComputerName LT-WIN-001` ([lab scenarios](../docs/06-lab-scenarios.md)) |
| Related controls | BC-02 unique local admin passwords (Windows LAPS) |

## Symptoms

- At sign-in: **"The trust relationship between this workstation and the primary domain failed."**
- Every domain account fails on this laptop, while the same accounts work on other devices.
- The user could sign in while offline (cached credentials) but fails as soon as the laptop is on the network.

## Likely causes

| Cause | Notes |
|---|---|
| An old snapshot, backup or system image was restored | The machine password in AD has moved on. In the lab, reverting a VM snapshot is the #1 cause |
| Computer account reset or deleted in AD | e.g. *Reset Account* used in Active Directory Users and Computers |
| The same computer name was joined from another device or image | The second join reset the shared account |
| Machine-password change failed (rare) | — |

> Computers change their machine password automatically (every 30 days by default). A laptop that was simply
> switched off for months does **not** lose trust — it changes the password the next time it reaches a DC.

## Quick checks

**Tier 1 intake:** exact message (photo), whether other users on other devices are fine, and anything that happened
just before (repair, reimage, restore). Then check the computer object on DC01 or an RSAT workstation:

```powershell
Get-ADComputer LT-WIN-001 -Properties Enabled, PasswordLastSet, LastLogonDate |
  Select-Object Name, Enabled, PasswordLastSet, LastLogonDate, DistinguishedName
```

- Object **missing or disabled** → do not create a new one; escalate to Contoso Identity & Access.
- `PasswordLastSet` changed recently with no matching ticket → note it (someone reset the account).

Escalate to Contoso Desktop Support — the fix needs local administrator rights.

## Resolution (Tier 2)

**1. Retrieve the local administrator password** with Windows LAPS (Tier 2 only). Record the retrieval time in the
ticket — never the password.

```powershell
Get-LapsADPassword -Identity LT-WIN-001 -AsPlainText
```

**2. Sign in on the laptop** as the LAPS-managed local administrator — user name `.\Administrator` (the `.\`
means "this computer"), unless your build manages a differently named account.

**3. Repair the secure channel** in an elevated PowerShell while the laptop can reach DC01. Use an account that may
reset computer objects (in the lab: `CONTOSO\adm.tech`; in production a delegated technician account):

```powershell
Test-ComputerSecureChannel -Verbose                                       # False = broken
Test-ComputerSecureChannel -Repair -Credential CONTOSO\adm.tech
# alternatives
Reset-ComputerMachinePassword -Server DC01.corp.contoso.internal -Credential CONTOSO\adm.tech
.\Invoke-EndpointRemediation.ps1 -Action RepairSecureChannel
```

**4. Restart** and have the user sign in.

**5. Rotate the LAPS password.** It rotates automatically after the post-authentication grace period; to force it
immediately, run `Reset-LapsPassword` in an elevated PowerShell on the laptop.

**6. Last resort — rejoin**, reusing the existing computer object (same name):

```powershell
Remove-Computer -UnjoinDomainCredential CONTOSO\adm.tech -WorkgroupName WORKGROUP -Restart
# after the restart, signed in as the local administrator:
Add-Computer -DomainName corp.contoso.internal -Credential CONTOSO\adm.tech -Restart
```

> **Never delete the computer object** to "fix" trust: its BitLocker recovery passwords and LAPS password are stored
> on that object, together with its group memberships — deleting it loses them.

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| Repair fails (access denied, RPC errors, DC unreachable) | Contoso Infrastructure Ops (AD DS) | Same as ticket |
| Computer object missing or disabled | Contoso Identity & Access | Same as ticket |
| Several devices lose trust at the same time (e.g. after a DC restore) | Contoso Infrastructure Ops | P2; P1 if widespread → [SOP-005](../sops/SOP-005-major-incident-communications.md) |

Attach: photo of the message, `Get-ADComputer` output, `Test-ComputerSecureChannel -Verbose` output, what happened
before the failure, and the LAPS retrieval time (not the password).

## Verification

```powershell
Test-ComputerSecureChannel                     # True
nltest /sc_verify:corp.contoso.internal        # secure channel verified
```

- The user signs in with their domain account; `gpupdate /force` succeeds.
- `Get-ADComputer LT-WIN-001 -Properties PasswordLastSet` shows today's date.

## Prevention

- Do not revert old snapshots or images of domain-joined machines; if you must, repair the secure channel right after.
- Reimage through [SOP-003](../sops/SOP-003-laptop-provisioning-refresh.md), which reuses the computer object.
- Reset computer accounts in AD only when the device is being rebuilt, and only under a ticket.

## Ticket note example

```text
INC0010037 | Trust relationship failed | LT-WIN-001 (emma.carter) | P3
Issue: Emma and a second test account both get "trust relationship ... failed" at sign-in on LT-WIN-001.
Steps taken:
  1. Get-ADComputer: Enabled = True; PasswordLastSet = today 07:55 - no ticket explains the reset.
  2. Tier 2 retrieved the LAPS password at 09:12 (Get-LapsADPassword); signed in as .\Administrator.
  3. Test-ComputerSecureChannel -Verbose -> False; -Repair -Credential CONTOSO\adm.tech -> True.
  4. Restarted; Emma signed in; gpupdate /force completed.
  5. Ran Reset-LapsPassword to rotate the local admin password after use.
Result: Secure channel verified (nltest /sc_verify); user working; no data loss.
Next action: Resolve. Flagged the unexplained computer-account reset to Contoso Identity & Access. KB0009 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
