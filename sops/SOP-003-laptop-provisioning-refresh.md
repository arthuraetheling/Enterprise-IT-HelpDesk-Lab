# SOP-003 · Laptop Provisioning, Refresh & Retirement

| Field | Value |
|---|---|
| SOP ID | SOP-003 |
| Owner | Contoso Desktop Support |
| Approver | IT Manager (Lucas Moreno) |
| Version / effective date | 1.0 · 2026-11-10 |
| Review cycle | Every 6 months (Windows feature updates raise the minimum build) |
| Related controls | BC-02, BC-03, BC-07, BC-09, BC-10, BC-11 |

## 1. Purpose

Every laptop leaves Desktop Support in the same known-good state: domain-joined, policy-managed, encrypted
with a recoverable key, protected by LAPS, monitored and recorded in the CMDB. Every laptop that comes back
is sanitized before it is reused or disposed of.

## 2. Scope

- **Devices:** Windows laptops `LT-WIN-###` (lab: Windows 11 Enterprise Evaluation VMs) and Mac laptops `LT-MAC-###`.
- **Triggers:** new hire ([SOP-001](SOP-001-new-hire-onboarding.md)), 48-month lifecycle refresh, hardware
  replacement, reimage to fix a persistent incident, device return ([SOP-002](SOP-002-employee-offboarding.md))
  or recovery ([SOP-006](SOP-006-lost-stolen-device.md)).
- **Change control:** domain joins use `adm.tech` under the pre-approved **standard change** *Workstation
  build / rebuild*. Reference the RITM or incident in the change (BC-07).

## 3. Roles (RACI)

| Activity | Desktop Support | Identity & Access | Infrastructure Ops | User | Manager |
|---|---|---|---|---|---|
| Reserve the asset and its name | R/A | – | – | – | I |
| Build, join, encrypt and verify | R/A | C | – | – | – |
| Register the device in Zabbix | R | – | A | – | – |
| Push inventory to the CMDB | R/A | – | I | – | – |
| Sign off data migration (refresh) | R | – | – | A | I |
| Sanitize and retire | R/A | I | R (removes the monitoring host) | – | I |

## 4. Prerequisites

- An asset in the CMDB with status *In stock*.
  - Physical devices: UEFI, Secure Boot and TPM 2.0 enabled.
  - Lab VM: 2 vCPU, 4 GB RAM, 64 GB thin disk, vTPM ([docs/02-build-guide.md](../docs/02-build-guide.md)).
- Windows 11 Enterprise media, and the Zabbix agent 2 MSI (7.0 LTS, same major version as the server).
- Accounts: `adm.tech` (domain join, under the standard change) and `hd.tier2` (LAPS and BitLocker checks).
- The repository's `scripts\powershell\` folder on the device (commands below run from there, elevated),
  and the ServiceNow integration credential.

## 5. Procedure

### A. Windows build (lab)

1. Pick the next free name, checking both AD and the CMDB:
   ```powershell
   Get-ADComputer -Filter "Name -like 'LT-WIN-*'" | Sort-Object Name | Select-Object -ExpandProperty Name
   ```
2. Install Windows 11 Enterprise with a temporary local account. Install all cumulative updates first:
   Windows LAPS and the OS-build compliance check both need a current build. Then rename the device:
   ```powershell
   Rename-Computer -NewName LT-WIN-003 -Restart
   ```
3. Check the network before joining. Expect a lease in 10.10.10.100–200 and DNS server 10.10.10.10:
   ```powershell
   .\endpoint\Invoke-NetworkTriage.ps1 -InternalHost dc01.corp.contoso.internal
   ```
4. Join the domain. Because of `redircmp`, the computer lands in `OU=Workstations` automatically:
   ```powershell
   Add-Computer -DomainName corp.contoso.internal -Credential CONTOSO\adm.tech -Restart
   ```
   On DC01, confirm the OU, and move the computer if it landed somewhere else:
   ```powershell
   Get-ADComputer LT-WIN-003 | Select-Object DistinguishedName
   Get-ADComputer LT-WIN-003 | Move-ADObject -TargetPath "OU=Workstations,OU=Computers,OU=Contoso,DC=corp,DC=contoso,DC=internal"
   ```
5. Apply and verify policy (elevated):
   ```powershell
   gpupdate /force
   gpresult /r /scope computer
   ```
   *Applied Group Policy Objects* must list `CON-C-Workstation-Baseline`, `CON-C-Workstation-BitLocker`
   and `CON-C-Workstation-LAPS`. If any are missing, see [KB0008](../knowledge-base/KB0008-group-policy-not-applying.md).
6. BitLocker:
   1. Confirm `Get-Tpm` shows `TpmPresent` and `TpmReady` = `True`.
   2. Enable BitLocker (TPM + recovery password, XTS-AES 256) using the command sequence in
      [docs/05-endpoint-management.md](../docs/05-endpoint-management.md). `CON-C-Workstation-BitLocker`
      blocks encryption until the recovery password is escrowed to AD DS.
   3. Verify:
      ```powershell
      Get-BitLockerVolume -MountPoint C: | Select-Object VolumeStatus, EncryptionMethod, ProtectionStatus, EncryptionPercentage
      (Get-BitLockerVolume -MountPoint C:).KeyProtector | Select-Object KeyProtectorType, KeyProtectorId
      ```
   4. As `hd.tier2`, run `.\helpdesk\Get-BitLockerRecoveryKey.ps1 -ComputerName LT-WIN-003`. The
      recovery password ID must match the `RecoveryPassword` protector. If no key is found, back it up
      from the laptop:
      ```powershell
      manage-bde -protectors -adbackup C: -id "{<KeyProtectorId>}"
      ```
7. Windows LAPS: on the laptop, run `Invoke-LapsPolicyProcessing`. Then on DC01, as `hd.tier2`:
   ```powershell
   Get-LapsADPassword -Identity LT-WIN-003     # PasswordUpdateTime is set; ExpirationTimestamp about 30 days out
   ```
   Do not reveal the password (`-AsPlainText`) unless a ticket requires it.
8. Monitoring: install Zabbix agent 2 pointing at MON01:
   ```powershell
   msiexec /i zabbix_agent2-7.0.x-windows-amd64-openssl.msi /qn SERVER=10.10.10.20 SERVERACTIVE=10.10.10.20 HOSTNAME=LT-WIN-003
   ```
   Then ask Contoso Infrastructure Ops to link the host to *Windows by Zabbix agent active*
   ([docs/04-monitoring-alerting.md](../docs/04-monitoring-alerting.md)).
9. Push the inventory to the CMDB. The CI stays *In stock* until it is assigned ([SOP-001](SOP-001-new-hire-onboarding.md) step 12).
   ```powershell
   .\endpoint\Get-EndpointInventory.ps1 -OutputPath C:\ProgramData\Contoso\Inventory
   .\integration\Sync-InventoryToCmdb.ps1 -InventoryPath C:\ProgramData\Contoso\Inventory\LT-WIN-003.json `
       -InstanceUrl https://devNNNNN.service-now.com -Credential (Get-Credential)
   ```
10. Quality gate:
    - `.\endpoint\Test-EndpointCompliance.ps1`: every check is PASS.
    - `.\endpoint\Get-EndpointHealth.ps1`: exit code `0`.
    - Lab: take a VMware snapshot named *LT-WIN-003 – provisioned* as the backout point.

**(production) Enterprise equivalents**

| Lab step | Enterprise equivalent |
|---|---|
| Manual install + `Add-Computer` | Windows Autopilot (the reseller registers the hardware hash) + Microsoft Entra join |
| GPO baseline | Intune configuration profiles / security baselines |
| BitLocker escrow to AD DS | Intune disk-encryption policy, key escrowed to Microsoft Entra ID |
| Windows LAPS → AD | Windows LAPS → Microsoft Entra ID |
| `Test-EndpointCompliance.ps1` | Intune compliance policy + Conditional Access |
| `Sync-InventoryToCmdb.ps1` | Intune ↔ ServiceNow integration (Service Graph connector) |

### B. macOS build

11. Macs are bought through Apple Business Manager and assigned to the MDM server, so **Automated Device
    Enrollment** happens during Setup Assistant. The device is supervised and the MDM profile can't be
    removed.
12. Go through Setup Assistant with the user. MDM then installs the configuration profiles and apps:
    - FileVault, with the personal recovery key escrowed to MDM
    - firewall
    - screen lock
    - Wi-Fi
    - software-update policy
13. Set the name if MDM did not:
    ```bash
    sudo scutil --set ComputerName LT-MAC-002
    sudo scutil --set LocalHostName LT-MAC-002
    sudo scutil --set HostName LT-MAC-002
    ```
14. Verify:
    ```bash
    sudo profiles status -type enrollment    # "Enrolled via DEP: Yes" and "MDM enrollment: Yes (User Approved)"
    fdesetup status                          # "FileVault is On."
    sudo ./macos_health_check.sh             # every check passes
    ```
15. Create or update the CI (`LT-MAC-###`, class `cmdb_ci_computer`). In production this comes from the
    MDM ↔ ServiceNow integration. Lab note: macOS can't be virtualized on non-Apple hardware under Apple's
    license, so run this section only if a physical Mac is available.

### C. Refresh & data migration

16. Schedule with the user at least 5 business days ahead. Confirm their business data lives on H:, S: or
    cloud storage.
17. Copy any remaining local data to the home drive and keep the log:
    ```powershell
    robocopy C:\Users\emma.carter\Desktop \\DC01\Home$\emma.carter\Migrated-Desktop /E /COPY:DAT /R:1 /W:1 /LOG:C:\Temp\migration.log
    ```
18. Provision the new device (§A or §B). The user signs in, checks files, printers and apps, and signs off
    in the ticket.
19. Keep the old device untouched for 5 business days (rollback option), then sanitize it (§D).

### D. Sanitization & retirement

20. Confirm there is no legal hold and that the user has signed off.
21. Sanitize the device (NIST SP 800-88):
    - **Windows:** reimage the BitLocker-encrypted drive, or use the drive's firmware secure-erase/sanitize
      command.
    - **Mac:** *Erase All Content and Settings*, which is a cryptographic erase on Apple silicon/T2 Macs.

    Record the method and date in the ticket. If the device is leaving the company, release it from Apple
    Business Manager or remove its Autopilot registration.
22. **Windows, being retired (not redeployed):** disable the computer object and move it to `OU=Disabled`.
    Keep it for the retention period, because the BitLocker recovery information is stored under it:
    ```powershell
    Get-ADComputer LT-WIN-003 | Disable-ADAccount
    Get-ADComputer LT-WIN-003 | Move-ADObject -TargetPath "OU=Disabled,OU=Contoso,DC=corp,DC=contoso,DC=internal"
    ```
    Redeployed devices keep their name and are rejoined after the reimage (§A).
23. Contoso Infrastructure Ops disables or deletes the Zabbix host.
24. CMDB: set *Status* to *Retired* (or *In stock* if redeployed), clear *Assigned to*, and attach the
    disposal or recycling certificate.

## 6. Controls & evidence

| Control | Evidence kept with the RITM / incident |
|---|---|
| BC-03 Data-at-rest encryption | `Get-BitLockerVolume` output + recovery key present in AD (`Get-BitLockerRecoveryKey.ps1`) |
| BC-02 Unique local admin passwords | `Get-LapsADPassword` metadata (no password shown) |
| BC-09 Endpoint baseline | `gpresult` summary + `Test-EndpointCompliance.ps1` report |
| BC-10 Monitoring | Zabbix host shows *Available* with the template linked |
| BC-11 CMDB accuracy | CI created or updated by `Sync-InventoryToCmdb.ps1`; retirement status and disposal certificate |
| BC-07 Change control | Standard change reference for the domain join or rebuild |

## 7. SLA / OLA

| Activity | Target |
|---|---|
| New-hire device ready, compliant and in the CMDB | ≥ 1 business day before the start date |
| Reimage to resolve an incident | ≤ 1 business day (loaner provided if longer) |
| Refresh scheduled after notice | ≤ 10 business days |
| Returned device sanitized | ≤ 10 business days after return |
| CMDB updated after any status change | Same business day |

## 8. Exceptions

| Situation | Handling |
|---|---|
| Device has no TPM 2.0 or Secure Boot | Do not issue it. Raise a replacement request. |
| Device fails the compliance gate | Do not issue it. Fix and run the gate again, or issue a loaner. |
| User asks for local admin rights | Not granted by default. A time-boxed exception needs IT Manager approval and goes on the exception register ([SOP-008](SOP-008-quarterly-access-review.md)). |
| Legal hold on a returned device | Do not sanitize it. Label it *Legal hold* in the CMDB and store it securely until Legal releases it. |
| Data migration needs more than the H: drive | Desktop Support copies the data to a temporary encrypted location, recorded in the ticket, and deletes it after the user signs off |

## 9. Related documents

- [SOP-001 New hire onboarding](SOP-001-new-hire-onboarding.md) · [SOP-002 Employee offboarding](SOP-002-employee-offboarding.md) ·
  [SOP-006 Lost or stolen device](SOP-006-lost-stolen-device.md)
- [KB0008 Group Policy not applying](../knowledge-base/KB0008-group-policy-not-applying.md) ·
  [KB0009 Trust relationship failed](../knowledge-base/KB0009-trust-relationship-failed.md) ·
  [KB0011 BitLocker recovery key](../knowledge-base/KB0011-bitlocker-recovery-key.md) ·
  [KB0016 macOS MDM enrollment & performance](../knowledge-base/KB0016-macos-mdm-enrollment-performance.md)
- [docs/02-build-guide.md](../docs/02-build-guide.md) · [docs/04-monitoring-alerting.md](../docs/04-monitoring-alerting.md) ·
  [docs/05-endpoint-management.md](../docs/05-endpoint-management.md)

## 10. Revision history

| Version | Date | Author | Change |
|---|---|---|---|
| 0.9 | 2026-11-03 | Contoso Desktop Support | Draft for review |
| 1.0 | 2026-11-10 | Contoso Desktop Support | Approved by IT Manager; enterprise-equivalent table added |
