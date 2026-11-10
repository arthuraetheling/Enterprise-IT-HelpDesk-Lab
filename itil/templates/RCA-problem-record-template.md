# PRB00#####: <Problem title: symptom + scope, e.g. "Recurring account lockouts – Finance">

> **How to use:** copy to `itil/examples/PRB00#####-<slug>.md` or mirror the sections in the ServiceNow problem
> record. Write blamelessly: describe conditions and decisions, not people's faults.
> Rules: [problem management](../problem-management.md).

## 1. Record

| Field | Value |
|---|---|
| Problem number | PRB00##### |
| State | New / Assess / Root Cause Analysis / Fix in Progress / Resolved / Closed |
| Priority | High / Moderate / Low *(linked incident impact × frequency)* |
| Problem manager | |
| Problem owner (assignment group) | |
| Opened / trigger | *YYYY-MM-DD · ≥ 3 same symptom/CI in 7 days · P1 · trend report · monitoring* |
| Affected CIs | |
| Linked incidents | |
| Known error | Yes / No · workaround in KB#### |
| Related changes | CHG00##### |

## 2. Problem statement

*One paragraph: what fails, for whom, since when, how often. No causes yet.*

| | IS | IS NOT |
|---|---|---|
| What | | |
| Where | | |
| When | | |
| Extent | | |

## 3. Impact

| Measure | Value |
|---|---|
| Linked incidents (count, priorities) | |
| Users / departments affected | |
| Productive time lost (estimate) | |
| SLA breaches | |
| Business effect | |

## 4. Timeline

| Date / time (ET) | Event | Source (log, ticket, command) |
|---|---|---|
| | | |

## 5. Evidence

| Evidence | Command / source | Finding |
|---|---|---|
| | *e.g. `Get-AccountLockoutInfo.ps1 -SamAccountName <user>`* | |

## 6. Analysis

### 5 Whys

| # | Why? | Because… |
|---|---|---|
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |

### Fishbone (fill only what applies)

| Category | Contributing factors |
|---|---|
| People | |
| Process | |
| Technology | |
| Environment | |
| Suppliers | |
| Monitoring | |

## 7. Root cause statement

*1–2 sentences: the condition + the mechanism + why it was not prevented or detected.*

**Contributing factors:**
-

## 8. Workaround (known error)

- **Steps:**
- **Published in:** KB#### (version, date)
- **Communicated to linked incidents on:**

## 9. Corrective and preventive actions

| # | Action | Type (prevent / detect / respond) | Owner (group) | Due | Tracking (CHG / KB / SOP) | Status |
|---|---|---|---|---|---|---|
| 1 | | | | | | |

## 10. Verification and closure criteria

- **Verification window:** *14 days default (30 for monthly-cycle issues)*
- **Measure:** *e.g. zero lockout incidents for affected users; `ticket_metrics.py` recurring-issues count*
- **Closure check:** actions done · KB updated · lessons captured

## 11. Lessons learned

- **What helped:**
- **What made it harder:**

## 12. Sign-off

| Role | Name | Date |
|---|---|---|
| Problem owner | | |
| Problem manager | | |
