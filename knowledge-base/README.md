# Knowledge Base — Contoso Financial IT

Tier 1–ready articles for the most common end-user issues in the lab: identity, Windows endpoints, network
services, printing, Microsoft 365, macOS and mobile devices. Every article follows the structure in
[Lab design §13](../docs/01-lab-design.md#13-documentation-conventions) and references only tools that exist in
this repository.

## Index

| ID | Title | Platform | Category › subcategory | Audience | Lab scenario |
|---|---|---|---|---|---|
| [KB0001](KB0001-account-lockout.md) | Account locked out — find the lockout source and unlock | Windows / AD | Account & Access › account lockout | Tier 1 | `AccountLockout` |
| [KB0002](KB0002-password-reset-identity-verification.md) | Password reset with identity verification | AD (all devices) | Account & Access › password reset | Tier 1 | — |
| [KB0003](KB0003-mfa-reregistration-new-phone.md) | MFA re-registration for a new or lost phone | Identity / mobile | Account & Access › MFA | Tier 1 | — |
| [KB0004](KB0004-dns-resolution-failure.md) | Internal names fail but the internet works (DNS) | Windows | Network › dns | Tier 1 → Tier 2 | `DnsMisconfig` |
| [KB0005](KB0005-no-network-apipa-dhcp.md) | No network / 169.254.x.x address (DHCP) | Windows | Network › dhcp | Tier 1 → Network Ops | `DhcpScopeDown`, `DhcpServiceDown` |
| [KB0006](KB0006-vpn-connection-failure.md) | VPN will not connect | Windows / macOS | Network › vpn | Tier 1 | — |
| [KB0007](KB0007-mapped-drive-access-denied.md) | Mapped drive missing or "Access denied" on a department share | Windows / AD | Network › file share | Tier 1 | `ShareAccessRemoved` |
| [KB0008](KB0008-group-policy-not-applying.md) | Group Policy not applying | Windows / AD | Software › OS | Tier 1 → Tier 2 | `WrongOU` |
| [KB0009](KB0009-trust-relationship-failed.md) | "The trust relationship … failed" | Windows / AD | Software › OS | Tier 2 | `BrokenTrust` |
| [KB0010](KB0010-kerberos-clock-skew.md) | Kerberos / clock skew errors | Windows / AD | Software › OS | Tier 1 → Tier 2 | `ClockSkew` |
| [KB0011](KB0011-bitlocker-recovery-key.md) | BitLocker recovery screen | Windows | Hardware › BitLocker | Tier 1 → Tier 2 | `BitLockerRecovery` |
| [KB0012](KB0012-print-queue-stuck.md) | Print job stuck / printer offline | Windows | Printing › print queue | Tier 1 | `SpoolerStuck` |
| [KB0013](KB0013-low-disk-space-slow-performance.md) | Low disk space and slow laptop | Windows | Hardware › disk | Tier 1 | `DiskFull` |
| [KB0014](KB0014-outlook-m365-sync-profile.md) | Outlook / Microsoft 365 not syncing or prompting for credentials | Windows | Email & Collaboration › Outlook | Tier 1 | — |
| [KB0015](KB0015-macos-filevault-password-keychain.md) | macOS forgotten password, FileVault recovery and Keychain prompts | macOS | Account & Access › password reset | Tier 1 → Tier 2 | — (optional Mac) |
| [KB0016](KB0016-macos-mdm-enrollment-performance.md) | macOS MDM enrollment / profiles and slow-Mac triage | macOS | Software › OS | Tier 1 → Tier 2 | — (optional Mac) |
| [KB0017](KB0017-mobile-enrollment-email-lost-device.md) | Mobile enrollment, work email setup and lost/stolen devices | iOS / Android | Mobile Device | Tier 1 → Tier 2 | — (optional Intune) |

**Audience:** Tier 1 = *Contoso Service Desk* · Tier 2 = *Contoso Desktop Support*. Resolver groups
(*Contoso Identity & Access*, *Contoso Network Operations*, *Contoso Infrastructure Ops*) are named in each
article's **Escalation** section, together with the evidence to attach.

## How to use this knowledge base (KCS)

The Service Desk works in the Knowledge-Centered Service (KCS) style — knowledge is created and improved
*while* solving tickets, not afterwards:

1. **Search first.** Before troubleshooting, search the KB with the user's own words (the *Symptoms* sections are
   written that way). Link the article you used to the incident — "KB used" is how reuse is measured.
2. **Follow, then judge.** If the article solved the issue, say so in the work note. If a step was wrong, missing
   or out of date, flag the article for review instead of silently working around it.
3. **Capture what's new.** No article? Resolve the ticket, then draft one from your work notes using the templates
   in [`../itil/templates/`](../itil/templates/). A draft is reviewed by the owning group before it is published.
4. **Keep it current.** Owners review their articles at least every six months and whenever a change record
   touches the underlying system (GPO, DNS, DHCP, MDM, VPN).
5. **Spot patterns.** Several incidents solved by the same article in a short time are a signal for
   [problem management](../itil/problem-management.md), not just more ticket closures.

Knowledge KPIs reported from the ticket data: KB link rate on resolved incidents, article reuse, First Contact
Resolution, and self-service deflection.

## Article structure

Every article contains, in this order: **metadata table** → Symptoms → Likely causes → Quick checks →
Resolution (Tier 1) → Escalation → Verification → Prevention → Ticket note example. Work notes follow
*Issue → Steps taken → Result → Next action* ([template](../itil/templates/ticket-work-note-template.md)).

Rules for everyone who edits the KB:

- Commands go in fenced code blocks and must have been run in the lab before publishing.
- Never write passwords, recovery keys or personal data into an article or a ticket.
- Steps that need local administrator rights are marked; Tier 1 escalates those to Contoso Desktop Support
  (see [incident management](../itil/incident-management.md) for the escalation rules).

## Practising with the lab

Most articles map to a fault-injection scenario. Break the lab, take the "call", and resolve it using only the
article — then compare your work note with the example at the bottom of the article.

```powershell
# On the machine named in the article (elevated PowerShell, from scripts\powershell\lab-faults)
.\Invoke-LabFault.ps1 -List
.\Invoke-LabFault.ps1 -Scenario DnsMisconfig
.\Invoke-LabFault.ps1 -Scenario DnsMisconfig -Revert   # reset the lab if you need to start over
```

Full walkthroughs and expected root causes: [docs/06-lab-scenarios.md](../docs/06-lab-scenarios.md).
macOS and mobile articles cover platforms that are not virtualized in the lab; see
[docs/05-endpoint-management.md](../docs/05-endpoint-management.md) for the optional extensions.
