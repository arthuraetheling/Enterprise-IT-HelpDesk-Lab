# KB0017 · Mobile devices: enrollment, work email setup and lost/stolen devices

| Field | Value |
|---|---|
| KB ID | KB0017 |
| Applies to | Company-owned and personal (BYOD) iPhones, iPads and Android phones that use work email and apps; MDM / app protection (e.g. Intune Company Portal) |
| Category | Mobile Device › enrollment · email on device · lost/stolen |
| Audience | Tier 1 (Contoso Service Desk) → Tier 2 for MDM console actions |
| Owner | Contoso Desktop Support |
| Last reviewed | 2026-11 |
| Typical priority | P3 (no work email on the phone) · **P2** for a lost/stolen device with corporate data, or a VIP |
| Related | [KB0003](KB0003-mfa-reregistration-new-phone.md) (MFA on a new phone), [SOP-006](../sops/SOP-006-lost-stolen-device.md) (lost/stolen device) |
| Lab note | Mobile management is an optional extension ([docs/05-endpoint-management.md](../docs/05-endpoint-management.md)); CMDB CIs `MB-IOS-001` (olivia.bennett) and `MB-AND-001` (daniel.kim) are used in examples. |

## Key concepts

| Concept | What it means | Typical use |
|---|---|---|
| **MDM** (device management) | The whole device is enrolled; IT enforces passcode/encryption, pushes Wi-Fi and apps, and can wipe the device | Company-owned phones |
| **MAM** (app protection) | Only work apps (e.g. Outlook) are managed; IT protects data inside them and can **selectively wipe** that data | Personal phones without enrollment |
| **Android work profile** | A separate, encrypted work space on a personal Android phone; work apps carry a briefcase badge | BYOD Android |
| **Automated Device Enrollment** (iOS) | Company iPhones enroll automatically during setup and are supervised | Company-owned iOS |

## Symptoms

- Enrollment fails (*couldn't enroll*, *device limit reached*, profile installation failed).
- Outlook mobile will not add the account, demands an app PIN, or says the device must be compliant; mail stops syncing.
- The authenticator app is not set up on a new phone → [KB0003](KB0003-mfa-reregistration-new-phone.md).
- The phone is lost or stolen.

## Likely causes

- OS below the minimum supported version, or no passcode → device non-compliant → work access blocked.
- Per-user device limit reached (old phones still registered).
- Wrong enrollment path (company-owned vs personal).
- Wrong date/time, or a network that blocks the management service.
- App protection policy changed → Outlook asks the user to sign in again or set an app PIN.
- iOS *Background App Refresh* off / Low Power Mode, or Android battery optimisation restricting Outlook → delayed mail.

## Quick checks

1. **Company-owned or personal?** Check the CMDB (e.g. `MB-IOS-001` → olivia.bennett).
2. **OS version** — iOS: *Settings › General › About*; Android: *Settings › About phone*.
3. **Passcode** set?
4. **Management present?** iOS: *Settings › General › VPN & Device Management*. Android: a *Work* tab in the app
   drawer or a work profile under accounts in Settings (labels vary by manufacturer).
5. **Company Portal** (or the company's MDM app): device status *compliant / not compliant* and the reason.

## Resolution (Tier 1)

### A — Enroll or re-enroll

- **Company iPhone (Automated Device Enrollment):** during setup, accept the *Remote Management* screen. If setup was
  completed without it, the phone must be erased and set up again — Tier 2.
- **Personal iPhone or Android:** install the company portal app from the App Store / Google Play, sign in with the
  work account and follow the steps. On iOS, approve the downloaded management profile in *Settings › Profile
  Downloaded › Install*; on Android a work profile is created.
- **Device limit reached** → Tier 2 removes stale device records.

### B — Work email (Outlook mobile) and Authenticator

1. Install **Microsoft Outlook** and **Microsoft Authenticator** (on Android with a work profile, from the work Play Store).
2. Outlook › *Add account* → work email address → sign in → approve MFA → set the app PIN if asked.
3. Not syncing → open the company portal app, fix the compliance reason (update the OS, set a passcode), then use its
   *check compliance/status* option. iOS: allow *Background App Refresh* for Outlook and turn off Low Power Mode;
   Android: set Outlook's battery usage to unrestricted.
4. Last step: remove and re-add the account in Outlook.

### C — Lost or stolen device — act within minutes

1. Record the device CI, when and where it was lost, whether it had a passcode, what corporate data it holds, and the
   phone number.
2. Log the incident as **Mobile Device › lost/stolen** — P2 when corporate data is on the device — and follow
   [SOP-006](../sops/SOP-006-lost-stolen-device.md).
3. Personal device: the user can try their own *Find My* (Apple) or *Find My Device* (Google) service — IT does not
   track personal devices.
4. Tier 2 in the MDM console: **lock** / lost mode (company iOS), **retire / selective wipe** (personal device — work
   data only) or **full wipe** (company device, per the SOP-006 decision).
5. Contoso Identity & Access: revoke sessions, remove the phone's MFA methods ([KB0003](KB0003-mfa-reregistration-new-phone.md)),
   reset the password if credentials may be exposed.
6. The user contacts the mobile carrier to suspend the SIM and files a police report if stolen.
7. Update the CI status in the CMDB (Lost/Stolen).

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| MDM console actions: wipe, retire, device limit, re-enrolling a company device | Contoso Desktop Support | P3; P2 for lost/stolen |
| Session revocation, MFA method removal, access blocked by policy | Contoso Identity & Access | P2 for lost/stolen |
| Lost/stolen device holding Finance or HR data | Follow the security notification steps in [SOP-006](../sops/SOP-006-lost-stolen-device.md) | P2 |

Attach: device CI, platform and OS version, company-owned or personal, the compliance message (screenshot), and for
lost devices the time and place of loss.

## Verification

- Enrollment: the company portal shows the device as compliant; Outlook syncs; a test email arrives.
- Lost device: the MDM shows the wipe/retire command as completed (or pending until the device comes online);
  sessions revoked; CMDB status updated.

## Prevention

- Keep the phone's OS updated and a passcode set; register two MFA methods.
- Move the authenticator to the new phone **before** trading in the old one.
- Report a lost device immediately — minutes matter for corporate data.

## Ticket note example

```text
INC0010064 | Lost company phone | daniel.kim (Operations Manager) | P2
Issue: Daniel left his company Android phone (MB-AND-001) in a taxi at 18:40; it holds work email and Teams.
Steps taken:
  1. Identity verified in person at the IT desk with photo badge. Phone had a passcode; device is company-owned (CMDB).
  2. Logged as Mobile Device > lost/stolen, P2; followed SOP-006.
  3. Contoso Identity & Access revoked sessions and removed the phone's MFA methods at 19:05.
  4. Contoso Desktop Support locked the device via MDM at 19:08; after the taxi company could not find it,
     issued a full wipe at 21:00 per SOP-006. Wipe pending until the device comes online.
  5. Daniel contacted the carrier to suspend the SIM. CMDB status of MB-AND-001 set to Lost/Stolen.
Result: No access possible from the lost device; replacement phone requested.
Next action: Keep open until the wipe is confirmed or 7 days pass; then re-register MFA on the replacement (KB0003). KB0017 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
