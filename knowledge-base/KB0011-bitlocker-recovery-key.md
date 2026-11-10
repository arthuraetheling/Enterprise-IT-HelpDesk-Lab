# KB0011 · BitLocker recovery screen — verify, retrieve the key, rotate it

| Field | Value |
|---|---|
| KB ID | KB0011 |
| Applies to | Windows 11 laptops encrypted with BitLocker (XTS-AES 256), recovery passwords escrowed to AD DS by `CON-C-Workstation-BitLocker` |
| Category | Hardware › BitLocker |
| Audience | Tier 1 (intake and identity verification) → Tier 2 (key retrieval) |
| Owner | Contoso Desktop Support |
| Last reviewed | 2026-11 |
| Typical priority | P3 (user cannot start the laptop) · P2 for a VIP |
| Related scripts | [`Get-BitLockerRecoveryKey.ps1`](../scripts/powershell/helpdesk/Get-BitLockerRecoveryKey.ps1), [`Test-EndpointCompliance.ps1`](../scripts/powershell/endpoint/Test-EndpointCompliance.ps1) |
| Related scenario | `BitLockerRecovery` — on LT-WIN-001: `.\Invoke-LabFault.ps1 -Scenario BitLockerRecovery`, then restart ([lab scenarios](../docs/06-lab-scenarios.md)) |
| Related controls | BC-03 data-at-rest encryption |

## Symptoms

- Before Windows starts: **"BitLocker recovery — Enter the recovery key for this drive"**, with a **Recovery key ID**.
- Usually right after a firmware/BIOS update, a hardware repair, a TPM or Secure Boot change, booting from USB, or
  starting the laptop on a new dock.

## Likely causes

- Firmware/UEFI update installed without suspending BitLocker.
- TPM cleared or reset; Secure Boot or boot-order changes; boot from USB or network.
- Hardware replacement (e.g. system board); disk moved to another device.
- Some docks or USB-C devices attached at start-up.
- Deliberately triggered (`manage-bde -forcerecovery C:` — the lab scenario).

## Quick checks (Tier 1)

1. **Verify identity — strongly** (in person with badge, or manager callback on the directory number,
   [KB0002](KB0002-password-reset-identity-verification.md)). The recovery key unlocks **all** data on the device.
2. **Confirm ownership:** computer name from the asset label, then the CMDB — `LT-WIN-001` is assigned to
   `emma.carter`. Caller and assignee must match.
3. **Check the device is not reported lost or stolen** (CMDB status, open [SOP-006](../sops/SOP-006-lost-stolen-device.md)
   ticket). If it is — **do not release the key**; escalate as a security incident.
4. Record the **Recovery key ID** shown on screen (at least the first 8 characters, e.g. `1A2B3C4D`).
5. Ask what happened just before: update, new dock, BIOS message, repair.

## Resolution

**Tier 1:** Tier 1 cannot read recovery keys. Escalate to **Contoso Desktop Support** with the verification method,
computer name, key ID and the ownership check.

**Tier 2 — 1. Retrieve the key** (run on DC01 or an RSAT workstation):

```powershell
.\Get-BitLockerRecoveryKey.ps1 -ComputerName LT-WIN-001 -KeyId 1A2B3C4D
```

Native equivalent — the recovery object's name contains the date and the key ID in braces:

```powershell
$computer = Get-ADComputer LT-WIN-001
Get-ADObject -SearchBase $computer.DistinguishedName -Filter 'objectClass -eq "msFVE-RecoveryInformation"' -Properties 'msFVE-RecoveryPassword' |
  Where-Object Name -like '*{1A2B3C4D*' |
  Select-Object Name, 'msFVE-RecoveryPassword'
```

**2. Read the 48-digit key** (eight groups of six digits) to the user over the verified call or in person. On the
recovery screen the number keys or **F1–F10** work (F10 = 0). Never send it by email, chat or SMS, and never paste it
into the ticket.

**3. Rotate the disclosed key** once Windows has started (elevated, on the laptop):

```powershell
manage-bde -status C:
manage-bde -protectors -get C:                        # note the ID of the existing "Numerical Password"
manage-bde -protectors -add C: -RecoveryPassword      # creates a new recovery password - note its ID
manage-bde -protectors -adbackup C: -id "{NEW-ID}"    # escrow the new one to AD DS
manage-bde -protectors -delete C: -id "{OLD-ID}"      # remove the disclosed one
```

**4. Protection off or suspended?** Turn it back on: `Resume-BitLocker -MountPoint C:`.

**5. Remove the trigger** — for example, if a firmware update is still pending, suspend BitLocker for one restart
before installing it: `Suspend-BitLocker -MountPoint C: -RebootCount 1`.

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| No matching key in AD | Desktop Support lead + Contoso Infrastructure Ops (escrow check). Data may be unrecoverable — inform the user's manager before any reimage ([SOP-003](../sops/SOP-003-laptop-provisioning-refresh.md)) | P2 |
| Recovery screen at every start-up | Contoso Desktop Support — TPM/firmware diagnosis, hardware vendor | P3 |
| Device reported lost/stolen, or the caller cannot be verified | Security incident — do not release the key ([SOP-006](../sops/SOP-006-lost-stolen-device.md)) | P2 |

Attach: verification method, computer name, key ID, CMDB ownership check, what triggered recovery. **Never** the key.

## Verification

- Windows starts; `manage-bde -status C:` shows **Protection On**.
- `.\Get-BitLockerRecoveryKey.ps1 -ComputerName LT-WIN-001` lists the **new** key ID (older entries stay in AD as history).
- `.\Test-EndpointCompliance.ps1` passes the BitLocker check.

## Prevention

- Suspend BitLocker for one restart before firmware/BIOS updates (`Suspend-BitLocker -MountPoint C: -RebootCount 1`).
- TPM and Secure Boot settings are changed only by Tier 2.
- Undock before start-up if a dock triggers recovery, and keep dock firmware current.
- Several devices of the same model entering recovery after one update → raise a problem record
  ([problem management](../itil/problem-management.md)).

## Ticket note example

```text
INC0010044 | BitLocker recovery screen | LT-WIN-001 (emma.carter) | P3
Issue: After last night's firmware update, LT-WIN-001 shows the BitLocker recovery screen. Key ID starts 1A2B3C4D.
Steps taken:
  1. Identity verified by manager callback - Olivia Bennett, directory number. CMDB: LT-WIN-001 assigned to emma.carter,
     status In use (not lost/stolen).
  2. Escalated to Contoso Desktop Support. Tier 2 ran Get-BitLockerRecoveryKey.ps1 -ComputerName LT-WIN-001 -KeyId 1A2B3C4D;
     key read to the user by phone; laptop booted.
  3. Rotated the disclosed recovery password (manage-bde add / adbackup / delete); new key present in AD.
  4. manage-bde -status C: Protection On.
Result: User working; Test-EndpointCompliance.ps1 BitLocker check passes.
Next action: Resolve. Recommended suspending BitLocker in the firmware-update procedure (sent to Desktop Support lead). KB0011 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
