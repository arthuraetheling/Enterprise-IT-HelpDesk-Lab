# PRB0040001: Recurring account lockouts in Finance after password changes

> **Example record (simulated)** from the fictional Contoso environment. You can reproduce the laptop half
> with `Invoke-LabFault.ps1 -Scenario AccountLockout -UserName emma.carter` on LT-WIN-001. The mobile half is a
> tabletop exercise, because the lab has no mail platform.
> Template: [RCA / problem record](../templates/RCA-problem-record-template.md) · rules: [problem management](../problem-management.md).

## 1. Record

| Field | Value |
|---|---|
| Problem number | PRB0040001 |
| State | **Fix in Progress**: permanent fixes in place, verification window to 2026-11-18 |
| Priority | Moderate (5 incidents in 8 days, 2 users, P3 each) |
| Problem manager | Service Desk lead |
| Problem owner | Contoso Identity & Access |
| Opened / trigger | 2026-10-30 11:00 · **≥ 3 incidents, same symptom, within 7 days** |
| Affected CIs | LT-WIN-001 · MB-IOS-001 · DC01 (account lockout policy via `PSO-Standard-Users`) |
| Linked incidents | INC0010002, INC0010003, INC0010004, INC0010005, INC0010006 |
| Known error | **Yes**, since 2026-11-03 · workaround in [KB0001](../../knowledge-base/KB0001-account-lockout.md) v1.1 |
| Related changes | CHG0030003 (proposed: modern-auth mobile mail) |

## 2. Problem statement

Finance users are locked out of their AD accounts within 24 hours of changing their password, and the lockouts
repeat after every unlock. Each incident was resolved by unlocking only, so the cause stayed in place.

| | IS | IS NOT |
|---|---|---|
| What | AD lockouts (5 bad passwords in 15 minutes, `PSO-Standard-Users`) | Users mistyping the new password (they sign in fine after unlock) |
| Where | emma.carter (LT-WIN-001), olivia.bennett (MB-IOS-001) | Other departments; other Finance users who changed passwords this month |
| When | Starting hours after a password change; repeating | Before the change |
| Extent | 5 incidents in 8 days | Not spreading |

## 3. Impact

| Measure | Value |
|---|---|
| Linked incidents | 5 × P3 (Impact 3 single user × Urgency 1 cannot work) |
| Users | 2 (one VIP: Olivia Bennett, Finance Manager) |
| Productive time lost | ≈ 2.5 hours (30 minutes median per lockout) |
| SLA breaches | None |
| Business effect | Finance month-end preparation interrupted twice |

## 4. Timeline (ET)

| Date / time | Event | Source |
|---|---|---|
| 10-14 | During a walk-up visit, Z: was mapped manually to `\\dc01.corp.contoso.internal\Departments` on LT-WIN-001 with *Connect using different credentials* and *Remember my credentials*. **No ticket was logged** | Found 11-03 (`net use`, `cmdkey /list`) |
| 10-26 16:31 | Emma changes her expiring password (`PasswordLastSet`) | `Get-ADUser -Properties PasswordLastSet` |
| 10-27 09:05 | **INC0010002**: Emma locked out. Unlocked; resolved "Solution provided" | Incident |
| 10-28 14:20 | **INC0010003**: Emma locked out again. Unlocked only | Incident |
| 10-29 17:08 | Olivia changes her password after the 14-day reminder | `PasswordLastSet` |
| 10-30 08:15 | **INC0010004**: Olivia locked out (VIP). Unlocked only | Incident |
| 10-30 11:00 | Service Desk lead sees 3 lockouts in 4 days in Finance → **PRB0040001** opened | Incident list grouped by subcategory |
| 11-02 08:05 | **INC0010005**: Olivia locked out again. First use of the source check: caller is the mail access server, not a laptop → phone mail account still has the old password → updated on MB-IOS-001 | `Get-AccountLockoutInfo.ps1` |
| 11-03 08:47 | **INC0010006**: Emma locked out (third time). Source LT-WIN-001 → stale saved credential + manual Z: removed | `Get-AccountLockoutInfo.ps1`, `cmdkey`, `net use` |
| 11-03 15:00 | Root cause agreed; known error and workaround published (KB0001 v1.1) | This record |
| 11-04 – 11-06 | Permanent fixes 1–4 completed (see §9) | KB, SOP, comms |
| 11-10 | No repeat lockouts for either user since the fixes | `Get-AccountLockoutInfo.ps1`, incident list |

## 5. Evidence

| Evidence | Command / source | Finding |
|---|---|---|
| Lockout source (Emma) | `.\Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter` (reads event 4740 on DC01, the PDC emulator) | Caller computer **LT-WIN-001** for all three lockouts |
| Lockout source (Olivia) | `.\Get-AccountLockoutInfo.ps1 -SamAccountName olivia.bennett` | Caller is the **mail access server**, not a user laptop: the signature of a mail client signing in on the user's behalf |
| Saved credentials | `cmdkey /list` in Emma's session | Domain credential for `dc01.corp.contoso.internal` saved 2026-10-14 |
| Persistent mappings | `net use` in Emma's session | `Z:` → `\\dc01.corp.contoso.internal\Departments`, a duplicate of the GPO-mapped `S:` |
| Phone | Walkthrough with Olivia on MB-IOS-001 | Mail account showing "Cannot Get Mail"; still configured with the previous password |
| Policy | `Get-ADUserResultantPasswordPolicy emma.carter` | `PSO-Standard-Users` (threshold 5, window 15 min) applies as designed |

## 6. Analysis: 5 Whys

| # | Why? | Because… |
|---|---|---|
| 1 | Why are the accounts locking? | 5 bad-password attempts reach DC01 within the 15-minute observation window |
| 2 | Why bad passwords after a successful password change? | Other clients keep presenting the **old** password automatically (sources: LT-WIN-001; the phone mail client) |
| 3 | Why do those clients hold the old password? | **(a)** A manual Z: mapping on LT-WIN-001 used *saved* credentials, and Windows retries them at every reconnect. **(b)** The phone's mail account stores the password and retries it on every sync |
| 4 | Why weren't they updated? | Password-change reminders and KB0002's reset steps did not tell users to update phones or saved credentials. The Z: mapping was made during an unlogged walk-up, so nobody knew it existed |
| 5 | Why did it repeat five times before anyone found the cause? | **KB0001 covered unlock only, with no step to find the lockout source.** Incidents were closed after unlock, and the pattern was only noticed at the third incident |

**Fishbone highlights:**

- **Process:** KB0001 had no source-finding step; there was no post-password-change checklist; a walk-up was
  not logged.
- **Technology:** a client stores the password (saved credentials, legacy mail authentication).
- **Monitoring:** no repeat-lockout alert.

## 7. Root cause statement

Stale passwords cached on secondary clients (a manually mapped drive with saved Windows credentials on
LT-WIN-001, and the mail account on MB-IOS-001) kept authenticating with the pre-change password and crossed
the 5-attempt lockout threshold. The Service Desk process treated lockouts as unlock-only tasks, so the
sources were never identified.

**Contributing factors:** the workaround in an earlier unlogged visit (manual mapping with saved credentials)
created a latent defect; the password-expiry reminder has no "update your devices" checklist; repeat lockouts
had no trigger before the problem threshold.

## 8. Workaround (known error)

Published in [KB0001](../../knowledge-base/KB0001-account-lockout.md) v1.1 on 2026-11-03 and posted to all
linked incidents:

1. Verify identity ([KB0002](../../knowledge-base/KB0002-password-reset-identity-verification.md)), then run
   `.\Get-AccountLockoutInfo.ps1 -SamAccountName <user>` and note the **caller computer**.
2. If the caller is the user's laptop, unlock (`-Unlock`), then in the user's session:
   - run `cmdkey /list` and remove entries for `dc01` / `corp.contoso.internal` (or use *Credential Manager →
     Windows Credentials*);
   - run `net use` and delete manual mappings that duplicate GPO drives (`net use Z: /delete`).
3. If the caller is a server rather than a laptop (mail access, VPN, Wi-Fi), find the user's device that signs
   in through it: usually the phone. Update or re-enter the password there, or remove and re-add the account.
4. Re-check after 15 minutes: not locked, no new 4740 events.

## 9. Corrective and preventive actions

| # | Action | Type | Owner | Due | Tracking | Status |
|---|---|---|---|---|---|---|
| 1 | KB0001 v1.1: mandatory lockout-source step + credential cleanup + phone check | Respond | Contoso Service Desk | 11-04 | KB0001 | **Done** |
| 2 | KB0002: post-reset checklist (update phone mail, remove saved credentials, sign out/in) | Prevent | Contoso Service Desk | 11-04 | KB0002 | **Done** |
| 3 | SOP-004 repeat-lockout rule: 2nd lockout in 7 days → find the source before resolving; 3rd → link to a problem | Detect | Service Desk lead | 11-05 | [SOP-004](../../sops/SOP-004-incident-triage-escalation.md) | **Done** |
| 4 | Password-expiry reminders (14 / 7 / 1 days) include "update your phone and saved passwords" | Prevent | Contoso Identity & Access | 11-06 | Comms template | **Done** |
| 5 | Remove manual drive mappings that duplicate GPP `S:` on Finance laptops (check `net use` during visits) | Prevent | Contoso Desktop Support | 11-13 | Visit checklist | In progress |
| 6 | Walk-up work is logged before or right after the fix ("no ticket, no work") | Prevent | Service Desk lead | 11-06 | Team huddle | **Done** |
| 7 | Move mobile mail to a modern-authentication client that stores tokens, not passwords; block legacy mail authentication | Prevent | Contoso Identity & Access | 11-20 | CHG0030003 (proposed, out of lab scope) | Proposed |
| 8 | Weekly trend review includes lockout counts per user (`ticket_metrics.py` recurring-issues table) | Detect | Service Desk lead | ongoing | Ops review | **Done** |

## 10. Verification and closure criteria

- **Window:** 14 days after the last fix (2026-11-04 → **2026-11-18**).
- **Pass:** zero lockout incidents for emma.carter and olivia.bennett. No Finance user locked out more than
  once after a password change. Action 5 done. Action 7 either approved or risk-accepted by Lucas Moreno.
- **As of 2026-11-10:** no repeats. State stays **Fix in Progress** until the window closes.

## 11. Lessons learned

- **What helped:** the source check took under a minute once it was in the KB. The problem trigger (≥ 3 in 7
  days) caught the pattern even though each incident looked trivial.
- **What made it harder:** "unlock and close" resolved the symptom and hid the cause. One undocumented
  workaround (saved credentials) created future incidents.
