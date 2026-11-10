#Requires -Version 5.1
<#
.SYNOPSIS
    Collects hardware, OS, network and installed-software inventory as JSON for the CMDB.

.DESCRIPTION
    Standalone and read-only; no admin rights required. Writes <COMPUTERNAME>.json to -OutputPath
    (UTF-8, no BOM) and returns the object. Consumed by:
      - integration/Sync-InventoryToCmdb.ps1  (pushes the CI to ServiceNow)
      - python/cmdb_reconcile.py              (data-quality report against a CMDB export)

    The file contains serial numbers, MAC addresses and the logged-on user. Treat it as internal data and
    do not commit inventories of real devices to a public repository.

.EXAMPLE
    .\Get-EndpointInventory.ps1 -OutputPath C:\Temp
.EXAMPLE
    .\Get-EndpointInventory.ps1 -NoSoftware | Select-Object ComputerName, SerialNumber, Model
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Get-Location).Path,
    [switch]$NoSoftware,
    [switch]$NoFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

function Get-Prop { param($Object, [string]$Name) if ($Object -and $Object.PSObject.Properties.Name -contains $Name) { $Object.$Name } else { $null } }

$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = @(Get-CimInstance Win32_Processor)
$enc  = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1
$cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$sysDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"

# Chassis type -> form factor (SMBIOS values)
$laptopTypes = 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
$desktopTypes = 3, 4, 5, 6, 7, 13, 15, 16, 35, 36
$chassis = @()
if ($enc -and $enc.ChassisTypes) { $chassis = @($enc.ChassisTypes | ForEach-Object { [int]$_ }) }
$formFactor = 'Other'
if (@($chassis | Where-Object { $laptopTypes -contains $_ }).Count) { $formFactor = 'Laptop' }
elseif (@($chassis | Where-Object { $desktopTypes -contains $_ }).Count) { $formFactor = 'Desktop' }
$virtual = ($cs.Model -match 'Virtual|VMware|KVM|HVM domU') -or ($cs.Manufacturer -match 'VMware|QEMU|Xen|Microsoft Corporation' -and $cs.Model -match 'Virtual')
if ($virtual) { $formFactor = 'Virtual Machine' }

# Disks
$disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{ Model = $_.Model; SizeGB = [math]::Round($_.Size / 1GB, 0); Interface = $_.InterfaceType }
})
try {
    $media = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName, MediaType, BusType, @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 0) } })
    if ($media.Count) { $disks = $media }
}
catch { }

# Network (adapters that are up, excluding loopback)
$nics = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object {
    $ip = @(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
    [pscustomobject]@{ Name = $_.Name; Description = $_.InterfaceDescription; MacAddress = $_.MacAddress; IPv4 = ($ip -join ', '); LinkSpeed = $_.LinkSpeed }
})

# Installed software (machine 64/32-bit + current user), excluding updates and system components
$software = @()
if (-not $NoSoftware) {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $software = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | Where-Object {
            (Get-Prop $_ 'DisplayName') -and -not (Get-Prop $_ 'SystemComponent') -and -not (Get-Prop $_ 'ParentKeyName') -and
            ((Get-Prop $_ 'ReleaseType') -notin 'Update', 'Hotfix', 'Security Update')
        } | ForEach-Object {
            [pscustomobject]@{
                Name        = ([string](Get-Prop $_ 'DisplayName')).Trim()
                Version     = [string](Get-Prop $_ 'DisplayVersion')
                Publisher   = [string](Get-Prop $_ 'Publisher')
                InstallDate = [string](Get-Prop $_ 'InstallDate')
            }
        } | Sort-Object Name, Version -Unique)
}

$battery = $null
$b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
if ($b) { $battery = [pscustomobject]@{ ChargePercent = $b.EstimatedChargeRemaining; Status = $b.Status } }

$inventory = [pscustomobject]@{
    SchemaVersion = 1
    CollectedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    ComputerName  = $env:COMPUTERNAME
    Domain        = $cs.Domain
    DomainJoined  = [bool]$cs.PartOfDomain
    LoggedOnUser  = $cs.UserName
    Manufacturer  = $cs.Manufacturer
    Model         = $cs.Model
    SerialNumber  = ([string]$bios.SerialNumber).Trim()
    AssetTag      = [string](Get-Prop $enc 'SMBIOSAssetTag')
    FormFactor    = $formFactor
    BiosVersion   = $bios.SMBIOSBIOSVersion
    OS            = [pscustomobject]@{
        Name           = $os.Caption
        DisplayVersion = [string](Get-Prop $cv 'DisplayVersion')
        Build          = '{0}.{1}' -f $os.BuildNumber, (Get-Prop $cv 'UBR')
        Architecture   = $os.OSArchitecture
        InstallDate    = $os.InstallDate.ToString('yyyy-MM-dd')
        LastBoot       = $os.LastBootUpTime.ToString('yyyy-MM-ddTHH:mm:ss')
    }
    Cpu           = [pscustomobject]@{ Name = ($cpu[0].Name).Trim(); Sockets = $cpu.Count; Cores = ($cpu | Measure-Object NumberOfCores -Sum).Sum; LogicalProcessors = ($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum }
    MemoryGB      = [math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
    SystemDrive   = [pscustomobject]@{ SizeGB = [math]::Round($sysDisk.Size / 1GB, 0); FreeGB = [math]::Round($sysDisk.FreeSpace / 1GB, 1) }
    Disks         = $disks
    Network       = $nics
    Battery       = $battery
    SoftwareCount = $software.Count
    Software      = $software
}

if (-not $NoFile) {
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $file = Join-Path $OutputPath "$($env:COMPUTERNAME).json"
    [System.IO.File]::WriteAllText($file, ($inventory | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Inventory written to $file ($($software.Count) applications)" -ForegroundColor Green
}
return $inventory
