#Requires -Version 5.1
<#
.SYNOPSIS
    Prepares DC01 (static IP + hostname) and promotes it to the first domain controller of the lab forest.

.DESCRIPTION
    Run on a fresh Windows Server 2022/2025 VM as the local Administrator, in an elevated session.

      Run 1: sets the static IPv4 address from Lab.Config.psd1 (10.10.10.10/24, gateway 10.10.10.2),
             renames the server to DC01 and reboots.
      Run 2: installs the AD DS role and creates the forest corp.contoso.internal with integrated DNS.
             Prompts for the Directory Services Restore Mode (DSRM) password, then reboots automatically.

    The script is idempotent: steps that are already done are skipped.

.PARAMETER InterfaceAlias
    Network adapter to configure. Defaults to the first adapter that is Up.

.PARAMETER NoReboot
    Do not reboot automatically (you must reboot before continuing).

.EXAMPLE
    PS C:\Lab\scripts\powershell\lab-build> .\01-Install-DomainController.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InterfaceAlias,
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabElevated
$cfg = Get-LabConfig
$dc  = $cfg.DomainController

# --- Already a domain controller? -----------------------------------------------------------
$role = (Get-CimInstance Win32_ComputerSystem).DomainRole   # 4 = backup DC, 5 = primary DC
if ($role -ge 4) {
    Write-LabOk "$env:COMPUTERNAME is already a domain controller of $((Get-CimInstance Win32_ComputerSystem).Domain). Next: 02-Configure-DnsDhcp.ps1"
    return
}

# --- Step 1: static IP ----------------------------------------------------------------------
Write-LabStep 'Configuring static IPv4 address'
if (-not $InterfaceAlias) {
    $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Sort-Object ifIndex | Select-Object -First 1
    if (-not $adapter) { throw 'No network adapter is Up. Connect the VM NIC to VMnet8 and retry.' }
    $InterfaceAlias = $adapter.Name
}
$current = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $dc.IPv4 }

if ($current) {
    Write-LabSkip "$InterfaceAlias already has $($dc.IPv4)"
}
elseif ($PSCmdlet.ShouldProcess($InterfaceAlias, "Set static IP $($dc.IPv4)/$($dc.PrefixLength) gw $($dc.Gateway)")) {
    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -Dhcp Disabled
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $dc.IPv4 -PrefixLength $dc.PrefixLength `
        -DefaultGateway $dc.Gateway | Out-Null
    # Until DNS is installed, resolve through the VMware NAT DNS proxy so Windows Update keeps working.
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $dc.Gateway
    Write-LabOk "Static IP $($dc.IPv4)/$($dc.PrefixLength) set on $InterfaceAlias"
}

# --- Step 2: hostname -----------------------------------------------------------------------
Write-LabStep 'Checking computer name'
if ($env:COMPUTERNAME -ne $dc.Name) {
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Rename to $($dc.Name)")) {
        Rename-Computer -NewName $dc.Name -Force
        Write-LabOk "Renamed to $($dc.Name). A reboot is required; run this script again afterwards."
        if (-not $NoReboot) { Restart-Computer -Force }
    }
    return
}
Write-LabSkip "Computer name is already $($dc.Name)"

# --- Step 3: AD DS role + forest --------------------------------------------------------------
Write-LabStep 'Installing the AD DS role'
$feature = Get-WindowsFeature -Name AD-Domain-Services
if (-not $feature.Installed) {
    if ($PSCmdlet.ShouldProcess('AD-Domain-Services', 'Install-WindowsFeature')) {
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
        Write-LabOk 'AD DS role installed'
    }
}
else { Write-LabSkip 'AD DS role already installed' }

Write-LabStep "Promoting $($dc.Name) to the first DC of $($cfg.DomainFqdn)"
Import-Module ADDSDeployment
$dsrm = Read-Host -AsSecureString 'Enter a Directory Services Restore Mode (DSRM) password (store it in your password manager)'

$forestParams = @{
    DomainName                    = $cfg.DomainFqdn
    DomainNetbiosName             = $cfg.NetBiosName
    ForestMode                    = 'WinThreshold'   # Windows Server 2016 functional level (valid on 2022 and 2025)
    DomainMode                    = 'WinThreshold'
    InstallDns                    = $true
    CreateDnsDelegation           = $false
    DatabasePath                  = 'C:\Windows\NTDS'
    LogPath                       = 'C:\Windows\NTDS'
    SysvolPath                    = 'C:\Windows\SYSVOL'
    SafeModeAdministratorPassword = $dsrm
    NoRebootOnCompletion          = [bool]$NoReboot
    Force                         = $true
}

if ($PSCmdlet.ShouldProcess($cfg.DomainFqdn, 'Install-ADDSForest')) {
    Install-ADDSForest @forestParams
    Write-LabOk 'Forest created. The server reboots now; log in as CONTOSO\Administrator and run 02-Configure-DnsDhcp.ps1'
}
