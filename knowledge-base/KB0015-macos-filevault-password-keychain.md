# KB0015 · macOS forgotten password, FileVault recovery and Keychain prompts

| Field | Value |
|---|---|
| KB ID | KB0015 |
| Applies to | Company Macs (`LT-MAC-###`) on macOS 14 or later with FileVault on, managed by MDM with the FileVault personal recovery key escrowed |
| Category | Account & Access › password reset (macOS) |
| Audience | Tier 1 (intake and verification) → Tier 2 (recovery key from the MDM console) |
| Owner | Contoso Desktop Support |
| Last reviewed | 2026-11 |
| Typical priority | P3 (user cannot sign in) · P2 for a VIP |
| Related scripts | [`macos_health_check.sh`](../scripts/bash/macos_health_check.sh) (FileVault status) |
| Lab note | Macs are not virtualized in the lab. With a physical Mac you can run the health check; MDM steps are described vendor-neutrally. |

## Symptoms

- The user has forgotten their Mac password; the FileVault login window at start-up rejects it.
- After several failed attempts the login window offers **password reset options** (for example using the recovery key).
- After a reset: repeated *login keychain* prompts, Wi-Fi and apps asking for saved passwords again, or
  *"The system was unable to unlock your login keychain."*
- The Mac password no longer matches the corporate password (on Macs that sync the local password with the
  corporate identity).

## Likely causes

- Forgotten local password — Mac accounts are local accounts unless an SSO extension or identity agent syncs them.
- The password was reset by IT or with the recovery key, but the **login keychain is still encrypted with the old password**.
- The corporate password changed and the Mac has not synced the new one yet.
- Caps Lock or the wrong keyboard layout at the login window (check the input menu at the top right).

## Quick checks (Tier 1)

1. **Verify identity** with a method from [KB0002](KB0002-password-reset-identity-verification.md); confirm in the CMDB
   that the Mac belongs to the caller (`LT-MAC-001` → `priya.shah`) and is **not** reported lost or stolen.
2. Caps Lock off? Correct keyboard layout selected at the login window?
3. Did the password change recently? Does the user mean the Mac password or the corporate password?
4. Get the **serial number** (on the underside of the Mac, the box, or the CMDB record).

If the user can still sign in (Keychain or sync issue only), collect:

```bash
fdesetup status                              # "FileVault is On."
sudo fdesetup list                           # accounts that can unlock FileVault
sudo profiles status -type bootstraptoken    # bootstrap token escrowed to MDM?
sudo ./macos_health_check.sh                 # FileVault, SIP, Gatekeeper, firewall, MDM, disk, memory, battery, updates
```

## Resolution

### A — Forgotten password at the FileVault login window (Tier 2 retrieves the key)

1. **Tier 1** escalates to Contoso Desktop Support with the verification method, serial number and computer name.
2. **Tier 2** looks up the device by serial number in the MDM console and retrieves the escrowed **FileVault personal
   recovery key** — 24 characters in six groups of four (`XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`).
3. Read the key to the user over the verified channel only. The user chooses the reset option in the login window
   (the wording varies by macOS version), enters the recovery key and sets a new password.
4. Alternative: a managed administrator account on the Mac can reset the user's password in
   *System Settings › Users & Groups* — this also leaves the old keychain locked (see B).
5. **Rotate the disclosed key** — use the MDM's FileVault key rotation if available, or on the Mac:

```bash
sudo fdesetup changerecovery -personal       # generates a new personal recovery key
```

   Confirm the new key appears as escrowed in the MDM console.

### B — Keychain prompts after a reset

- **User remembers the old password:** open *Keychain Access* (use Spotlight) › *Edit* › **Change Password for
  Keychain "login"** — enter the old password, then the new one.
- **Old password unknown:** create a new login keychain (*Create New Keychain* in the prompt, or *Keychain Access ›
  Settings › Reset Default Keychains* where available). **Warn the user first:** passwords saved in the old keychain
  (Wi-Fi, websites, apps) must be re-entered; the old keychain file is kept but cannot be opened without the old password.
- Restart and confirm the prompts have stopped.

### C — Mac password out of sync with the corporate password

Sign in with the current Mac password; when the single sign-on extension or identity agent prompts, enter the new
corporate password to sync. No prompt appears → escalate.

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| No escrowed recovery key in MDM | Desktop Support lead — data may be unrecoverable; inform the manager before any erase/restore ([SOP-003](../sops/SOP-003-laptop-provisioning-refresh.md)) | P2 |
| Secure token / bootstrap token problems (e.g. accounts that cannot unlock FileVault) | Contoso Desktop Support | P3 |
| Mac reported lost/stolen, or the caller cannot be verified | Security incident — do not release the key ([SOP-006](../sops/SOP-006-lost-stolen-device.md)) | P2 |
| Password sync with the corporate identity fails | Contoso Identity & Access | P3 |

Attach: verification method, serial number, macOS version, health-check output (if the user can sign in) and what
has been tried. Never the recovery key or any password.

## Verification

```bash
fdesetup status                              # FileVault is On.
sudo fdesetup haspersonalrecoverykey         # true
sudo fdesetup validaterecovery               # Tier 2: validate the new key (prompts for it)
```

- MDM shows a newly escrowed key; Keychain prompts are gone after a restart; Wi-Fi and apps work.

## Prevention

- The FileVault escrow profile is installed **before** FileVault is enabled; review escrow status in MDM regularly.
- Users change passwords while on the corporate network so sync tools can update the Mac.
- Recovery keys are only ever read out over a verified channel — never emailed or chatted.

## Ticket note example

```text
INC0010057 | Forgot Mac password | priya.shah (HR) | P3
Issue: After two weeks of leave Priya cannot unlock LT-MAC-001 at the FileVault login window.
Steps taken:
  1. Identity verified in person with photo badge; CMDB: LT-MAC-001 assigned to priya.shah, status In use.
  2. Escalated to Contoso Desktop Support; Tier 2 retrieved the escrowed personal recovery key by serial number.
  3. User used the login window's reset option with the key and set a new password.
  4. Keychain prompt appeared; user did not remember the old password -> created a new login keychain after she agreed
     that saved Wi-Fi and website passwords would need re-entering.
  5. Ran sudo fdesetup changerecovery -personal; new key shows as escrowed in MDM.
Result: User signed in; fdesetup status = On; no further keychain prompts after restart.
Next action: Resolve. KB0015 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
