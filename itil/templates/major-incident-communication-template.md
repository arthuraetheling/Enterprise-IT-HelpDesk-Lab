# Major Incident Communication Template (P1)

> Procedure: [SOP-005 Major incident communications](../../sops/SOP-005-major-incident-communications.md) ·
> Rules: [incident management §10](../incident-management.md#10-major-incidents) ·
> Filled example: [INC0010007 PIR](../examples/INC0010007-dhcp-scope-outage-pir.md)

## 1. Bridge roles

| Role | Default in the lab | Responsibilities |
|---|---|---|
| **Major Incident Manager (MIM)** | Service Desk lead (weekly rotation; backup Lucas Moreno) | Runs the bridge, owns decisions and the timeline, sets update times, declares resolution |
| **Technical lead** | On-call lead of the owning group (e.g. Contoso Network Operations) | Coordinates diagnosis and the fix; one voice for the technical plan |
| **Communications lead** | Contoso Service Desk analyst | Drafts and sends every notice; updates the Service Desk phone greeting and the Teams *IT Status* channel |
| **Scribe** | Any analyst not fixing | Timestamps decisions, actions and findings in the incident work notes |
| **Resolver SMEs** | Identity & Access / Infrastructure Ops / Desktop Support as needed | Execute fixes; report back to the technical lead |
| **Business liaison** | Affected department manager (e.g. Olivia Bennett for Finance) | Confirms business impact, priorities and restoration |
| **Executive** | Lucas Moreno, IT Manager | Informed at declaration; approves emergency changes (ECAB) |

**Bridge rules:** one conversation at a time, and the MIM decides. Every action has an owner and a time. Fixes
that change configuration need an emergency CHG (ECAB can approve verbally). Do not speculate on cause in
user-facing notices.

## 2. Cadence

| When | Send |
|---|---|
| Within **15 minutes** of declaring | Initial notice |
| Every **30 minutes** (P1), or sooner on major news | Update |
| When service is restored and verified | Resolution notice |
| Within 3 business days | PIR summary to stakeholders |

All times in ET. Use the same subject prefix and INC number in every message so people can follow the thread.

## 3. Initial notice

**Subject:** `[P1][INVESTIGATING] <Service> – <user-visible symptom> – INC00#####`

> **What's happening:** Since about **[time] ET**, some users **[symptom in plain words]**.
> **Who is affected:** [departments / locations / "devices connecting to the office network"].
> **What you should do:** [workaround, or what NOT to do, e.g. "If your laptop is working, don't restart or undock it"].
> **What we're doing:** IT is investigating with priority. [One line, no speculation.]
> **Next update:** by **[time] ET**, or sooner if it changes.
> **Need help?** Call the Service Desk at x1234 and mention INC00#####.

## 4. Update

**Subject:** `[P1][UPDATE #n] <Service> – <symptom> – INC00#####`

> **Current status:** [identified / fix in progress / monitoring].
> **What changed since the last update:** [progress in one or two lines].
> **Impact now:** [same / reduced / who is still affected].
> **What you should do:** [unchanged / new instruction].
> **Next update:** by **[time] ET**.

*Give an ETA only if the technical lead commits to it. "We expect…" beats a missed promise.*

## 5. Resolution notice

**Subject:** `[P1][RESOLVED] <Service> – <symptom> – INC00#####`

> **Resolved:** Service was restored at **[time] ET** and confirmed at **[time] ET**.
> **What happened:** [one non-technical sentence, no blame, e.g. "A network setting that hands out addresses to
> laptops was turned off during maintenance and has been turned back on"].
> **What you should do:** [e.g. "If your laptop still shows 'No Internet', unplug and reconnect it or restart it"].
> **Still having problems?** Call x1234 and mention INC00##### so we can link your ticket.
> **Next steps:** We'll complete a review and share what we're changing to prevent a repeat.

## 6. Service Desk phone greeting (during the incident)

> "Thank you for calling the Contoso Service Desk. We are aware that **[symptom]** and are working on it. If
> you are calling about this issue, there is no need to stay on the line. Updates are posted in the Teams
> *IT Status* channel. For anything else, please hold."

## 7. Executive summary (optional, to Lucas Moreno)

| Item | Value |
|---|---|
| Incident | INC00##### · P1 · declared [time] |
| Business impact | [users, departments, blocked activities] |
| Current status | [investigating / restoring / restored] |
| Cause (if known) | [one line] |
| Decisions needed | [e.g. approve emergency change CHG00#####] |
| Next update | [time] |

## 8. Checklist for the communications lead

- [ ] Notice sent within 15 minutes of declaration
- [ ] Phone greeting and Teams *IT Status* updated
- [ ] Every notice logged in the incident (*Additional comments* or work notes with the text)
- [ ] Update times kept (set reminders)
- [ ] Greeting removed and resolution notice sent after the MIM declares resolution
