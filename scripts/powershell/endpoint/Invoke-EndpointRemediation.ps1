#Requires -Version 5.1
<#
.SYNOPSIS
    Runs common Tier 1/Tier 2 fixes on a Windows endpoint, with -WhatIf, a transcript and a ticket note.

.DESCRIPTION
    Standalone. Most actions need an elevated session; the script tells you when one is skipped.

      FlushDns             Clear the DNS client cache (+ re-register DNS when elevated)          KB0004
      RenewDhcp            Release/renew DHCP on physical adapters (skips VPN adapters)           KB0005
      ClearTemp            Delete temp files older than -TempFileAgeDays (user; system if admin) KB0013
      DiskCleanup          ClearTemp + empty Recycle Bin + report the largest files (no deletes) KB0013
      RestartSpooler       Stop spooler, clear stuck jobs, start spooler                         KB0012
      ResetWindowsUpdate   Stop WU services, rename SoftwareDistribution/catroot2, restart        -
      GpUpdate             gpupdate /force + gpresult summary                                    KB0008
      RepairSecureChannel  Test-ComputerSecureChannel -Repair (prompts for a domain credential)  KB0009
      SyncTime             Start w32time, follow the domain hierarchy, force resync              KB0010
      ResetNetworkStack    netsh winsock reset + netsh int ip reset (reboot required)            KB0004/5

.EXAMPLE
    .\Invoke-EndpointRemediation.ps1 -Action DiskCleanup -WhatIf
.EXAMPLE
    .\Invoke-EndpointRemediation.ps1 -Action FlushDns, GpUpdate -TicketNumber INC0010004
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('FlushDns', 'RenewDhcp', 'ClearTemp', 'DiskCleanup', 'RestartSpooler', 'ResetWindowsUpdate',
                 'GpUpdate', 'RepairSecureChannel', 'SyncTime', 'ResetNetworkStack')]
    [string[]]$Action,
    [int]$TempFileAgeDays = 1,
    [string]$LargeFileSearchPath = "$env:SystemDrive\Users",
    [int]$LargeFileMinMB = 500,
    [pscredential]$Credential,
    [string]$TicketNumber = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

# Load modules up front with -WhatIf off; otherwise module auto-loading prints "What if: Set Alias" noise.
$savedWhatIf = $WhatIfPreference
$WhatIfPreference = $false
Import-Module CimCmdlets, DnsClient, NetTCPIP, PrintManagement -ErrorAction SilentlyContinue
$WhatIfPreference = $savedWhatIf

$principal =New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needsAdmin = @('RenewDhcp', 'RestartSpooler', 'ResetWindowsUpdate', 'RepairSecureChannel', 'SyncTime', 'ResetNetworkStack')
$vpnPattern = 'VPN|TAP-|WireGuard|AnyConnect|Secure Client|GlobalProtect|PANGP|Fortinet|Juniper|Pulse|Zscaler|Cisco'

$logRoot = Join-Path $env:TEMP 'ContosoHelpDesk'
if ($isAdmin) { $logRoot = Join-Path $env:ProgramData 'ContosoHelpDesk\Logs' }
if (-not (Test-Path $logRoot)) { New-Item -ItemType Directory -Path $logRoot -Force -WhatIf:$false | Out-Null }
$transcript = Join-Path $logRoot ("remediation-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$results = New-Object System.Collections.Generic.List[object]
function Add-Result { param([string]$Name, [string]$Result, [string]$Detail) $results.Add([pscustomobject]@{ Action = $Name; Result = $Result; Detail = $Detail }) }

function Get-FreeGB { [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace / 1GB, 2) }

function Remove-OldFile {
    param([string]$Path, [datetime]$Cutoff)
    $out = [pscustomobject]@{ Path = $Path; Candidates = 0; CandidateMB = 0; Removed = 0; FreedMB = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $Cutoff })
    $bytes = 0; foreach ($f in $files) { $bytes += $f.Length }
    $out.Candidates = $files.Count; $out.CandidateMB = [math]::Round($bytes / 1MB, 1)
    if ($files.Count -gt 0 -and $PSCmdlet.ShouldProcess($Path, "Delete $($files.Count) file(s) older than $($Cutoff.ToString('yyyy-MM-dd HH:mm')) ($($out.CandidateMB) MB)")) {
        $freed = 0
        foreach ($f in $files) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop -WhatIf:$false; $out.Removed++; $freed += $f.Length } catch { }
        }
        $out.FreedMB = [math]::Round($freed / 1MB, 1)
    }
    return $out
}

function Invoke-ClearTemp {
    $cutoff = (Get-Date).AddDays(-$TempFileAgeDays)
    $paths = @($env:TEMP)
    if ($isAdmin) {
        $paths += "$env:SystemRoot\Temp"
        $paths += @(Get-ChildItem "$env:SystemDrive\Users" -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' } | Where-Object { Test-Path -LiteralPath $_ })
    }
    $paths = @($paths | Select-Object -Unique)
    $stats = @($paths | ForEach-Object { Remove-OldFile -Path $_ -Cutoff $cutoff })
    $cand = ($stats | Measure-Object CandidateMB -Sum).Sum
    $freed = ($stats | Measure-Object FreedMB -Sum).Sum
    $scope = 'current user only (not elevated)'
    if ($isAdmin) { $scope = "$($paths.Count) temp folders" }
    if ($WhatIfPreference) { return "WhatIf: $cand MB in $scope would be deleted" }
    return "Freed $freed MB of $cand MB eligible ($scope; locked files skipped)"
}

$hostLine = "Remediation on $env:COMPUTERNAME by $env:USERDOMAIN\$env:USERNAME (elevated: $isAdmin)"
if (-not $WhatIfPreference) { Start-Transcript -Path $transcript -WhatIf:$false | Out-Null }
try {
    Write-Host $hostLine -ForegroundColor Cyan
    foreach ($a in $Action) {
        Write-Host ''
        Write-Host "==> $a" -ForegroundColor Cyan
        if (($needsAdmin -contains $a) -and -not $isAdmin) { Add-Result $a 'Skipped' 'Requires an elevated session (Run as administrator)'; continue }
        try {
            switch ($a) {
                'FlushDns' {
                    if ($PSCmdlet.ShouldProcess('DNS client cache', 'Clear')) {
                        Clear-DnsClientCache
                        $extra = ''
                        if ($isAdmin) { Register-DnsClient; $extra = '; DNS registration refreshed' }
                        Add-Result $a 'Success' "DNS cache cleared$extra"
                    }
                    else { Add-Result $a 'WhatIf' 'Would clear DNS cache' }
                }
                'RenewDhcp' {
                    $cfgs = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE AND DHCPEnabled=TRUE' |
                        Where-Object { $_.Description -notmatch $vpnPattern })
                    if ($cfgs.Count -eq 0) { Add-Result $a 'Skipped' 'No DHCP-enabled physical adapters'; break }
                    $done = @()
                    foreach ($c in $cfgs) {
                        if ($PSCmdlet.ShouldProcess($c.Description, 'Release and renew DHCP lease')) {
                            $null = Invoke-CimMethod -InputObject $c -MethodName ReleaseDHCPLease
                            $r = Invoke-CimMethod -InputObject $c -MethodName RenewDHCPLease
                            $now = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "Index=$($c.Index)"
                            $done += "$($c.Description): rc=$($r.ReturnValue), IP $(@($now.IPAddress)[0])"
                        }
                    }
                    if ($done.Count) { Add-Result $a 'Success' ($done -join '; ') } else { Add-Result $a 'WhatIf' "Would renew $($cfgs.Count) adapter(s)" }
                }
                'ClearTemp' {
                    $msg = Invoke-ClearTemp
                    $res = 'Success'
                    if ($WhatIfPreference) { $res = 'WhatIf' }
                    Add-Result $a $res $msg
                }
                'DiskCleanup' {
                    $before = Get-FreeGB
                    $msg = Invoke-ClearTemp
                    if ($PSCmdlet.ShouldProcess('Recycle Bin', 'Empty')) { Clear-RecycleBin -Force -ErrorAction SilentlyContinue -WhatIf:$false }
                    Write-Host "    Largest files under $LargeFileSearchPath (>= $LargeFileMinMB MB) - review with the user before deleting:"
                    $large = @(Get-ChildItem -LiteralPath $LargeFileSearchPath -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.Length -ge ($LargeFileMinMB * 1MB) } | Sort-Object Length -Descending | Select-Object -First 15)
                    if ($large.Count -gt 0) {
                        $large | Select-Object @{ n = 'SizeGB'; e = { [math]::Round($_.Length / 1GB, 2) } }, LastWriteTime, FullName |
                            Format-Table -AutoSize | Out-String -Width 200 | Write-Host
                    }
                    else { Write-Host '    (none found)' }
                    $after = Get-FreeGB
                    $res = 'Success'; $bin = 'Recycle Bin emptied'
                    if ($WhatIfPreference) { $res = 'WhatIf'; $bin = 'Recycle Bin would be emptied' }
                    Add-Result $a $res "$msg; $bin; C: free $before GB -> $after GB; $($large.Count) large file(s) listed for review"
                }
                'RestartSpooler' {
                    if ($PSCmdlet.ShouldProcess('Spooler', 'Stop, clear queue, start')) {
                        Stop-Service -Name Spooler -Force -ErrorAction Stop
                        $spool = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
                        $n = @(Get-ChildItem -LiteralPath $spool -File -ErrorAction SilentlyContinue).Count
                        Get-ChildItem -LiteralPath $spool -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue -WhatIf:$false
                        Set-Service -Name Spooler -StartupType Automatic
                        Start-Service -Name Spooler -ErrorAction Stop
                        $printers = @(Get-Printer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
                        Add-Result $a 'Success' "Cleared $n spool file(s); spooler running; printers: $($printers -join ', ')"
                    }
                    else { Add-Result $a 'WhatIf' 'Would restart the spooler and clear stuck jobs' }
                }
                'ResetWindowsUpdate' {
                    if ($PSCmdlet.ShouldProcess('Windows Update components', 'Reset')) {
                        $svcs = 'wuauserv', 'bits', 'cryptsvc'
                        Stop-Service -Name $svcs -Force -ErrorAction SilentlyContinue
                        $stamp = Get-Date -Format 'yyyyMMddHHmmss'
                        $renamed = @()
                        foreach ($p in "$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2") {
                            if (Test-Path $p) {
                                try { Rename-Item -LiteralPath $p -NewName ("{0}.bak-{1}" -f (Split-Path $p -Leaf), $stamp) -ErrorAction Stop -WhatIf:$false; $renamed += (Split-Path $p -Leaf) }
                                catch { Write-Warning "Could not rename ${p}: $($_.Exception.Message)" }
                            }
                        }
                        Start-Service -Name $svcs -ErrorAction SilentlyContinue
                        Add-Result $a 'Success' "Renamed: $($renamed -join ', '); services restarted. Check for updates again."
                    }
                    else { Add-Result $a 'WhatIf' 'Would reset Windows Update components' }
                }
                'GpUpdate' {
                    if ($PSCmdlet.ShouldProcess('Group Policy', 'gpupdate /force')) {
                        $out = (& gpupdate.exe /force /wait:120) 2>&1 | Out-String
                        Write-Host $out.Trim()
                        $rsop = (& gpresult.exe /r) 2>&1 | Out-String
                        Write-Host ($rsop.Trim() -split "`r?`n" | Select-Object -First 60 | Out-String)
                        Add-Result $a 'Success' 'Policy refreshed; review the applied/filtered GPO lists above (gpresult /h report.html for detail)'
                    }
                    else { Add-Result $a 'WhatIf' 'Would run gpupdate /force' }
                }
                'RepairSecureChannel' {
                    if (-not (Get-CimInstance Win32_ComputerSystem).PartOfDomain) { Add-Result $a 'Skipped' 'Device is not domain-joined'; break }
                    $healthy = Test-ComputerSecureChannel -ErrorAction SilentlyContinue
                    if ($healthy) { Add-Result $a 'Success' 'Secure channel is healthy - no repair needed'; break }
                    if ($PSCmdlet.ShouldProcess('Computer secure channel', 'Repair')) {
                        if (-not $Credential) { $Credential = Get-Credential -Message 'Domain account allowed to reset this computer account (e.g. CONTOSO\adm.tech)' }
                        $ok = Test-ComputerSecureChannel -Repair -Credential $Credential -ErrorAction Stop
                        $res = 'Failed'; if ($ok) { $res = 'Success' }
                        Add-Result $a $res "Repair returned $ok. Have the user sign out and back in."
                    }
                    else { Add-Result $a 'WhatIf' 'Secure channel broken - would repair it' }
                }
                'SyncTime' {
                    if ($PSCmdlet.ShouldProcess('w32time', 'Enable, start and resync')) {
                        Set-Service -Name w32time -StartupType Automatic
                        Start-Service -Name w32time -ErrorAction Stop
                        if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { $null = & w32tm.exe /config /syncfromflags:domhier /update }
                        $sync = (& w32tm.exe /resync /force) 2>&1 | Out-String
                        $src = (& w32tm.exe /query /source) 2>&1 | Out-String
                        Add-Result $a 'Success' ("Source: {0}; {1}" -f $src.Trim(), ($sync.Trim() -replace '\s+', ' '))
                    }
                    else { Add-Result $a 'WhatIf' 'Would resync time with the domain hierarchy' }
                }
                'ResetNetworkStack' {
                    if ($PSCmdlet.ShouldProcess('Winsock and TCP/IP stack', 'Reset (reboot required)')) {
                        $null = & netsh.exe winsock reset
                        $null = & netsh.exe int ip reset
                        Clear-DnsClientCache
                        Add-Result $a 'Success' 'Winsock and TCP/IP reset - REBOOT REQUIRED. Static IP settings may need re-entry.'
                    }
                    else { Add-Result $a 'WhatIf' 'Would reset Winsock and TCP/IP (reboot required)' }
                }
            }
        }
        catch { Add-Result $a 'Failed' $_.Exception.Message }
    }
}
finally {
    if (-not $WhatIfPreference) { Stop-Transcript | Out-Null }
}

Write-Host ''
$results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$ticket = ''
if ($TicketNumber) { $ticket = "[$TicketNumber] " }
Write-Host 'Ticket note (paste into work notes):' -ForegroundColor Cyan
Write-Host ("{0}Ran Invoke-EndpointRemediation.ps1 on {1} at {2}: {3}" -f $ticket, $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm'),
    (($results | ForEach-Object { "$($_.Action)=$($_.Result)" }) -join ', '))
if (-not $WhatIfPreference) { Write-Host "Transcript: $transcript" -ForegroundColor DarkGray }
