# KB0001 · Account locked out — find the lockout source and unlock

| Field | Value |
|---|---|
| KB ID | KB0001 |
| Applies to | Active Directory accounts in `corp.contoso.internal`; Windows 11 laptops; any device that signs in with the AD password |
| Category | Account & Access › account lockout |
| Audience | Tier 1 (Contoso Service Desk) |
| Owner | Contoso Identity & Access |
| Last reviewed | 2026-11 |
| Typical priority | P3 (single user cannot work: Impact 3 × Urgency 1) · P2 for a VIP |
| Related scripts | [`Get-AccountLockoutInfo.ps1`](../scripts/powershell/helpdesk/Get-AccountLockoutInfo.ps1), [`Reset-UserPassword.ps1`](../scripts/powershell/helpdesk/Reset-UserPassword.ps1) |
| Related scenario | `AccountLockout` — on LT-WIN-001: `.\Invoke-LabFault.ps1 -Scenario AccountLockout -UserName emma.carter` ([lab scenarios](../docs/06-lab-scenarios.md)) |

## Symptoms

- The sign-in screen shows **"The referenced account is currently locked out and may not be logged on to."**
- Outlook, Teams or mapped drives repeatedly ask for a password, then stop working.
- The user changed their password recently and the lockout "keeps coming back".
- Several users are locked out at the same time (treat as a possible security event — see Escalation).

## Likely causes

| Cause | Why it locks the account |
|---|---|
| Wrong password typed repeatedly | `PSO-Standard-Users` locks after **5** bad attempts in 15 minutes (privileged accounts: **3**) |
| Stale credentials after a password change | A phone mail app, a saved Windows credential, a mapped drive or a second laptop keeps retrying the old password |
| Scheduled task or service running as the user | Retries with the old password on every run |
| Disconnected remote session still signed in | Re-authenticates in the background with the old password |
| Password guessing / spraying | Many accounts lock from the same unfamiliar source |

The lockout clears by itself after **15 minutes** (lockout duration), but it returns if the source is not fixed.

## Quick checks (2 minutes)

1. **Verify identity** before discussing the account ([KB0002](KB0002-password-reset-identity-verification.md)).
2. Ask: *When did you last change your password? Which devices use your work account (phone, tablet, second laptop)?*
3. Run the lockout tool on DC01 or an RSAT workstation, from `scripts\powershell\helpdesk`:

```powershell
.\Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter
```

It reports the lockout state on each domain controller, the bad-password count and the **lockout source computer**
(event **4740** on the PDC emulator). Native equivalents if the script is unavailable:

```powershell
Get-ADUser emma.carter -Properties LockedOut, BadLogonCount, LastBadPasswordAttempt, PasswordLastSet |
  Select-Object Name, LockedOut, BadLogonCount, LastBadPasswordAttempt, PasswordLastSet
Get-ADUserResultantPasswordPolicy emma.carter          # which PSO (lockout threshold) applies

# Event 4740: Properties[0] = locked account, Properties[1] = caller (source) computer
$pdc = (Get-ADDomain).PDCEmulator
Get-WinEvent -ComputerName $pdc -FilterHashtable @{ LogName = 'Security'; Id = 4740 } -MaxEvents 50 |
  Where-Object { $_.Properties[0].Value -eq 'emma.carter' } |
  Select-Object TimeCreated, @{ n = 'Account'; e = { $_.Properties[0].Value } }, @{ n = 'SourceComputer'; e = { $_.Properties[1].Value } }

Search-ADAccount -LockedOut | Select-Object Name, SamAccountName   # is anyone else locked out?
```

> `BadLogonCount` and `LastBadPasswordAttempt` are kept per domain controller and are not replicated — that is why
> every DC is checked. Reading the PDC Security log needs *Event Log Readers* rights; if the lookup is denied, note it
> in the ticket and ask Contoso Identity & Access for the source.

## Resolution (Tier 1)

**1. Fix the source first** — otherwise the account re-locks within minutes.

- *Source is the user's own laptop* (for example `LT-WIN-001`): in a remote session with the user, remove saved
  credentials created before the password change and disconnect drives that reconnect with them. GUI alternative:
  *Control Panel › Credential Manager › Windows Credentials*.

```powershell
cmdkey /list                              # look for DC01 / corp.contoso.internal entries
cmdkey /delete:<target name shown by /list>
net use                                   # drives that keep reconnecting with old credentials
net use S: /delete
```

- *Source is another device the user owns:* have the user update the password in that device's mail, Wi-Fi or
  VPN settings — or power it off until they can.
- *Source is a server, or blank:* do not guess — escalate (see below).

**2. Unlock the account.**

```powershell
.\Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter -Unlock
# native: Unlock-ADAccount -Identity emma.carter
```

**3.** If the user no longer knows the password, continue with [KB0002](KB0002-password-reset-identity-verification.md).

**4.** Ask the user to sign in while you are still on the call.

## Escalation

| Condition | Escalate to | Notes |
|---|---|---|
| Account re-locks after the source was cleaned up, or the source is a server / blank | Contoso Identity & Access | Keep the original priority |
| Privileged account (`adm.*`, `hd.*`) locked out | Contoso Identity & Access | Tier 1 has no delegated rights on `OU=Admins` |
| Several accounts locked from the same or an unknown source | Contoso Identity & Access, and raise a **Security › suspicious sign-in** incident | Possible password spray — raise priority, do not bulk-unlock |

Attach to the ticket: the tool output (state per DC, source computer, lockout times), the user's device list and
the steps already taken.

## Verification

- `.\Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter` shows the account unlocked and no new lockouts.
- The user signs in and opens Outlook, Teams and the S: drive without password prompts.
- Re-check after **30 minutes** (longer than the 15-minute observation window) before resolving.

## Prevention

- After every password change, update the password on phones, tablets and second devices the same day.
- Do not save domain credentials in Credential Manager; mapped drives should use the signed-in identity.
- If the same account locks out repeatedly (for example 3+ times in a week), link the incidents and propose a
  Problem record ([problem management](../itil/problem-management.md)).

## Ticket note example

```text
INC0010011 | Account locked out | emma.carter (Finance) | P3
Issue: Emma reported "account is locked out" on LT-WIN-001 at 08:52; Outlook had prompted for a password since 08:10.
Steps taken:
  1. Verified identity by calling back the number in the directory.
  2. Get-AccountLockoutInfo.ps1: LockedOut = True on DC01; 3 lockouts since 08:10; source = LT-WIN-001 (event 4740).
  3. Remote session on LT-WIN-001: cmdkey /list showed a DC01 credential saved before the 11/07 password change - removed.
     S: was reconnecting with the saved credential - disconnected (net use S: /delete).
  4. Unlocked with -Unlock; user signed in successfully while on the call.
Result: No new 4740 events after 30 minutes; Outlook working; S: re-mapped at next sign-in.
Next action: Resolve. Advised user to update the password in her phone's mail app. KB0001 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md) · Process:
[incident management](../itil/incident-management.md)
