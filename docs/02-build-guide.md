# 02 · Build Guide

Step-by-step build of the lab on one Windows laptop. Names, addresses and policies come from
[01-lab-design.md](01-lab-design.md). Each phase ends with a **checkpoint** (what to verify) and a
📸 **portfolio capture** (screenshot worth keeping in `docs/screenshots/`).

| Phase | What you build | Time |
|---|---|---|
| 0 | Host prep, ISOs, VMware network | 1 h |
| 1 | DC01 - AD DS, DNS, DHCP, OUs, users, GPOs, LAPS | 2-3 h |
| 2 | LT-WIN-001 - domain join, GPO, BitLocker, LAPS | 1.5 h |
| 3 | GPMC drive map + first user logon | 30 min |
| 4 | MON01 - Ubuntu, Docker, Zabbix | 1.5 h |
| 5 | ServiceNow PDI ([03](03-servicenow-itsm.md)) and monitoring integration ([04](04-monitoring-alerting.md)) | 2-3 h |
| 6 | Break/fix scenarios ([06](06-lab-scenarios.md)) and metrics ([07](07-metrics-reporting.md)) | ongoing |

---

## Phase 0 - Host preparation

**Host minimum:** 16 GB RAM, 4+ cores with virtualization enabled in firmware, **80 GB free** on a fast
drive (use a secondary drive if C: is tight - for example `D:\Labs\HelpDeskLab`).

1. Install **VMware Workstation Pro** (free for personal use; download from the Broadcom support portal).
   VirtualBox works too - see the note at the end of this phase.
2. Download evaluation media (free):
   - Windows Server 2022 or 2025 **Evaluation** ISO (Microsoft Evaluation Center) - 180 days
   - Windows 11 Enterprise **Evaluation** ISO (Microsoft Evaluation Center) - 90 days
   - Ubuntu Server 24.04 LTS ISO (ubuntu.com)
3. Configure the lab network - **Edit > Virtual Network Editor > Change Settings > VMnet8 (NAT)**:
   - Subnet IP `10.10.10.0`, subnet mask `255.255.255.0`
   - **Untick** "Use local DHCP service to distribute IP address to VMs" (DC01 will be the DHCP server)
   - **NAT Settings…** → gateway IP `10.10.10.2`
4. Clone or download this repository on the host. You will copy it into each VM as
   `C:\Lab\Enterprise-IT-HelpDesk-Lab` (drag-and-drop with VMware Tools, a shared folder, or download the
   ZIP from GitHub inside the VM).

> **VirtualBox:** create a *NAT Network* `10.10.10.0/24` with DHCP disabled; its gateway is `10.10.10.1`,
> so change `Gateway` and `Dhcp.Router` in `scripts/powershell/Lab.Config.psd1` before you run anything.

---

## Phase 1 - DC01 (domain controller)

**VM:** Windows Server 2022/2025 Standard (Desktop Experience), 2 vCPU, 3-4 GB RAM, 60 GB disk (thin),
NIC on **VMnet8**.

1. Install Windows Server, set a **complex** local Administrator password (promotion fails otherwise),
   install VMware Tools, then run **Windows Update until nothing is left** - Windows LAPS needs the
   April 2023 cumulative update or later.
2. Copy the repo to `C:\Lab\Enterprise-IT-HelpDesk-Lab`, then in an **elevated** PowerShell:

   ```powershell
   Get-ChildItem C:\Lab -Recurse | Unblock-File
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   cd C:\Lab\Enterprise-IT-HelpDesk-Lab\scripts\powershell\lab-build
   ```

3. Run the build scripts in order (each one is idempotent - safe to re-run):

   ```powershell
   .\01-Install-DomainController.ps1   # sets 10.10.10.10, renames to DC01, reboots
   .\01-Install-DomainController.ps1   # again after the reboot: installs AD DS, asks for the DSRM password, reboots
   ```

   Sign in as **CONTOSO\Administrator** (Schema Admins is needed for the LAPS schema extension), then:

   ```powershell
   .\02-Configure-DnsDhcp.ps1          # DNS forwarders, reverse zone, mon01/zabbix records, DHCP scope, NTP
   .\03-Build-ADStructure.ps1          # OUs, groups, adm.tech/hd.tier1/hd.tier2, FGPP, delegation, LAPS, shares
   .\04-Import-LabUsers.ps1            # 50 users from data\users.csv
   .\05-Configure-GroupPolicy.ps1      # 5 GPOs, backups + HTML reports in C:\GPOBackups
   ```

**Checkpoint**

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode, PDCEmulator
Get-ADOrganizationalUnit -Filter * -SearchBase 'OU=Contoso,DC=corp,DC=contoso,DC=internal' | Select-Object Name
(Get-ADUser -Filter * -SearchBase 'OU=Users,OU=Contoso,DC=corp,DC=contoso,DC=internal').Count   # 51 (50 + legacy.contractor)
Get-ADUserResultantPasswordPolicy -Identity emma.carter          # PSO-Standard-Users
Get-DhcpServerv4Scope | Select-Object ScopeId, Name, State
Get-GPO -All | Where-Object DisplayName -like 'CON-*' | Select-Object DisplayName, GpoStatus
Resolve-DnsName zabbix.corp.contoso.internal
```

📸 ADUC with the OU tree · DHCP console scope · GPMC with the five linked GPOs ·
`Get-ADFineGrainedPasswordPolicy -Filter *` output.

Take a VMware snapshot: **`01-dc01-built`**.

---

## Phase 2 - LT-WIN-001 (Windows 11 laptop)

**VM:** Windows 11 Enterprise Evaluation, 2 vCPU, 4 GB RAM, 64 GB disk, **UEFI + Secure Boot + vTPM**
(VMware: when the wizard asks, choose "Only the files needed to support a TPM are encrypted"), NIC on **VMnet8**.

1. Install Windows 11. At the account screen choose **Sign-in options > Domain join instead** to create a
   local admin account (no Microsoft account needed). Install VMware Tools and Windows Updates.
2. Confirm DC01 gave it an address:

   ```powershell
   ipconfig /all          # 10.10.10.1xx, DNS server 10.10.10.10, DNS suffix corp.contoso.internal
   Resolve-DnsName _ldap._tcp.dc._msdcs.corp.contoso.internal -Type SRV
   ```

3. Rename and join the domain (elevated PowerShell):

   ```powershell
   Rename-Computer -NewName LT-WIN-001 -Restart
   Add-Computer -DomainName corp.contoso.internal -Credential CONTOSO\adm.tech -Restart
   ```

4. On DC01, confirm the computer landed in **OU=Workstations** (thanks to `redircmp`):
   `Get-ADComputer LT-WIN-001 | Select-Object DistinguishedName`.
5. Back on LT-WIN-001 (signed in as `CONTOSO\adm.tech`), apply policy and prepare LAPS:

   ```powershell
   gpupdate /force
   gpresult /r /scope computer        # CON-C-Workstation-Baseline, -BitLocker, -LAPS applied
   Get-LocalUser | Where-Object { $_.SID -like '*-500' } | Enable-LocalUser   # LAPS-managed local admin
   Invoke-LapsPolicyProcessing
   ```

   On DC01, as a Tier 2 analyst: `runas /user:CONTOSO\hd.tier2 powershell` then
   `Get-LapsADPassword -Identity LT-WIN-001 -AsPlainText`.
6. Enable BitLocker with AD escrow - exact commands in
   [05-endpoint-management.md](05-endpoint-management.md#bitlocker-with-ad-key-escrow). Verify on DC01 with
   `.\helpdesk\Get-BitLockerRecoveryKey.ps1 -ComputerName LT-WIN-001`.
7. Copy the repo to `C:\Lab\...` on the laptop too and run the endpoint tools once:

   ```powershell
   cd C:\Lab\Enterprise-IT-HelpDesk-Lab\scripts\powershell\endpoint
   .\Get-EndpointHealth.ps1
   .\Test-EndpointCompliance.ps1        # expect all controls Pass on a correctly built laptop
   .\Get-EndpointInventory.ps1 -OutputPath C:\Lab\inventory
   ```

📸 `gpresult /r` · the logon banner · `Test-EndpointCompliance.ps1` all green ·
`Get-LapsADPassword` output (blur the password).

Snapshot: **`02-laptop-joined`**.

---

## Phase 3 - Drive map and first user logon

The S: drive uses Group Policy Preferences, which have no PowerShell cmdlets - configure it in **GPMC**
on DC01 (a skill worth knowing anyway):

1. **Group Policy Management** → edit **CON-U-Standard-User** → *User Configuration > Preferences >
   Windows Settings > Drive Maps* → **New > Mapped Drive**.
2. Action **Update**, Location `\\DC01\Departments`, Reconnect ticked, Label `Departments`, Drive letter **S:**.
3. Sign in on LT-WIN-001 as `CONTOSO\emma.carter`. Expect: logon banner, **S:** (only the *Finance*
   folder visible - access-based enumeration), **H:** home drive, screen saver lock after 15 minutes,
   USB storage blocked (Finance).

📸 File Explorer showing S: and H: for Emma, with only the Finance folder visible.

---

## Phase 4 - MON01 (Zabbix)

**VM:** Ubuntu Server 24.04 LTS, 2 vCPU, 2 GB RAM, 30 GB disk, NIC on **VMnet8**.

1. During setup, choose a **manual IPv4** configuration - or set it afterwards in `/etc/netplan/50-cloud-init.yaml`
   (check the interface name with `ip -br a`; VMware usually shows `ens33` or `ens160`):

   ```yaml
   network:
     version: 2
     ethernets:
       ens33:
         addresses: [10.10.10.20/24]
         routes:
           - to: default
             via: 10.10.10.2
         nameservers:
           addresses: [10.10.10.10]
           search: [corp.contoso.internal]
   ```

   `sudo netplan apply`, then `getent hosts dc01.corp.contoso.internal` must return 10.10.10.10.
2. Install Docker from the Ubuntu archive and start Zabbix:

   ```bash
   sudo apt update && sudo apt -y upgrade
   sudo apt -y install docker.io docker-compose-v2
   sudo usermod -aG docker "$USER" && newgrp docker
   cp -r ~/Enterprise-IT-HelpDesk-Lab/infrastructure/zabbix ~/zabbix && cd ~/zabbix
   cp .env.example .env && nano .env          # set POSTGRES_PASSWORD
   docker compose up -d && docker compose ps
   ```

3. Browse to `http://zabbix.corp.contoso.internal` from LT-WIN-001, sign in as `Admin` / `zabbix` and
   **change the password immediately**. Run the host check:
   `bash ~/Enterprise-IT-HelpDesk-Lab/scripts/bash/linux_health_check.sh`.

Continue with agents, triggers and the ServiceNow integration in
[04-monitoring-alerting.md](04-monitoring-alerting.md). Snapshot: **`03-monitoring`**.

---

## Phase 5 onwards

- ServiceNow PDI configuration → [03-servicenow-itsm.md](03-servicenow-itsm.md)
- Monitoring, dashboards, alert-to-incident → [04-monitoring-alerting.md](04-monitoring-alerting.md)
- Endpoint management (BitLocker, LAPS, macOS, mobile, optional Intune) → [05-endpoint-management.md](05-endpoint-management.md)
- Break/fix practice → [06-lab-scenarios.md](06-lab-scenarios.md)
- Metrics and reporting → [07-metrics-reporting.md](07-metrics-reporting.md)

---

## Running on a 16 GB host

- Run **DC01 + LT-WIN-001 + MON01** together (about 9-10 GB). Power off MON01 when you use LT-WIN-002.
- After Windows 11 is installed you can drop LT-WIN-001 to 3 GB.
- Pause VMs you are not using (VMware *Suspend*) instead of shutting them down - faster to resume.
- Evaluation licences: Server lasts 180 days, Windows 11 Enterprise 90 days. Snapshots make rebuilds cheap.

## Build troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Install-ADDSForest` fails on the local Administrator password | Password does not meet complexity | `net user Administrator <complex password>` and re-run |
| Clients get 192.168.x.x or no address | VMware DHCP still enabled on VMnet8, or DC01 scope inactive | Untick VMware DHCP (Phase 0), `Get-DhcpServerv4Scope` |
| Client gets 169.254.x.x | DHCP server not authorized or service stopped | `Get-DhcpServerInDC`, `Get-Service DHCPServer` ([KB0005](../knowledge-base/KB0005-no-network-apipa-dhcp.md)) |
| Domain join: "domain could not be contacted" | Client DNS is not 10.10.10.10 | `ipconfig /all`; fix DHCP option 006 ([KB0004](../knowledge-base/KB0004-dns-resolution-failure.md)) |
| Windows 11 setup: "This PC can't run Windows 11" | No vTPM / Secure Boot | Add a TPM in VM settings (requires VM encryption) and enable UEFI Secure Boot |
| `Update-LapsADSchema` not found | Server not patched | Install the latest cumulative update, re-run `03-Build-ADStructure.ps1` |
| GPOs not applying | Computer in the wrong OU, or DC unreachable | `gpresult /r`, check OU ([KB0008](../knowledge-base/KB0008-group-policy-not-applying.md)) |
