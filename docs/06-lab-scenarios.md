# 06 · Break/Fix Scenarios (answer key)

Eleven realistic incidents, injected with `scripts/powershell/lab-faults/Invoke-LabFault.ps1`. The script
prints only the *user's complaint* - work the ticket first, then compare with this page.

**How to practise each scenario**

1. Take a VMware snapshot (cheap backout).
2. Inject the fault. Start a timer.
3. Open an incident in ServiceNow: caller, CI, category, **impact × urgency → priority**, short description.
4. Troubleshoot with the KB and tools - **no peeking** at the root cause below.
5. Write work notes in *Issue → Steps → Result → Next action* form
   ([template](../itil/templates/ticket-work-note-template.md)); link the KB; resolve with the caller's confirmation.
6. Record time to diagnose and time to restore. Ask: should this become a **problem**, a **change** or a
   **KB update**?
7. `-Revert` (or fix it the real way) and confirm the endpoint is compliant again.

| # | Scenario | Inject on | Priority (typical) | KB | ITIL follow-up |
|---|---|---|---|---|---|
| 1 | `AccountLockout` | LT-WIN-001 | P3 | [KB0001](../knowledge-base/KB0001-account-lockout.md) | Problem if repeated ([PRB0040001](../itil/examples/PRB0040001-recurring-account-lockouts.md)) |
| 2 | `DnsMisconfig` | LT-WIN-001 | P4 | [KB0004](../knowledge-base/KB0004-dns-resolution-failure.md) | KB update |
| 3 | `DhcpScopeDown` | DC01 | **P1/P2** (many users) | [KB0005](../knowledge-base/KB0005-no-network-apipa-dhcp.md) | Major incident, emergency change, PIR |
| 4 | `DhcpServiceDown` | DC01 | P2 (auto-created) | [KB0005](../knowledge-base/KB0005-no-network-apipa-dhcp.md) | SOP-007, MTTA/MTTR |
| 5 | `ShareAccessRemoved` | DC01 | P4 | [KB0007](../knowledge-base/KB0007-mapped-drive-access-denied.md) | Access request (RITM) |
| 6 | `WrongOU` | DC01 | P3 (compliance) | [KB0008](../knowledge-base/KB0008-group-policy-not-applying.md) | Standard change, control gap |
| 7 | `BrokenTrust` | DC01 | P3 | [KB0009](../knowledge-base/KB0009-trust-relationship-failed.md) | KB update |
| 8 | `ClockSkew` | LT-WIN-001 | P3 | [KB0010](../knowledge-base/KB0010-kerberos-clock-skew.md) | Problem if fleet-wide |
| 9 | `SpoolerStuck` | LT-WIN-001 | P4 | [KB0012](../knowledge-base/KB0012-print-queue-stuck.md) | Change: DHCP reservation for printers |
| 10 | `DiskFull` | LT-WIN-001 | P3 (auto-created) | [KB0013](../knowledge-base/KB0013-low-disk-space-slow-performance.md) | KB + user education |
| 11 | `BitLockerRecovery` | LT-WIN-001 | P3 | [KB0011](../knowledge-base/KB0011-bitlocker-recovery-key.md) | Rotate recovery key |

Run scripts from `C:\Lab\Enterprise-IT-HelpDesk-Lab\scripts\powershell` in an elevated session. Fault scripts
refuse to run outside `corp.contoso.internal`.

---

## 1 · AccountLockout

**Inject (LT-WIN-001):** `.\lab-faults\Invoke-LabFault.ps1 -Scenario AccountLockout -UserName emma.carter`

**Triage:** verify identity (callback to the number on file) → on DC01 as `hd.tier1`:
`.\helpdesk\Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter` → *LockedOut = True*, bad-password count
at the threshold (5, from PSO-Standard-Users), event **4740** caller computer **LT-WIN-001**.

**Root cause:** repeated authentication with a wrong password from LT-WIN-001 (stands in for a stale saved
credential, a mapped drive or a phone mail app still using the old password).

**Fix:** on the source device check `cmdkey /list`, `net use`, Credential Manager, scheduled tasks; remove
the stale credential → `Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter -Unlock -TicketNumber INC00xxxxx`.

**Verify:** Emma signs in; no new 4740 within 15 minutes. **Follow-up:** a second lockout within 7 days links
to the problem record (SOP-004 repeat-lockout rule).

## 2 · DnsMisconfig

**Inject (LT-WIN-001):** `-Scenario DnsMisconfig` → the adapter now uses 1.1.1.1 / 8.8.8.8.

**Symptoms:** web browsing works; S:, intranet names and `gpupdate` fail.

**Triage:** `.\endpoint\Invoke-NetworkTriage.ps1` → verdict *"Internal names fail while internet names
resolve - DNS misconfiguration"*, DNS servers flagged *[public resolver]*; `Get-DnsClientServerAddress`;
`Resolve-DnsName dc01.corp.contoso.internal` fails.

**Fix:** `Set-DnsClientServerAddress -InterfaceAlias <adapter> -ResetServerAddresses` (back to DHCP option
006) → `.\endpoint\Invoke-EndpointRemediation.ps1 -Action FlushDns`. **Prevent:** find out *who/what* changed
it (user with local admin? VPN client?) - another reason for CMP-09 (no standard users in local Administrators).

## 3 · DhcpScopeDown - potential major incident

**Inject (DC01):** `-Scenario DhcpScopeDown`; on LT-WIN-001 run `ipconfig /release` then `ipconfig /renew`.

**Symptoms:** 169.254.x.x address, "No Internet". Several users calling within 30 minutes = **3-in-30 rule**
→ parent incident + Major Incident Manager ([SOP-005](../sops/SOP-005-major-incident-communications.md)).

**Triage:** `Invoke-NetworkTriage.ps1` → *DHCP failure*. On DC01: `Get-Service DHCPServer` (running!) →
`Get-DhcpServerv4Scope` → **State = InActive**. Zabbix `dhcp.scope.state` trigger is firing.

**Fix:** emergency change: `Set-DhcpServerv4Scope -ScopeId 10.10.10.0 -State Active` → clients
`ipconfig /renew` (or `-Action RenewDhcp`). **Review:** write the PIR - model answer
[INC0010007](../itil/examples/INC0010007-dhcp-scope-outage-pir.md) (root cause: unrecorded maintenance;
corrective actions: scope-state monitoring, change control).

## 4 · DhcpServiceDown - monitoring-detected

**Inject (DC01):** `-Scenario DhcpServiceDown` - no user calls yet.

**Detection:** Zabbix *High* "DHCP Server service is not running on DC01" → ServiceNow **P2** created
automatically for Contoso Infrastructure Ops ([04](04-monitoring-alerting.md)).

**Response ([SOP-007](../sops/SOP-007-monitoring-alert-response.md)):** acknowledge within 30 minutes →
validate (`Get-Service DHCPServer`, System log event 7036 for the stop time) → `Start-Service DHCPServer` →
`Get-DhcpServerv4ScopeStatistics` → the Zabbix recovery updates/resolves the incident. Report detection
time, acknowledge time and restore time.

## 5 · ShareAccessRemoved

**Inject (DC01):** `-Scenario ShareAccessRemoved -UserName emma.carter`; Emma signs out and in.

**Symptoms:** the *Finance* folder vanished from S: (access-based enumeration hides what you cannot open) or
"Access is denied" from a shortcut.

**Triage:** on the laptop `whoami /groups` (no `GG-Finance`); on DC01
`Get-ADPrincipalGroupMembership emma.carter`; `icacls C:\Shares\Departments\Finance` shows
`DL-FS-Finance-RW` → AGDLP chain broken at the global group.

**Fix:** access is a **request**, not a fix: confirm approval from the manager (Olivia Bennett) on a RITM →
`Add-ADGroupMember GG-Finance emma.carter` → user signs out/in or runs `klist purge` (group SIDs live in the
Kerberos ticket). Note who removed her (security event 4729 on DC01) - was it an approved change?

## 6 · WrongOU

**Inject (DC01):** `-Scenario WrongOU -ComputerName LT-WIN-001`; on the laptop `gpupdate /force`.

**Symptoms:** no logon banner or screen-lock policy; `Test-EndpointCompliance.ps1` fails CMP-08, CMP-11,
CMP-12; LAPS stops rotating.

**Triage:** `gpresult /r /scope computer` → none of the `CON-C-*` GPOs, OU shows `Staging`;
`Get-ADComputer LT-WIN-001` on DC01; `Get-GPInheritance -Target 'OU=Staging,OU=Computers,OU=Contoso,DC=corp,DC=contoso,DC=internal'`.

**Fix:** move it back to OU=Workstations (standard change), `gpupdate /force`, re-run the compliance check.
**Control improvement:** weekly report of computer objects outside OU=Workstations/Servers.

## 7 · BrokenTrust

**Inject (DC01):** `-Scenario BrokenTrust -ComputerName LT-WIN-001`; restart the laptop and sign in as Emma.

**Symptoms:** *"The trust relationship between this workstation and the primary domain failed."*

**Triage:** Tier 2 retrieves the LAPS password (`Get-LapsADPassword -Identity LT-WIN-001 -AsPlainText` as
`hd.tier2`) → signs in as `.\Administrator` → `Test-ComputerSecureChannel -Verbose` returns False;
`nltest /sc_verify:corp.contoso.internal`.

**Fix:** `Test-ComputerSecureChannel -Repair -Credential CONTOSO\adm.tech` (or
`Invoke-EndpointRemediation.ps1 -Action RepairSecureChannel`) → Emma signs in. The LAPS password rotates
automatically after use. **Real-world causes:** restoring an old image or VM snapshot, a device offline for
months, duplicate computer names. Avoid unjoin/rejoin - it creates a new SID and breaks group-based access.

## 8 · ClockSkew

**Inject (LT-WIN-001):** `-Scenario ClockSkew` (time service disabled, clock +10 minutes, tickets purged).

**Symptoms:** shares and intranet fail with authentication errors; DC01 logs **4771** with failure code
**0x25** (KRB_AP_ERR_SKEW).

**Triage:** `w32tm /query /status`, `w32tm /stripchart /computer:dc01.corp.contoso.internal /samples:3 /dataonly`
(offset ≈ +600 s), `Get-Service w32time` (stopped/disabled). Kerberos tolerates **5 minutes**.

**Fix:** `Invoke-EndpointRemediation.ps1 -Action SyncTime` → `klist purge` → retry. If several devices drift,
check the PDC emulator's external time source (02-Configure-DnsDhcp.ps1 sets it).

## 9 · SpoolerStuck

**Inject (LT-WIN-001):** `-Scenario SpoolerStuck` (printer FIN-PRN-01 on a dead IP, three jobs queued).

**Triage:** `Get-Printer FIN-PRN-01 | Format-List Name, PrinterStatus, PortName`,
`Get-PrintJob -PrinterName FIN-PRN-01`, `Test-NetConnection 10.10.10.250 -Port 9100` (fails = device
offline / wrong IP, not a Windows problem).

**Fix:** `Invoke-EndpointRemediation.ps1 -Action RestartSpooler` (clears the stuck jobs), then correct the
port or escalate the printer to Desktop Support. **Problem/change:** printers whose IP changed need a DHCP
reservation - a standard change.

## 10 · DiskFull

**Inject (LT-WIN-001):** `-Scenario DiskFull` (a large file in `C:\Users\Public\Downloads`).

**Detection:** `Get-EndpointHealth.ps1` → *Disk C: Critical*; `Invoke-HealthCheckAndAlert.ps1` opens a
**P3** with `correlation_id = LT-WIN-001-Disk-C`; Zabbix raises its own disk problem.

**Triage/fix:** `Invoke-EndpointRemediation.ps1 -Action DiskCleanup -WhatIf` lists
`Q3-Finance-Archive.zip` among the largest files. **Ask the user** before deleting anything that could be
business data (move it to S:\Finance instead). Clear temp, re-run the health check - with `-AutoResolve` the
incident resolves itself when the check is OK.

## 11 · BitLockerRecovery

**Prerequisite:** BitLocker on and the key visible in AD (`Get-BitLockerRecoveryKey.ps1`). Snapshot first.

**Inject (LT-WIN-001):** `-Scenario BitLockerRecovery` → restart.

**Fix:** verify identity → Tier 2 runs `Get-BitLockerRecoveryKey.ps1 -ComputerName LT-WIN-001 -KeyId <first
8 characters on screen> -TicketNumber INC00xxxxx` → read the 48-digit key in groups of six → Windows boots.
Then `-Scenario BitLockerRecovery -Revert` restores the TPM protector and **rotates the disclosed key**.
**Prevent:** suspend BitLocker before firmware updates (`Suspend-BitLocker -MountPoint C: -RebootCount 1`).

---

## Bonus exercises (process, not break/fix)

| Exercise | Steps | Evidence |
|---|---|---|
| Joiner | RITM0010001 → `New-Employee.ps1 -FirstName Ava -LastName Turner -Department Sales -Title "Account Executive" -Manager marcus.reed -TicketNumber RITM0010001` → LT-WIN-002 joined → `Sync-InventoryToCmdb.ps1` → Day-1 checklist ([SOP-001](../sops/SOP-001-new-hire-onboarding.md)) | Audit log line, CI in CMDB |
| Leaver | `Remove-Employee.ps1 -SamAccountName ava.turner -TicketNumber RITM0010002 -WhatIf`, then for real ([SOP-002](../sops/SOP-002-employee-offboarding.md)) | Evidence CSV, account in OU=Disabled |
| Access review | `Get-ADAccessReview.ps1` → should flag `legacy.contractor` (expired but enabled) and `svc-scanner` (documented PNE exception) ([SOP-008](../sops/SOP-008-quarterly-access-review.md)) | HTML report + attestation CSV |
| CMDB audit | `python scripts/python/cmdb_reconcile.py` → fix one finding of each type | Reconciliation report |
| Change | Raise CHG for a GPO tweak, pilot on LT-WIN-002, back up with `05-Configure-GroupPolicy.ps1`, implement, PIR ([CHG0030001](../itil/examples/CHG0030001-deploy-workstation-baseline-gpo.md)) | CHG record, GPO HTML reports |
