# KB0003 · MFA re-registration for a new or lost phone

| Field | Value |
|---|---|
| KB ID | KB0003 |
| Applies to | Work accounts protected by multi-factor authentication with an authenticator app (push approval / one-time codes, e.g. Microsoft Authenticator); iOS and Android phones |
| Category | Account & Access › MFA |
| Audience | Tier 1 (Contoso Service Desk) |
| Owner | Contoso Identity & Access |
| Last reviewed | 2026-11 |
| Typical priority | P3 (cannot sign in) · P2 for a VIP · lost/stolen phone: also follow [SOP-006](../sops/SOP-006-lost-stolen-device.md) |
| Related | [KB0002](KB0002-password-reset-identity-verification.md) (identity verification), [KB0017](KB0017-mobile-enrollment-email-lost-device.md) (mobile enrollment) |
| Lab note | The core lab has no cloud identity tenant; this article describes the standard process. The optional cloud extension in [docs/05-endpoint-management.md](../docs/05-endpoint-management.md) lets you practise it end to end. |

## Symptoms

- New phone: the authenticator app on the new phone has no work account, and sign-in asks for approval on the old phone.
- Lost, stolen, broken or factory-reset phone: the user cannot approve sign-ins at all.
- Approval requests never arrive, or one-time codes are rejected.
- The user receives approval requests they did **not** start (possible compromise — see Escalation).

## Likely causes

- Phone replaced or app reinstalled without moving the work account.
- Device lost or stolen.
- Phone clock set manually and drifting — one-time codes are time-based and fail when the clock is wrong.
- Notifications for the authenticator app disabled, battery optimisation, or no mobile data / Wi-Fi.

## Quick checks

1. **New phone or lost/stolen?** Lost or stolen → this article **and** [SOP-006](../sops/SOP-006-lost-stolen-device.md)
   (session revocation, device wipe, security notification).
2. Is the **old phone still available and working**? → self-service path A, no admin action needed.
3. Codes rejected? Check the phone's date & time is set to **automatic**.
4. Prompts not arriving? Notifications allowed for the app, battery saver off, phone online.

## Identity verification (mandatory)

An MFA reset hands over control of the account, so verification must be **stronger** than for a password reset:
in person with a photo badge, or a video call with badge **plus** a manager callback on the directory number. Never
call the number on record if that number belongs to the lost phone. Privileged accounts (`adm.*`, `hd.*`) are reset
only by Contoso Identity & Access. Attackers routinely call help desks to register their own phone — urgency and
seniority are not reasons to skip steps.

## Resolution (Tier 1)

### A — Old phone still works (self-service)

1. On a computer, the user opens the **security info** page of the identity provider (Microsoft example:
   `https://mysignins.microsoft.com/security-info`) and signs in, approving with the **old** phone.
2. **Add sign-in method › Authenticator app**, then scan the QR code with the authenticator app on the **new** phone.
3. Approve the test notification, set the new phone as the **default** method, then **delete** the old phone entry.

### B — Old phone not available (help desk reset)

1. In the identity admin portal (requires an authentication-administrator role), open the user's
   **authentication methods** and:
   - delete the old phone's app registration and phone number,
   - require the user to **re-register** MFA,
   - if supported, issue a **temporary access code** — short lifetime (for example one hour), single use
     (in Microsoft Entra ID this is a *Temporary Access Pass*).
2. Read the code to the user over the **verified** channel only.
3. The user signs in with the code, opens the security info page and registers the authenticator app on the new
   phone; then completes a test sign-in.
4. **Lost or stolen phone:** also revoke the user's active sessions ("sign out everywhere") and continue with
   [SOP-006](../sops/SOP-006-lost-stolen-device.md).

Tell every user: approval requests use **number matching** — type the number shown on the sign-in screen into the
app. **Never approve a request you did not start**; report it instead.

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| You do not hold the authentication-administrator role, or the account is privileged | Contoso Identity & Access | Same as ticket |
| User reports approval requests they did not start, or sign-in activity from unknown locations | Contoso Identity & Access + **Security › suspicious sign-in** incident | P2 — reset password, revoke sessions |
| Lost/stolen phone holding corporate email or data | Contoso Desktop Support (device wipe) per [SOP-006](../sops/SOP-006-lost-stolen-device.md) | P2 |
| Hardware security keys (FIDO2) or certificate-based sign-in | Contoso Identity & Access | Same as ticket |

Attach: the verification method, which methods were removed, when the phone was lost (if applicable) and the device
CI (for example `MB-IOS-001`).

## Verification

- The user completes a fresh sign-in (private browser window) and approves with the new phone.
- The old device no longer appears in the user's authentication methods.
- Any temporary access code has been used or deleted.
- Replaced device recorded in the CMDB by Contoso Desktop Support.

## Prevention

- Register at least two methods (authenticator app plus a second factor allowed by policy).
- Move the work account **before** trading in or resetting a phone — add this to new-phone guidance.
- Restoring an authenticator backup on a new phone usually still requires re-verification for work accounts.

## Ticket note example

```text
INC0010017 | MFA re-registration | olivia.bennett (Finance Manager, VIP) | P2
Issue: Olivia replaced her iPhone (MB-IOS-001) and traded in the old one; cannot approve sign-ins.
Steps taken:
  1. Identity verified in person at the IT desk with photo badge; request confirmed by manager callback (directory number).
  2. Old phone no longer available -> path B. Removed old authenticator registration; required MFA re-registration;
     issued a 1-hour single-use temporary access code, read to the user in person.
  3. User registered the authenticator app on the new phone via the security info page; test sign-in approved
     with number matching.
Result: User signed in to Outlook and Teams; old device no longer listed; temporary code consumed.
Next action: Resolve. Assigned task to Contoso Desktop Support to update CI MB-IOS-001 and re-enroll the new phone (KB0017).
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
