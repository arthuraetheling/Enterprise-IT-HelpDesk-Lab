#Requires -Version 5.1
<#
.SYNOPSIS
    Pushes Get-EndpointInventory.ps1 JSON into the ServiceNow CMDB (cmdb_ci_computer), create-or-update.

.DESCRIPTION
    Matches an existing CI on serial number first, then on name, so re-running never creates duplicates.
    Reference fields (manufacturer -> core_company, assigned_to -> sys_user) are resolved to sys_ids and
    skipped when no match exists. Installed software is counted in the description but not synced
    (software asset management is out of scope for the lab).

    Production note: large estates should use the Identification and Reconciliation Engine (IRE) API or
    a discovery tool; this script shows the data flow and the upsert logic.

.EXAMPLE
    .\Sync-InventoryToCmdb.ps1 -InventoryPath .\LT-WIN-001.json -DryRun
.EXAMPLE
    .\Sync-InventoryToCmdb.ps1 -InventoryPath \\DC01\Inventory$ -InstanceUrl https://dev12345.service-now.com -Credential (Get-Credential)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$InventoryPath,
    [string]$InstanceUrl,
    [pscredential]$Credential,
    [string]$CredentialPath,
    [switch]$DryRun,
    [string]$Class = 'cmdb_ci_computer'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ServiceNow.psm1') -Force

if ($CredentialPath -and -not $Credential) { $Credential = Import-Clixml -Path $CredentialPath }
if ($DryRun) {
    if (-not $InstanceUrl) { $InstanceUrl = 'https://dev00000.service-now.com' }
    Connect-ServiceNow -InstanceUrl $InstanceUrl -DryRun
}
else {
    if (-not $InstanceUrl -or -not $Credential) { throw 'Provide -InstanceUrl and -Credential/-CredentialPath, or use -DryRun.' }
    Connect-ServiceNow -InstanceUrl $InstanceUrl -Credential $Credential
}

$files = @()
if (Test-Path -LiteralPath $InventoryPath -PathType Container) { $files = @(Get-ChildItem -LiteralPath $InventoryPath -Filter '*.json' -File) }
else { $files = @(Get-Item -LiteralPath $InventoryPath) }
if ($files.Count -eq 0) { throw "No inventory JSON found at $InventoryPath" }

$placeholderSerials = 'To be filled by O.E.M.', 'Default string', 'System Serial Number', '0', 'None', ''
$results = foreach ($f in $files) {
    try {
        $inv = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
        $serial = [string]$inv.SerialNumber
        if ($placeholderSerials -contains $serial.Trim()) { $serial = '' }

        $nic = @($inv.Network | Where-Object { $_.IPv4 }) | Select-Object -First 1
        $attrs = [ordered]@{
            model_number       = $inv.Model
            os                 = $inv.OS.Name
            os_version         = ('{0} ({1})' -f $inv.OS.DisplayVersion, $inv.OS.Build).Trim()
            cpu_name           = $inv.Cpu.Name
            cpu_count          = $inv.Cpu.Sockets
            cpu_core_count     = $inv.Cpu.Cores
            ram                = [int]$inv.MemoryGB * 1024
            disk_space         = $inv.SystemDrive.SizeGB
            form_factor        = $inv.FormFactor
            virtual            = ([string]($inv.FormFactor -eq 'Virtual Machine')).ToLower()
            dns_domain         = $inv.Domain
            install_status     = '1'   # Installed
            operational_status = '1'   # Operational
            last_discovered    = ([datetime]$inv.CollectedAt).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
            short_description  = ('{0} {1} - {2} apps - inventory {3}' -f $inv.Manufacturer, $inv.Model, $inv.SoftwareCount, $inv.CollectedAt)
        }
        $tag = [string]$inv.AssetTag
        if ($tag -and $tag -notmatch 'No Asset|Default|^\s*$') { $attrs['asset_tag'] = $tag }
        if ($nic) {
            $attrs['ip_address'] = ($nic.IPv4 -split ',')[0].Trim()
            $attrs['mac_address'] = ($nic.MacAddress -replace '-', ':')
        }
        if ($inv.Manufacturer) {
            $mfr = Resolve-SnReference -Table 'core_company' -Field 'name' -Value $inv.Manufacturer
            if ($mfr) { $attrs['manufacturer'] = $mfr }
        }
        if ($inv.LoggedOnUser) {
            $userName = ([string]$inv.LoggedOnUser).Split('\')[-1]
            $uid = Resolve-SnReference -Table 'sys_user' -Field 'user_name' -Value $userName
            if ($uid) { $attrs['assigned_to'] = $uid }
        }
        $ht = @{}
        foreach ($k in $attrs.Keys) { $ht[$k] = $attrs[$k] }

        $r = Set-SnComputerCi -Name $inv.ComputerName -SerialNumber $serial -Attributes $ht -Class $Class
        if ($r) { [pscustomobject]@{ File = $f.Name; Name = $inv.ComputerName; Serial = $serial; Action = $r.Action; SysId = $r.SysId } }
    }
    catch {
        [pscustomobject]@{ File = $f.Name; Name = ''; Serial = ''; Action = "Failed: $($_.Exception.Message)"; SysId = '' }
    }
}

$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
