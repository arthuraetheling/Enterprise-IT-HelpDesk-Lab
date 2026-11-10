# 05 · Endpoint Management - Windows, macOS and Mobile

The role this lab targets supports "an even mix of Windows PCs, Macs and mobile devices". Windows is built
hands-on in the lab; macOS and mobile are covered by tooling, procedures and an optional cloud module.

| Platform | Lab implementation | Management plane | Evidence |
|---|---|---|---|
| Windows 11 | LT-WIN-001/002 (VMs) | Active Directory + Group Policy, BitLocker, Windows LAPS, Zabbix, PowerShell tooling | `gpresult`, compliance CSV, inventory JSON, CMDB CI |
| macOS | Optional physical Mac (LT-MAC-001) | MDM concepts (ADE via Apple Business Manager, FileVault escrow, profiles) | `macos_health_check.sh --json`, KB0015/KB0016 |
| iOS / Android | Optional phone | MDM / MAM (Intune trial module) | KB0017, SOP-006 |

---

## Windows

### Policy baseline

Five GPOs ([01-lab-design.md §5](01-lab-design.md#5-group-policy-design)) are created by
`05-Configure-GroupPolicy.ps1`. Verify on a laptop:

```powershell
gpupdate /force
gpresult /r /scope computer                      # applied vs filtered GPOs, last refresh time
gpresult /h $env:TEMP\rsop.html; start $env:TEMP\rsop.html
```

Processing order is **Local → Site → Domain → OU (LSDOU)**; the closest linked GPO wins, unless a link is
*Enforced* or inheritance is blocked. Computer policy applies at boot, user policy at sign-in, then every
90 minutes ± 30 (5 minutes on DCs).

### BitLocker with AD key escrow

`CON-C-Workstation-BitLocker` requires the recovery password to reach AD DS before encryption starts.
Enable it on LT-WIN-001 in an elevated session **after** `gpresult` shows the GPO applied:

```powershell
Get-Tpm | Select-Object TpmPresent, TpmReady                       # both True (add a vTPM if not)
Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector
Enable-BitLocker -MountPoint 'C:' -TpmProtector -EncryptionMethod XtsAes256 -UsedSpaceOnly -SkipHardwareTest
$rp = (Get-BitLockerVolume -MountPoint 'C:').KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword'
Backup-BitLockerKeyProtector -MountPoint 'C:' -KeyProtectorId $rp.KeyProtectorId   # explicit escrow (idempotent)
Get-BitLockerVolume -MountPoint 'C:' | Select-Object VolumeStatus, EncryptionMethod, EncryptionPercentage, ProtectionStatus
```

On DC01: `.\scripts\powershell\helpdesk\Get-BitLockerRecoveryKey.ps1 -ComputerName LT-WIN-001` must return
the key with the same Key ID shown by `manage-bde -protectors -get C:`. After any real recovery, restore the
TPM protector and rotate the disclosed password - `Invoke-LabFault.ps1 -Scenario BitLockerRecovery -Revert`
automates both - as described in [KB0011](../knowledge-base/KB0011-bitlocker-recovery-key.md).

### Windows LAPS

```powershell
Get-LocalUser | Where-Object { $_.SID -like '*-500' } | Enable-LocalUser   # the LAPS-managed account
Invoke-LapsPolicyProcessing                                                # rotate + escrow now
Get-WinEvent -LogName 'Microsoft-Windows-LAPS/Operational' -MaxEvents 5 | Format-List TimeCreated, Id, Message
```

Retrieve it only as Tier 2, only for a ticket: `Get-LapsADPassword -Identity LT-WIN-001 -AsPlainText`.
The password rotates automatically 8 hours after use (post-authentication action). Force a rotation with
`Reset-LapsPassword` on the laptop or `Set-LapsADPasswordExpirationTime` from a DC.

### Patching

Windows Update is configured by the baseline GPO (auto-install at 03:00). Evidence of patch currency comes
from `Test-EndpointCompliance.ps1` (CMP-06 build, CMP-07 last update ≤ 35 days) and the uptime / pending
reboot checks in `Get-EndpointHealth.ps1`. When updates are stuck:
`Invoke-EndpointRemediation.ps1 -Action ResetWindowsUpdate`.

### Technician workstation (RSAT)

Support staff should administer AD from their workstation, not by signing in to the DC:

```powershell
'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0', 'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0',
'Rsat.Dhcp.Tools~~~~0.0.1.0', 'Rsat.Dns.Tools~~~~0.0.1.0', 'Rsat.BitLocker.Recovery.Tools~~~~0.0.1.0' |
    ForEach-Object { Add-WindowsCapability -Online -Name $_ }
```

### Endpoint toolkit

| Task | Script | Typical ticket |
|---|---|---|
| Health snapshot (exit 0/1/2) | `endpoint/Get-EndpointHealth.ps1` | "Laptop is slow", monitoring alert |
| Network diagnosis with verdict | `endpoint/Invoke-NetworkTriage.ps1` | "No internet / can't reach S:" |
| Safe fixes with -WhatIf | `endpoint/Invoke-EndpointRemediation.ps1 -Action …` | DNS cache, DHCP renew, spooler, temp files, WU reset, secure channel, time |
| Security baseline evidence | `endpoint/Test-EndpointCompliance.ps1 -Format Csv` | Audit request, new-laptop checklist |
| CMDB inventory | `endpoint/Get-EndpointInventory.ps1` → `integration/Sync-InventoryToCmdb.ps1` | Provisioning, asset audit |

---

## macOS

**How Macs are managed in an enterprise** (and what to say in an interview):

- **Apple Business Manager + Automated Device Enrollment (ADE):** company-purchased Macs are assigned to the
  MDM server by serial number, so enrollment is automatic at Setup Assistant and cannot be removed by the user.
- **MDM** (Jamf Pro, Intune, Kandji, Mosyle…): pushes configuration profiles (Wi-Fi, VPN, certificates,
  restrictions), apps, OS update deferrals, and escrows the **FileVault personal recovery key**.
- **Identity:** Macs are rarely bound to AD today; Platform SSO / Jamf Connect sync the local account with the
  identity provider.

**Support toolkit:**

```bash
sudo ./scripts/bash/macos_health_check.sh                 # disk, memory pressure, uptime, FileVault, SIP,
                                                          # Gatekeeper, firewall, MDM enrollment, battery, network
sudo ./scripts/bash/macos_health_check.sh --json > LT-MAC-001.json   # inventory for cmdb_reconcile.py
sudo profiles status -type enrollment                     # MDM / ADE status (KB0016)
fdesetup status                                           # FileVault (KB0015)
```

If you have a Mac, run the JSON mode and add the file to `data/inventory/` - `cmdb_reconcile.py` reads it
alongside the Windows inventories.

---

## Mobile devices

| Model | What IT controls | Typical use | Wipe option |
|---|---|---|---|
| **MDM - corporate (ADE / Android Enterprise fully managed)** | Whole device | Company-owned phones (MB-IOS-001) | Full wipe |
| **MDM - BYOD (User Enrollment / Android work profile)** | Work container only | Personal phones with work apps | Retire / remove work profile |
| **MAM only (app protection policies)** | Work data inside managed apps (Outlook, Teams) | BYOD without enrollment | Selective wipe of app data |

Support flows: enrollment and email setup ([KB0017](../knowledge-base/KB0017-mobile-enrollment-email-lost-device.md)),
new phone / MFA ([KB0003](../knowledge-base/KB0003-mfa-reregistration-new-phone.md)), lost or stolen device
([SOP-006](../sops/SOP-006-lost-stolen-device.md)).

---

## Optional module - Microsoft Intune (cloud endpoint management)

If you can get a Microsoft 365 / Intune trial tenant (check the current trial terms; cancel before it bills):

1. Add the tenant domain, create a test user, assign an Intune licence.
2. Enroll **LT-WIN-002**: *Settings > Accounts > Access work or school > Connect* (or Microsoft Entra join).
3. Create a **compliance policy** (BitLocker required, minimum OS build, firewall on, Defender on) and compare
   its verdict with `Test-EndpointCompliance.ps1` on the same device.
4. Create a **configuration profile** (for example the logon banner via Settings catalog) and deploy
   **Company Portal** as an app.
5. Enroll your phone with Company Portal; apply an **app protection policy** for Outlook; test a selective wipe.

Document it the same way: a change record for each policy, screenshots of compliance status, and a KB update.
