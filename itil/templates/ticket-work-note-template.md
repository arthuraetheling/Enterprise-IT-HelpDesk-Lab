# Ticket Work Note Templates

> Rules: [incident management §11](../incident-management.md#11-documentation-standard). A good note lets the
> next analyst continue **without calling the user again**. It also lets an auditor see who did what, when,
> under which ticket, and with what approval.

## Work notes vs. additional comments

| | Work notes (internal) | Additional comments (customer-visible) |
|---|---|---|
| Reader | IT staff, problem manager, auditors | The caller (emailed to them) |
| Content | Technical detail: commands, output, hypotheses, evidence | What we found, what we did, what happens next, when they'll hear from us |
| Style | Precise, terse, timestamps | Plain language, no jargon, no blame |
| Never | Passwords, LAPS passwords, BitLocker recovery passwords, MFA codes | Internal hostnames/IPs unless needed, other users' details |

## Standard work note

```
Issue:        <symptom in the user's words + scope (just me / team / everyone) + since when>
Steps taken:  1) <check or action> → <result>
              2) <script with parameters> → <key output>
              KB used: KB#### (step n)   |   KB searched: "<terms>" – no match (gap flagged)
Result:       <current state and how it was verified>
Next action:  <who> will <do what> by <time>   |   none – resolved
```

### Good example

```
Issue: Emma Carter (Finance) locked out at 08:47, third time since 2026-10-27. Can't sign in to LT-WIN-001.
Steps taken:
 1) Identity verified per KB0002 (manager callback, Olivia Bennett, 08:52).
 2) .\Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter → locked on DC01, BadLogonCount 5,
    source LT-WIN-001 (event 4740, 08:47).
 3) Source is her own laptop → stale credential suspected (KB0001 "Repeat lockouts").
    Unlocked with -Unlock; user signed in at 08:58 and accepted a remote-assistance session.
 4) In her session: cmdkey /list showed a saved domain credential for dc01.corp.contoso.internal;
    net use showed a manual Z: mapping. Removed both (S: from GPO is unaffected).
 5) Re-checked at 09:15: BadLogonCount 0, not locked; no new 4740 events.
KB used: KB0001 (repeat-lockout section).
Result: Resolved. Root-cause pattern matches PRB0040001 – incident linked.
Next action: none. Resolve with "Workaround provided".
```

### Bad example (and why)

```
User locked out. Unlocked. Closed.
```

There is no identity verification, no source, no evidence and no KB. The lockout will recur, and nobody can
tell whether the unlock was authorized.

## Escalation note

```
Escalating to: <assignment group>
Reason:        <criterion met: 20 min without progress / needs physical access / elevated rights / infra change>
Priority/SLA:  P# – resolution due <date time>; <x>% elapsed
Evidence:      <script output summary, error text, screenshots attached>
Already tried: <steps + results, so they are not repeated>
User:          <availability, contact method, best time>, VIP: yes/no
```

Example: *Escalating to Contoso Network Operations. Reason: APIPA 169.254.x.x persists after KB0005 steps 1–4,
cable/dock verified, and a second user on the same subnet has reported the same symptom (possible DHCP
server-side issue). P3, resolution due 2026-11-06 09:10 ET, 1% elapsed. Evidence: `Invoke-NetworkTriage.ps1` output attached
(adapter Up, IPv4 169.254.31.7, no gateway, DHCP enabled). User at desk until 17:00, x2231.*

## Resolution note

```
Cause:        <what was actually wrong>
Fix:          <what changed>  (CHG00##### if configuration changed)
Verification: <how we proved it – user test + command output>
KB:           KB#### used / updated / draft created
Prevention:   <linked PRB, user advice, or none>
```

## Customer-visible comments: examples

**Acknowledgement:**
> Hi Emma, thanks for calling. I've unlocked your account and found an old saved password on your laptop
> that was locking it again. I've removed it, so this shouldn't happen again. If you're locked out again
> today, reply to this message and I'll look at it straight away.

**Escalation:**
> Hi Marcus, your laptop isn't getting a network address from our system, and our network team is now
> looking at it. You don't need to do anything else for now. We'll update you by 10:30 ET.

**On hold (awaiting caller):**
> Hi Priya, we tried to reach you today at 10:05 and 14:30 to finish setting up your Mac. Please reply with a
> time that works. We'll try again tomorrow. If we can't reach you by Friday, we'll resolve this ticket. You
> can reopen it any time by replying.

## Sensitive actions: what to record

| Action | Record | Never record |
|---|---|---|
| Password reset (`Reset-UserPassword.ps1`) | Verification method, ticket number, "temp password given verbally" | The temporary password |
| BitLocker recovery (`Get-BitLockerRecoveryKey.ps1`) | Computer name, 8-character key ID, verification method | The 48-digit recovery password |
| LAPS (`Get-LapsADPassword`) | Computer name, reason, time retrieved (the password rotates after use) | The local admin password |
| MFA reset | Verification method, method re-registered | Codes, QR images |
