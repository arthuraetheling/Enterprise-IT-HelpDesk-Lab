# SOP-006 · Lost or Stolen Device

| Field | Value |
|---|---|
| SOP ID | SOP-006 |
| Owner | Contoso Desktop Support |
| Approver | IT Manager (Lucas Moreno) |
| Version / effective date | 1.0 · 2026-11-10 |
| Review cycle | Annually, or after any device-loss case that leads to data exposure |
| Related controls | BC-02, BC-03, BC-05, BC-11 |

## 1. Purpose

Treat every lost or stolen device as a **potential security incident**. Contain the risk to company data
within the target time, revoke credentials the device could expose, keep the CMDB accurate, and get the
user productive again on a replacement device.

## 2. Scope

- Corporate Windows laptops (`LT-WIN-###`), Mac laptops (`LT-MAC-###`), corporate phones (`MB-IOS-###`,
  `MB-AND-###`), and personal (BYOD) phones that hold corporate apps under app protection (MAM).
- Out of scope: personal devices with no corporate data. Offer advice only, such as the owner's own
  Find My or Find My Device service.

## 3. Roles (RACI)

| Activity | User | Service Desk | Desktop Support | Identity & Access | Security | Manager |
|---|---|---|---|---|---|---|
| Report the loss (as soon as noticed) | R | I | – | – | – | I |
| Log, verify identity, record facts | C | R/A | I | – | I | – |
| Assess data-exposure risk | C | C | R | – | A | – |
| Remote lock / wipe; disable the computer account | – | – | R/A | C | C | – |
| Reset credentials, revoke sessions and MFA methods | – | – | – | R/A | C | – |
| Replacement device ([SOP-003](SOP-003-laptop-provisioning-refresh.md)) | C | – | R | – | – | A (approves) |
| Update the CMDB; close | – | I | R/A | – | I | I |

## 4. Prerequisites

- CMDB access to find the device and its serial number or IMEI.
- The device's latest compliance evidence: the `Test-EndpointCompliance.ps1` report (Windows), MDM
  encryption status (Mac/mobile), and `.\helpdesk\Get-BitLockerRecoveryKey.ps1` to confirm a key exists.
- **(production)** MDM console with remote lock/wipe rights. The lab equivalent is the optional Intune
  trial ([docs/05-endpoint-management.md](../docs/05-endpoint-management.md)).
- `hd.tier2` for device actions. An Identity & Access account for password resets and session revocation.

## 5. Procedure

1. **Log the incident immediately.**
   - Laptops: category **Security**. Phones: **Mobile Device → lost/stolen**.
   - Single user: at least Impact 3 × Urgency 1 = **P3**.
   - VIP (e.g. `olivia.bennett`), or a device that held regulated data: **P2**.
   - Suspected mass data exposure: Security may raise it to P1 ([SOP-005](SOP-005-major-incident-communications.md)).
   - Example: **INC0010015**, Olivia Bennett reports corporate iPhone `MB-IOS-001` stolen while travelling.
2. **Verify identity.** You can't call back on a lost phone, so use manager verification, a video call
   against photo ID, or an in-person check ([KB0002](../knowledge-base/KB0002-password-reset-identity-verification.md)).
   A fake "I lost my phone" call is a known social-engineering route to a password or MFA reset.
3. **Record the facts:**
   - lost or stolen
   - when and where last seen
   - was it locked or powered off
   - were any passwords written down with it
   - which accounts and apps were signed in

   If stolen, the user files a police report. Record the **report number** in the ticket.
4. **Identify the device in the CMDB.** Find the CIs assigned to the user and note the serial number or
   IMEI for the police report and the carrier. Add the CI to the incident.
5. **Assess exposure** from the compliance evidence:

   | Evidence | Risk | Action |
   |---|---|---|
   | BitLocker / FileVault on, device locked or off | Low: data protected at rest (BC-03) | Contain per step 6 |
   | Encryption off or unknown | High | Security leads, Legal/Compliance consulted, P2 at least |
   | Phone with passcode, managed by MDM | Low–medium | Lost Mode / wipe per step 6 |

6. **Contain** (target ≤ 1 hour for P2, ≤ 4 hours for P3):
   - **Corporate laptop:** (production) send an MDM remote lock or wipe. On-prem/lab: disable the
     computer account so the device can no longer authenticate to the domain:
     ```powershell
     Get-ADComputer LT-WIN-001 | Disable-ADAccount
     ```
   - **Corporate phone:** (production) enable MDM *Lost Mode* (supervised iOS) or a remote lock if there is
     a realistic chance of recovery. Do a **full wipe** if it was stolen, or if it is not recovered within
     24 hours.
   - **BYOD:** selective wipe / app-protection wipe of corporate data only. Never full-wipe a personal
     device unless the user consents under the BYOD policy.
7. **Revoke credentials:**
   - Identity & Access resets the password. The temporary password goes to the user through the verified
     channel:
     ```powershell
     .\helpdesk\Reset-UserPassword.ps1 -SamAccountName olivia.bennett -TicketNumber INC0010015 -VerificationMethod 'Manager callback'
     ```
   - **(production)** Revoke sign-in sessions and refresh tokens. Remove the lost phone as an MFA method
     and register a new one ([KB0003](../knowledge-base/KB0003-mfa-reregistration-new-phone.md)).
   - Ask Contoso Network Operations to revoke any device certificate used for VPN or Wi-Fi.
8. **BitLocker and LAPS:**
   - Flag the device's BitLocker recovery key in the ticket. **No one** gets that key for this device
     while the case is open. Any request for it is suspicious and goes to Security.
   - The device's local admin password is unique to that device (Windows LAPS, BC-02), so losing it
     exposes no other device and needs no fleet-wide rotation.
9. **Monitor** (production): watch sign-in logs for the user and device for 14 days. In AD, the disabled
   computer account already blocks the device's secure channel.
10. **Replace.** The manager approves, then Desktop Support provisions a device per
    [SOP-003](SOP-003-laptop-provisioning-refresh.md). The user's data comes back from H:, S: and cloud
    storage. Enroll the new phone per [KB0017](../knowledge-base/KB0017-mobile-enrollment-email-lost-device.md).
11. **CMDB.** Set the CI status to **Lost/Stolen**: CI *Status* = *Stolen*, and asset *State* = *Missing*
    with substate *Lost* or *Stolen*. Link the incident and add the police report number. **Never delete
    the CI.** Laptops: move the disabled computer object to `OU=Disabled`. Keep it, because the BitLocker
    recovery information is stored under it.
12. **Close** once containment is confirmed, credentials are rotated and the replacement is delivered.
    Security closes its assessment separately.

**If the device is found later:** treat it as untrusted. Desktop Support inspects it, then reimages it
(Windows) or erases it (Mac/mobile) before reuse, and updates the CMDB to *In stock*.

## 6. Controls & evidence

| Control | Evidence |
|---|---|
| BC-03 Data-at-rest encryption | Compliance report or MDM encryption status used in the risk decision (step 5) |
| BC-02 Unique local admin passwords | Note that LAPS limits exposure to this one device |
| BC-05 Timely revocation | Password reset and session revocation timestamps versus report time |
| BC-11 CMDB accuracy | CI status *Stolen* / asset *Missing*, police report number, linked incident |
| Containment | MDM action log or `Disable-ADAccount` output in the work notes |

## 7. SLA / OLA

| Step | Target |
|---|---|
| Incident logged after the user's report | Immediately (during the first contact) |
| Containment (lock, wipe or disable) | ≤ 1 hour (P2) · ≤ 4 hours (P3) |
| Password reset after identity verification | ≤ 30 minutes |
| Replacement device delivered | ≤ 2 business days (loaner the same day for VIPs) |
| CMDB updated | Same business day |

## 8. Exceptions

| Situation | Handling |
|---|---|
| Device under legal hold | A remote **lock** is always allowed. A full **wipe** needs Security and Legal approval, recorded in the ticket. |
| BYOD with no MDM enrollment | Selective (app-protection) wipe only, plus a credential reset |
| Suspected insider theft | Security leads. Restrict the ticket's visibility. Don't contact the suspect. |
| Lost abroad / roaming | The carrier is contacted to suspend the SIM. A replacement may need a courier, so the manager approves temporary alternatives. |
| User is also leaving the company | Run [SOP-002](SOP-002-employee-offboarding.md) in parallel; a device that isn't returned counts as lost |

## 9. Related documents

- [KB0003 MFA re-registration (new phone)](../knowledge-base/KB0003-mfa-reregistration-new-phone.md) ·
  [KB0011 BitLocker recovery key](../knowledge-base/KB0011-bitlocker-recovery-key.md) ·
  [KB0015 macOS FileVault, password & Keychain](../knowledge-base/KB0015-macos-filevault-password-keychain.md) ·
  [KB0017 Mobile enrollment, email & lost device](../knowledge-base/KB0017-mobile-enrollment-email-lost-device.md)
- [SOP-003 Laptop provisioning, refresh & retirement](SOP-003-laptop-provisioning-refresh.md) ·
  [SOP-004 Incident triage & escalation](SOP-004-incident-triage-escalation.md) ·
  [SOP-005 Major incident](SOP-005-major-incident-communications.md)
- [itil/incident-management.md](../itil/incident-management.md) · [docs/05-endpoint-management.md](../docs/05-endpoint-management.md)

## 10. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.9 | 2026-11-03 | Contoso Desktop Support | Draft for review |
| 1.0 | 2026-11-10 | Contoso Desktop Support | Approved by IT Manager; exposure-risk table added |
