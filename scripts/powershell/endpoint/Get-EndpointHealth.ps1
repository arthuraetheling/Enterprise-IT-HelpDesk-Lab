#Requires -Version 5.1
<#
.SYNOPSIS
    Endpoint health check for Windows 10/11 laptops - the first thing Tier 1/Tier 2 runs on a "slow / broken" ticket.

.DESCRIPTION
    Standalone (no dependencies) so it can be copied to any device. Runs without admin rights; a few
    values are more complete when elevated. Thresholds match docs/01-lab-design.md section 9.

    Checks: disk free (per fixed volume), memory, CPU, uptime, pending reboot, Microsoft Defender,
            Windows Firewall, stopped automatic services, System log critical/error events, gateway reachability.

    Exit codes (for monitoring / scheduled tasks): 0 = OK, 1 = Warning, 2 = Critical.

.PARAMETER Format
    Console (default, colored table), Json or Html (writes a report file to -OutputPath), Object (returns
    the result object - used by integration/Invoke-HealthCheckAndAlert.ps1).

.EXAMPLE
    .\Get-EndpointHealth.ps1
.EXAMPLE
    .\Get-EndpointHealth.ps1 -Format Html -OutputPath C:\Temp
.EXAMPLE
    $r = .\Get-EndpointHealth.ps1 -Format Object; $r.Checks | Where-Object Status -ne 'OK'
#>
[CmdletBinding()]
param(
    [ValidateSet('Console', 'Json', 'Html', 'Object')][string]$Format = 'Console',
    [string]$OutputPath = (Get-Location).Path,
    [ValidateRange(1, 99)][int]$DiskWarnPercent = 15,
    [ValidateRange(1, 99)][int]$DiskCritPercent = 10,
    # Absolute floors (same idea as Zabbix vfs.fs triggers): a large disk with plenty of GB free is not alarmed.
    [int]$DiskWarnMinFreeGB = 25,
    [int]$DiskCritMinFreeGB = 10,
    [ValidateRange(1, 100)][int]$MemWarnPercent = 85,
    [ValidateRange(1, 100)][int]$MemCritPercent = 95,
    [int]$UptimeWarnDays = 14,
    [int]$UptimeCritDays = 30,
    [int]$SignatureMaxAgeDays = 3,
    [int]$EventLookbackHours = 24,
    [string[]]$ServiceExclusions = @('gupdate', 'gupdatem', 'edgeupdate', 'edgeupdatem', 'GoogleUpdater*', 'MapsBroker',
        'sppsvc', 'RemoteRegistry', 'TrustedInstaller', 'WbioSrvc', 'ShellHWDetection', 'tiledatamodelsvc',
        'clr_optimization*', 'MSIServer', 'wuauserv', 'BITS', 'UsoSvc', 'DoSvc', 'WaaSMedicSvc', 'NetTcpPortSharing',
        'dbupdate*', 'Intel(R) TPM Provisioning Service', 'IntelTPMProvisioningService')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string]$Id, [string]$Name, [ValidateSet('OK', 'Warning', 'Critical', 'Unknown')][string]$Status,
          [string]$Value, [string]$Detail = '')
    $checks.Add([pscustomobject]@{ Id = $Id; Check = $Name; Status = $Status; Value = $Value; Detail = $Detail })
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- System information ------------------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$displayVersion = ''
if ($cv -and $cv.PSObject.Properties.Name -contains 'DisplayVersion') { $displayVersion = $cv.DisplayVersion }
$ubr = ''
if ($cv -and $cv.PSObject.Properties.Name -contains 'UBR') { $ubr = ".$($cv.UBR)" }
$uptime = (Get-Date) - $os.LastBootUpTime
$isAdmin = Test-IsAdmin

$system = [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    Domain       = $cs.Domain
    DomainJoined = [bool]$cs.PartOfDomain
    LoggedOnUser = $cs.UserName
    Model        = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
    OS           = $os.Caption
    Version      = ('{0} (build {1}{2})' -f $displayVersion, $os.BuildNumber, $ubr).Trim()
    LastBoot     = $os.LastBootUpTime
    UptimeDays   = [math]::Round($uptime.TotalDays, 1)
    RanElevated  = $isAdmin
}

# --- 1. Disk --------------------------------------------------------------------------------------------
foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
    if (-not $d.Size) { continue }
    $pct    = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
    $freeGb = [math]::Round($d.FreeSpace / 1GB, 1)
    $sizeGb = [math]::Round($d.Size / 1GB, 1)
    $status = 'OK'
    if ($pct -lt $DiskCritPercent -and $freeGb -lt $DiskCritMinFreeGB) { $status = 'Critical' }
    elseif ($pct -lt $DiskWarnPercent -and $freeGb -lt $DiskWarnMinFreeGB) { $status = 'Warning' }
    $id = 'Disk-' + $d.DeviceID.TrimEnd(':')
    Add-Check $id "Disk $($d.DeviceID)" $status "$pct% free ($freeGb of $sizeGb GB)" `
        "Warn <$DiskWarnPercent% and <$DiskWarnMinFreeGB GB; critical <$DiskCritPercent% and <$DiskCritMinFreeGB GB"
}

# --- 2. Memory ------------------------------------------------------------------------------------------
$memUsed = [math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 1)
$memTot  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$status = 'OK'
if ($memUsed -gt $MemCritPercent) { $status = 'Critical' } elseif ($memUsed -gt $MemWarnPercent) { $status = 'Warning' }
$topProc = (Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3 |
    ForEach-Object { '{0} {1:N0} MB' -f $_.ProcessName, ($_.WorkingSet64 / 1MB) }) -join ', '
Add-Check 'Memory' 'Memory' $status "$memUsed% used of $memTot GB" "Top: $topProc"

# --- 3. CPU (3 samples, locale-independent perf class) ------------------------------------------------
$samples = @()
for ($i = 0; $i -lt 3; $i++) {
    $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
    if ($p) { $samples += [double]$p.PercentProcessorTime }
    if ($i -lt 2) { Start-Sleep -Milliseconds 700 }
}
if ($samples.Count -gt 0) {
    $cpu = [math]::Round(($samples | Measure-Object -Average).Average, 0)
    $status = 'OK'
    if ($cpu -gt 90) { $status = 'Warning' }
    Add-Check 'CPU' 'CPU' $status "$cpu% (3-sample average)" 'Sustained load is tracked by Zabbix; this is a point-in-time sample'
}
else { Add-Check 'CPU' 'CPU' 'Unknown' 'n/a' 'Performance counters unavailable' }

# --- 4. Uptime ----------------------------------------------------------------------------------------
$status = 'OK'
if ($uptime.TotalDays -gt $UptimeCritDays) { $status = 'Critical' } elseif ($uptime.TotalDays -gt $UptimeWarnDays) { $status = 'Warning' }
Add-Check 'Uptime' 'Uptime' $status ('{0:N1} days' -f $uptime.TotalDays) "Last boot $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')); patches need a reboot to apply"

# --- 5. Pending reboot ------------------------------------------------------------------------------
$reasons = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Component Based Servicing' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
$pfro = $false
$sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
if ($sm -and $sm.PSObject.Properties.Name -contains 'PendingFileRenameOperations' -and $sm.PendingFileRenameOperations) { $pfro = $true }
if ($reasons.Count -gt 0) {
    Add-Check 'PendingReboot' 'Pending reboot' 'Warning' 'Yes' ("Reason: $($reasons -join ', ')")
}
else {
    $note = ''
    if ($pfro) { $note = 'PendingFileRenameOperations present (informational - often set by installers)' }
    Add-Check 'PendingReboot' 'Pending reboot' 'OK' 'No' $note
}

# --- 6. Microsoft Defender ------------------------------------------------------------------------------
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $sigAge = [int]$mp.AntivirusSignatureAge
    $mode = ''
    if ($mp.PSObject.Properties.Name -contains 'AMRunningMode') { $mode = [string]$mp.AMRunningMode }
    if ($mode -match 'Passive|EDR Block') {
        Add-Check 'Defender' 'Microsoft Defender' 'Unknown' "Running mode: $mode" 'Another antivirus is primary - check it in its own console'
    }
    elseif (-not $mp.RealTimeProtectionEnabled) {
        Add-Check 'Defender' 'Microsoft Defender' 'Critical' 'Real-time protection OFF' "Signatures $sigAge day(s) old"
    }
    elseif ($sigAge -gt $SignatureMaxAgeDays) {
        Add-Check 'Defender' 'Microsoft Defender' 'Warning' "Signatures $sigAge day(s) old" "Max $SignatureMaxAgeDays days; run Update-MpSignature"
    }
    else {
        Add-Check 'Defender' 'Microsoft Defender' 'OK' "Real-time on, signatures $sigAge day(s) old" "Engine $($mp.AMEngineVersion)"
    }
}
catch {
    $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty displayName)
    Add-Check 'Defender' 'Microsoft Defender' 'Unknown' 'Status unavailable' ("Registered antivirus: " + ($av -join ', '))
}

# --- 7. Windows Firewall ----------------------------------------------------------------------------
try {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    $off = @($profiles | Where-Object { -not $_.Enabled -or [string]$_.Enabled -eq 'False' } | Select-Object -ExpandProperty Name)
    if ($off.Count -gt 0) { Add-Check 'Firewall' 'Windows Firewall' 'Critical' "Disabled: $($off -join ', ')" 'All profiles must be on (CON-C-Workstation-Baseline)' }
    else { Add-Check 'Firewall' 'Windows Firewall' 'OK' 'Domain/Private/Public enabled' '' }
}
catch { Add-Check 'Firewall' 'Windows Firewall' 'Unknown' 'Status unavailable' $_.Exception.Message }

# --- 8. Automatic services that are not running ----------------------------------------------------
$stopped = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" -ErrorAction SilentlyContinue |
    Where-Object {
        $svc = $_
        $excluded = @($ServiceExclusions | Where-Object { $svc.Name -like $_ -or $svc.DisplayName -like $_ }).Count -gt 0
        $delayed = ($svc.PSObject.Properties.Name -contains 'DelayedAutoStart') -and $svc.DelayedAutoStart
        $trigger = Test-Path ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}\TriggerInfo" -f $svc.Name)
        -not ($excluded -or $delayed -or $trigger)
    })
if ($stopped.Count -gt 0) {
    $names = ($stopped | Select-Object -First 5 | ForEach-Object { "$($_.DisplayName) [$($_.Name)]" }) -join '; '
    Add-Check 'Services' 'Automatic services' 'Warning' "$($stopped.Count) stopped" $names
}
else { Add-Check 'Services' 'Automatic services' 'OK' 'All running' 'Trigger-start, delayed-start and known updater services excluded' }

# --- 9. System event log ---------------------------------------------------------------------------
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddHours(-$EventLookbackHours) } -MaxEvents 500 -ErrorAction Stop)
}
catch { $events = @() }
$crit = @($events | Where-Object Level -eq 1).Count
$err  = @($events | Where-Object Level -eq 2).Count
$top  = ($events | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3 |
    ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
$status = 'OK'
if ($crit -ge 1 -or $err -ge 10) { $status = 'Warning' }
Add-Check 'EventLog' "System log (last ${EventLookbackHours}h)" $status "$crit critical, $err error" $top

# --- 10. Network gateway -----------------------------------------------------------------------------
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
if (-not $route) {
    Add-Check 'Network' 'Default gateway' 'Warning' 'No default route' 'Device appears offline - run Invoke-NetworkTriage.ps1'
}
else {
    $gw = $route.NextHop
    $ok = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($ok) { Add-Check 'Network' 'Default gateway' 'OK' "$gw reachable" "Interface $($route.InterfaceAlias)" }
    else { Add-Check 'Network' 'Default gateway' 'Warning' "$gw not responding to ping" 'May be filtered; run Invoke-NetworkTriage.ps1' }
}

# --- Overall ---------------------------------------------------------------------------------------
$overall = 'OK'; $exitCode = 0
if (@($checks | Where-Object Status -eq 'Critical').Count -gt 0) { $overall = 'Critical'; $exitCode = 2 }
elseif (@($checks | Where-Object Status -eq 'Warning').Count -gt 0) { $overall = 'Warning'; $exitCode = 1 }

$report = [pscustomobject]@{
    SchemaVersion = 1
    CollectedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    System        = $system
    Overall       = $overall
    ExitCode      = $exitCode
    Checks        = $checks.ToArray()
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
switch ($Format) {
    'Object' { return $report }

    'Json' {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $file = Join-Path $OutputPath "$($env:COMPUTERNAME)-health-$stamp.json"
        [System.IO.File]::WriteAllText($file, ($report | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Health report written to $file (overall: $overall)"
    }

    'Html' {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $file = Join-Path $OutputPath "$($env:COMPUTERNAME)-health-$stamp.html"
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
        $rows = ($checks | ForEach-Object {
            "<tr><td>$(& $enc $_.Check)</td><td><span class='b $($_.Status.ToLower())'>$($_.Status)</span></td><td>$(& $enc $_.Value)</td><td>$(& $enc $_.Detail)</td></tr>"
        }) -join "`n"
        $sysRows = ($system.PSObject.Properties | ForEach-Object { "<tr><th>$($_.Name)</th><td>$(& $enc $_.Value)</td></tr>" }) -join "`n"
        $html = @"
<!doctype html><html><head><meta charset="utf-8"><title>Endpoint health - $($env:COMPUTERNAME)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1f2933;background:#fff}h1{font-size:20px;margin:0 0 4px}
.meta{color:#52606d;font-size:13px;margin-bottom:16px}table{border-collapse:collapse;width:100%;font-size:13px;margin-bottom:20px}
th,td{border:1px solid #d9dee3;padding:6px 8px;text-align:left;vertical-align:top}th{background:#f3f5f7;width:180px}
.b{display:inline-block;padding:1px 8px;border-radius:10px;font-weight:600;font-size:12px}
.ok{background:#e3f6ec;color:#0b6b3a}.warning{background:#fff4d6;color:#8a5a00}.critical{background:#fde4e1;color:#a4161a}.unknown{background:#eceff3;color:#52606d}
</style></head><body>
<h1>Endpoint health - $($env:COMPUTERNAME) <span class='b $($overall.ToLower())'>$overall</span></h1>
<div class="meta">Collected $($report.CollectedAt) &middot; Get-EndpointHealth.ps1</div>
<table>$sysRows</table>
<table><tr><th>Check</th><th>Status</th><th>Value</th><th>Detail</th></tr>$rows</table>
</body></html>
"@
        [System.IO.File]::WriteAllText($file, $html, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Health report written to $file (overall: $overall)"
    }

    default {
        Write-Host ''
        Write-Host ("Endpoint health - {0}  ({1}, {2})" -f $system.ComputerName, $system.OS, $system.Version) -ForegroundColor Cyan
        Write-Host ("Model: {0}  |  Domain: {1}  |  Uptime: {2} days  |  Elevated: {3}" -f $system.Model, $system.Domain, $system.UptimeDays, $system.RanElevated)
        Write-Host ''
        Write-Host ('{0,-26} {1,-9} {2,-38} {3}' -f 'CHECK', 'STATUS', 'VALUE', 'DETAIL')
        foreach ($c in $checks) {
            $color = @{ OK = 'Green'; Warning = 'Yellow'; Critical = 'Red'; Unknown = 'DarkGray' }[$c.Status]
            $detail = $c.Detail
            if ($detail.Length -gt 70) { $detail = $detail.Substring(0, 67) + '...' }
            Write-Host ('{0,-26} {1,-9} {2,-38} {3}' -f $c.Check, $c.Status, $c.Value, $detail) -ForegroundColor $color
        }
        Write-Host ''
        $oc = @{ OK = 'Green'; Warning = 'Yellow'; Critical = 'Red' }[$overall]
        Write-Host ("Overall: {0} (exit code {1})" -f $overall, $exitCode) -ForegroundColor $oc
        if (-not $isAdmin) { Write-Host 'Tip: run elevated for complete results.' -ForegroundColor DarkGray }
    }
}
exit $exitCode
