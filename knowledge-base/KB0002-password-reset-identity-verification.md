# KB0002 · Password reset with identity verification

| Field | Value |
|---|---|
| KB ID | KB0002 |
| Applies to | Standard user accounts in `OU=Users,OU=Contoso` (`corp.contoso.internal`); Windows 11, macOS and mobile sign-ins that use the AD password |
| Category | Account & Access › password reset |
| Audience | Tier 1 (Contoso Service Desk) |
| Owner | Contoso Identity & Access |
| Last reviewed | 2026-11 |
| Typical priority | P3 (cannot work) · P4 (password expiring, user can still work) · P2 for a VIP |
| Related scripts | [`Reset-UserPassword.ps1`](../scripts/powershell/helpdesk/Reset-UserPassword.ps1), [`Get-AccountLockoutInfo.ps1`](../scripts/powershell/helpdesk/Get-AccountLockoutInfo.ps1) |
| Related controls | BC-01 least privilege, BC-04 password standards ([lab design §10](../docs/01-lab-design.md#10-business-controls-matrix)) |

## Symptoms

- "The user name or password is incorrect" and the user is sure they have forgotten it.
- "Your password has expired and must be changed."
- VPN or remote sign-in fails because the password expired while the user was travelling.

## Likely causes

- Forgotten password (common after leave or a recent forced change).
- Expired password — `PSO-Standard-Users` maximum age is **90 days** (privileged accounts: 60 days).
- The account is actually **locked**, not forgotten → [KB0001](KB0001-account-lockout.md).
- The account is **disabled** → not a password problem (offboarding, HR hold or an access-review action).

## Quick checks

Run on DC01 or an RSAT workstation:

```powershell
Get-ADUser emma.carter -Properties Enabled, LockedOut, PasswordExpired, PasswordLastSet, Department, Title, Manager, telephoneNumber |
  Select-Object Name, Enabled, LockedOut, PasswordExpired, PasswordLastSet, Department, Title, Manager, telephoneNumber
```

- `Enabled = False` → **stop**. Never re-enable an account from a phone call; escalate.
- The account lives in `OU=Admins` (`adm.*`, `hd.*`) → Tier 1 has no rights there; escalate.
- Note the **manager** and **directory phone number** — you need them for verification.

## Identity verification (mandatory, before any reset)

Use one method, strongest first, and record **which** method was used — never the answers given:

| Method | How |
|---|---|
| In person | Walk-up with a company photo badge that matches the account |
| Manager callback | Call the user's manager on the number **in the directory**; the manager confirms the request |
| Directory callback | Hang up and call the user back on the number **in the directory / HR record** |

Never accept: a callback number offered by the caller, facts anyone could find (employee ID, birthday, job title),
requests by email or chat, or pressure ("I'm presenting to the board in five minutes"). **VIPs get faster service,
not weaker verification** — executives and Finance staff are the most targeted by social engineering. If
verification fails, do not reset: log the attempt and raise a **Security › suspicious sign-in** incident.

## Resolution (Tier 1)

**1. Reset** from DC01 or an RSAT workstation (`scripts\powershell\helpdesk`). The tool sets a temporary password,
unlocks the account, forces a change at next sign-in and writes an audit line.

```powershell
.\Reset-UserPassword.ps1 -SamAccountName emma.carter -TicketNumber INC0010014 -VerificationMethod "Manager callback"
```

Native equivalent (same result, no audit line):

```powershell
Set-ADAccountPassword -Identity emma.carter -Reset -NewPassword (Read-Host -AsSecureString 'Temporary password')
Set-ADUser -Identity emma.carter -ChangePasswordAtLogon $true
Unlock-ADAccount -Identity emma.carter
```

**2. Deliver the temporary password verbally** over the verified call or in person — never by email, chat, SMS or a
sticky note, and never type it into the ticket.

**3. Stay on the line** while the user signs in and sets a new password: at least 12 characters, complexity
required, and none of the last 24 passwords.

**4. Off-network users.** The laptop can only accept the new password once it can reach a domain controller.
- *Forgotten password, user remote:* use the VPN's pre-sign-in option if the laptop has one, or have the user connect
  on-site or wired. If neither is possible, escalate to Contoso Desktop Support.
- *Expired password, user still knows it:* sign in with the cached password, connect the VPN, press
  **Ctrl + Alt + Del › Change a password**, then lock (**Windows + L**) and unlock with the new password so the cached
  credential updates.

**5.** Remind the user to update the password on their phone and other devices ([KB0001](KB0001-account-lockout.md)).

## Escalation

| Condition | Escalate to |
|---|---|
| Account is disabled | Contoso Identity & Access — re-enabling needs an approved request (RITM) |
| Privileged account (`adm.*`, `hd.*`) | Contoso Identity & Access |
| Identity cannot be verified, or the caller is suspicious | Contoso Identity & Access + **Security › suspicious sign-in** incident |
| Remote user cannot reach a domain controller to use the new password | Contoso Desktop Support |

Attach: the verification method used, the account-state output above and the time of the reset (never the password).

## Verification

```powershell
Get-ADUser emma.carter -Properties PasswordLastSet, LockedOut, PasswordExpired |
  Select-Object Name, PasswordLastSet, LockedOut, PasswordExpired
```

- `PasswordLastSet` shows the user's own change (after your reset), `LockedOut` and `PasswordExpired` are `False`.
- The user can open Outlook, Teams and the S: drive.

## Prevention

- Windows warns users 5 days before expiry — encourage changing the password at the first reminder, while on-site.
- Encourage long passphrases (four random words) instead of complex short passwords.
- Repeated resets for the same person may indicate a usability or training issue — mention it to the team lead.

## Ticket note example

```text
INC0010014 | Password reset | emma.carter (Finance) | P3
Issue: Emma forgot her password after two weeks of leave; cannot sign in to LT-WIN-001.
Steps taken:
  1. Account check: Enabled = True, LockedOut = True (5 attempts this morning), PasswordExpired = False.
  2. Identity verified by manager callback - Olivia Bennett (Finance Manager), directory number.
  3. Reset-UserPassword.ps1 -TicketNumber INC0010014 -VerificationMethod "Manager callback":
     temporary password set, account unlocked, change required at next sign-in.
  4. Temporary password given verbally on the verified call; stayed on the line during sign-in.
Result: User set a new password and signed in; PasswordLastSet updated 09:41; Outlook and S: working.
Next action: Resolve. Reminded user to update the password on her phone. KB0002 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
