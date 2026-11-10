# KB####: <Symptom in the user's words, e.g. "Locked out again after changing my password">

> **How to use:** copy to `knowledge-base/KB####-<slug>.md`. Keep one problem per article, and test every step
> in the lab before publishing. Quality checklist and lifecycle: [knowledge management](../knowledge-management.md).
> Delete the *italic guidance* when done.

| Field | Value |
|---|---|
| KB ID | KB#### |
| Applies to | *e.g. Windows 11 Enterprise (domain-joined) · macOS 14+ · iOS 17+/Android 13+* |
| Category | *Account & Access · Hardware · Software · Network · Email & Collaboration · Mobile Device · Printing · Security* |
| Audience | *Tier 1 · Tier 2 · End user (self-service)* |
| Owner | *Assignment group, e.g. Contoso Service Desk* |
| Last reviewed | *YYYY-MM-DD (next review in 180 days)* |
| Related scripts / scenarios | *e.g. `Get-AccountLockoutInfo.ps1` · scenario `AccountLockout` · KB0002* |
| Status · version | *Draft · Review · Published · Retired* · *1.0* |

## Symptoms

*What the user sees or says, including exact error text in quotes. Several phrasings help search.*

-

## Likely causes

*Most common first. Mark the known error if a problem record exists (e.g. "Known error: PRB0040001").*

1.

## Quick checks (≤ 2 minutes)

*Read-only checks that confirm the scope and direction before any change.*

- [ ] Just this user/device, or several? (Several within 30 minutes → tell the Service Desk lead.)
- [ ]

```powershell
# read-only diagnostic command(s)
```

## Resolution (Tier 1)

*Numbered, tested, copy-pasteable. Say what result to expect after each important step.*

1.
2.

## Escalation

| Escalate when | To (assignment group) | Include in the ticket |
|---|---|---|
| *e.g. needs elevated rights / physical access / infrastructure change, or 20 minutes without progress* | *Contoso Desktop Support* | *Script output, error text, steps already tried, user availability* |

## Verification

*How to prove it's fixed: what the user should be able to do, and what the command output should show.*

-

## Prevention

*What stops it happening again: user guidance, linked problem or change, monitoring.*

-

## Ticket note example

```
Issue: <symptom, scope, since when>
Steps taken: 1) ... 2) ... (KB#### used)
Result: <current state, verified how>
Next action: <none / follow-up owner + time>
```
