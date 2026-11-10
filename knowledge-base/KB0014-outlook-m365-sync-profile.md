# KB0014 · Outlook / Microsoft 365 apps not syncing or prompting for credentials

| Field | Value |
|---|---|
| KB ID | KB0014 |
| Applies to | Microsoft 365 Apps on Windows 11 — **classic Outlook** (desktop app with profiles and `.ost` files) and **new Outlook for Windows**; Teams and OneDrive sign-in prompts |
| Category | Email & Collaboration › Outlook |
| Audience | Tier 1 (Contoso Service Desk) — Office repair and profile rebuild may need Tier 2 |
| Owner | Contoso Desktop Support |
| Last reviewed | 2026-11 |
| Typical priority | P3 (no email for one user) · P2 for a VIP · P1 if email is down company-wide |
| Related | [KB0001](KB0001-account-lockout.md), [KB0002](KB0002-password-reset-identity-verification.md), [KB0003](KB0003-mfa-reregistration-new-phone.md), [KB0006](KB0006-vpn-connection-failure.md) |
| Lab note | The lab has no mail tenant; this article covers the most common real-world desk tickets. |

## Symptoms

- Status bar shows **Disconnected**, **Working Offline** or **Trying to connect…**; new mail does not arrive.
- Repeated *Enter password* or Microsoft sign-in windows in Outlook, Teams or OneDrive; status *Need Password*.
- Calendar or shared mailboxes stop updating; sent mail stays in the Outbox.
- Outlook freezes at *Processing…* or crashes on start.

## Likely causes

| Cause | Clue |
|---|---|
| No network / VPN problem | Other internet services also fail |
| *Work Offline* switched on | Status bar shows *Working Offline* |
| Password changed or expired; stale sign-in tokens | Prompts started right after a password change |
| Signed out of Office, or the work account disconnected | *File › Office Account* shows no user or a different account |
| Corrupt saved credentials | Prompts continue after entering the correct password |
| Add-in causing hangs or crashes | Outlook works in safe mode |
| Corrupt `.ost` cache or profile (classic Outlook) | Folders out of date, sync errors, other fixes failed |
| Mailbox full | *Mailbox full* warnings; cannot send |
| Service-side outage | Several users affected at once |

## Quick checks

1. **Outlook on the web** in a browser: works → client-side problem; also fails → account or service problem.
2. Anyone else affected? (recent tickets, status announcements)
3. Classic Outlook status bar; *Send / Receive* tab → is **Work Offline** highlighted?
4. *File › Office Account* — signed in with the user's work account? *File › Info* — mailbox size near the limit?
5. Which Outlook? **New Outlook** has a *New Outlook* toggle on and no *File* menu; **classic Outlook** has the full ribbon
   and *File* menu.

## Resolution (Tier 1)

**1. Basics** — turn off *Work Offline*, close Outlook completely, reopen; restart the laptop if it has been up for days.

**2. Credential prompts**
- *File › Office Account › Sign out*, close all Office apps, reopen and sign in again.
- *Control Panel › Credential Manager › Windows Credentials* — remove entries whose name starts with
  `MicrosoftOffice` (e.g. `MicrosoftOffice16_Data:…`), then reopen Outlook and sign in.
- *Settings › Accounts › Access work or school* — confirm the work account is listed. **Do not click Disconnect**
  on a work account without Tier 2: on company-joined devices it can remove the device from management.
- Still prompting after a password change → check the account is not locked ([KB0001](KB0001-account-lockout.md)) and
  MFA works ([KB0003](KB0003-mfa-reregistration-new-phone.md)).

**3. Crashes or hangs** — start in safe mode (**Windows + R**):

```text
outlook.exe /safe
```

Stable in safe mode → *File › Options › Add-ins › Manage: COM Add-ins › Go*, disable add-ins one at a time.

**4. Repair Office** *(needs admin — Tier 2 if Tier 1 has no elevation)*: *Settings › Apps › Installed apps ›
Microsoft 365 › … › Modify*. Run **Quick Repair** first (offline, a few minutes); use **Online Repair** only if
Quick Repair fails (full reinstall, needs internet, takes longer).

**5. New profile (classic Outlook)** — keeps the old profile as a fallback:
*Control Panel* (view: small icons) › **Mail (Microsoft Outlook)** › *Show Profiles* › *Add* → name it (e.g.
`Outlook-2026-11`) → let the account set itself up → select **Always use this profile** → choose the new profile →
open Outlook and allow the first sync to finish. Re-attach any personal `.pst` files with
*File › Open & Export › Open Outlook Data File*.

**6. Rebuild the `.ost` cache (classic Outlook)** — close Outlook, open `%LOCALAPPDATA%\Microsoft\Outlook`, rename
`<address>.ost` to `<address>.ost.old`, reopen Outlook (it downloads a fresh copy). An `.ost` is only a cache and can
be rebuilt — a **`.pst` is not**: never delete or rename `.pst` files.

**7. New Outlook** — it does not use classic profiles or `.ost` files. Remove and re-add the account in its
*Settings › Accounts*; if the app itself misbehaves, use *Settings › Apps › Installed apps › Outlook (new) ›
Advanced options › Repair* (then *Reset*). If the user switched to new Outlook by accident, the toggle switches back
to classic where policy allows.

**8. Mailbox full** — archive or delete large items (sort by size), empty *Deleted Items*; escalate if more space is
genuinely needed.

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| Repair or profile rebuild needs admin, or Outlook still crashes | Contoso Desktop Support — attach Application log errors (source *Application Error*, faulting module) | P3 |
| Sign-in fails with an error code after password and MFA checks, licence or account issues | Contoso Identity & Access | P3 |
| Several users affected, or Outlook on the web also fails for many | Contoso Infrastructure Ops — parent incident | P2; P1 company-wide → [SOP-005](../sops/SOP-005-major-incident-communications.md) |
| Mailbox quota increase | Contoso Identity & Access (with manager approval) | P4 |

Attach: Outlook version (classic/new), exact error or screenshot, whether Outlook on the web works, steps already
tried and the time the problem started.

## Verification

- Status bar shows **Connected** (classic) and new mail arrives; send a test message to the user's own address.
- Calendar and shared mailboxes update; no credential prompt after closing and reopening Outlook.

## Prevention

- After a password change, sign out of and back into Office apps on all devices.
- Keep Microsoft 365 Apps on the supported update channel; review add-ins that cause repeated crashes.
- Encourage the online archive over local `.pst` files.

## Ticket note example

```text
INC0010054 | Outlook keeps asking for password | marcus.reed (Sales Manager) | P3
Issue: Since changing his password this morning, classic Outlook on LT-WIN-002 prompts every few minutes; status "Need Password".
Steps taken:
  1. Outlook on the web works -> client-side. Get-AccountLockoutInfo.ps1: not locked.
  2. File > Office Account showed the work account; signed out, closed Office apps.
  3. Credential Manager: removed 3 stale MicrosoftOffice16_Data entries.
  4. Reopened Outlook, signed in with the new password and approved MFA.
Result: Status "Connected"; test mail sent and received; no prompt after reopening Outlook twice.
Next action: Resolve. Advised updating the password on his phone mail app. KB0014 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
