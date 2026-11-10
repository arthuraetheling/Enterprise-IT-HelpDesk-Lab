#Requires -Version 5.1
<#
.SYNOPSIS
    Injects (and reverts) realistic help desk faults into the lab for troubleshooting practice.

.DESCRIPTION
    Each scenario breaks one thing the way it breaks in real life, prints the simulated user complaint
    (not the root cause), and records what it changed so -Revert can undo it. Work the ticket using the
    KB articles and docs/06-lab-scenarios.md before you look at the answer.

    SAFETY: refuses to run unless the machine is joined to the lab domain in Lab.Config.psd1
    (corp.contoso.internal) and the session is elevated. DC scenarios run only on a domain controller,
    client scenarios only on a member workstation.

.EXAMPLE
    .\Invoke-LabFault.ps1 -List
.EXAMPLE
    .\Invoke-LabFault.ps1 -Scenario DnsMisconfig            # on LT-WIN-001
    .\Invoke-LabFault.ps1 -Scenario DnsMisconfig -Revert
.EXAMPLE
    .\Invoke-LabFault.ps1 -Scenario ShareAccessRemoved -UserName emma.carter   # on DC01
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run', Position = 0)]
    [ValidateSet('AccountLockout', 'DnsMisconfig', 'DhcpScopeDown', 'DhcpServiceDown', 'ShareAccessRemoved', 'WrongOU',
                 'BrokenTrust', 'ClockSkew', 'SpoolerStuck', 'DiskFull', 'BitLockerRecovery')]
    [string]$Scenario,
    [Parameter(ParameterSetName = 'Run')][switch]$Revert,
    [Parameter(ParameterSetName = 'Run')][string]$UserName = 'emma.carter',
    [Parameter(ParameterSetName = 'Run')][string]$ComputerName = 'LT-WIN-001',
    [Parameter(ParameterSetName = 'Run')][ValidateRange(1, 20)][int]$Attempts = 6,
    [Parameter(Mandatory, ParameterSetName = 'List')][switch]$List
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
$cfg = Get-LabConfig

$catalog = [ordered]@{
    AccountLockout     = @{ RunOn = 'Client'; Kb = 'KB0001'; Ticket = "Emma Carter (Finance) calls: 'It says my account is locked. This is the third time this week!'" }
    DnsMisconfig       = @{ RunOn = 'Client'; Kb = 'KB0004'; Ticket = "Emma: 'The internet works, but the S: drive and every internal site are gone.'" }
    DhcpScopeDown      = @{ RunOn = 'DC';     Kb = 'KB0005'; Ticket = "Several users after restarting: 'My laptop says No Internet - limited connectivity.'" }
    DhcpServiceDown    = @{ RunOn = 'DC';     Kb = 'KB0005'; Ticket = "Zabbix (High): 'DHCP Server service is not running on DC01' - no user has called yet." }
    ShareAccessRemoved = @{ RunOn = 'DC';     Kb = 'KB0007'; Ticket = "Emma: 'I get Access Denied on the Finance folder. It worked yesterday.'" }
    WrongOU            = @{ RunOn = 'DC';     Kb = 'KB0008'; Ticket = "Security: 'LT-WIN-001 shows no logon banner and no screen-lock policy. Is it still compliant?'" }
    BrokenTrust        = @{ RunOn = 'DC';     Kb = 'KB0009'; Ticket = "Emma (after a restart): 'The trust relationship between this workstation and the primary domain failed.'" }
    ClockSkew          = @{ RunOn = 'Client'; Kb = 'KB0010'; Ticket = "Emma: 'Shared drives give strange errors and my clock looks wrong.'" }
    SpoolerStuck       = @{ RunOn = 'Client'; Kb = 'KB0012'; Ticket = "Daniel Kim (Operations): 'My print jobs are stuck in the queue and nothing comes out of FIN-PRN-01.'" }
    DiskFull           = @{ RunOn = 'Client'; Kb = 'KB0013'; Ticket = "Monitoring alert + Emma: 'My laptop is really slow and says it is running out of space.'" }
    BitLockerRecovery  = @{ RunOn = 'Client'; Kb = 'KB0011'; Ticket = "Emma: 'After the firmware update my laptop asks for a BitLocker recovery key.'" }
}

if ($List) {
    $catalog.Keys | ForEach-Object { [pscustomobject]@{ Scenario = $_; RunOn = $catalog[$_].RunOn; KB = $catalog[$_].Kb; SimulatedTicket = $catalog[$_].Ticket } } |
        Format-Table -AutoSize -Wrap
    return
}

# --- Safety gates ---------------------------------------------------------------------------------------
$cs = Get-CimInstance Win32_ComputerSystem
if (-not $cs.PartOfDomain -or $cs.Domain -ne $cfg.LabSafetyDomain) {
    throw "SAFETY STOP: this machine is not joined to the lab domain '$($cfg.LabSafetyDomain)' (found '$($cs.Domain)'). Fault injection only runs inside the lab."
}
Assert-LabElevated
$meta = $catalog[$Scenario]
$isDc = ($cs.DomainRole -ge 4)
if ($meta.RunOn -eq 'DC' -and -not $isDc) { throw "$Scenario runs on the domain controller ($($cfg.DomainController.Name)), not on $env:COMPUTERNAME." }
if ($meta.RunOn -eq 'Client' -and $cs.DomainRole -ne 1) { throw "$Scenario runs on a member workstation (e.g. LT-WIN-001), not on $env:COMPUTERNAME." }
if ($meta.RunOn -eq 'DC') { Assert-LabModule -Name ActiveDirectory }

# --- State helpers ---------------------------------------------------------------------------------------
function Get-FaultState {
    $s = @{}
    if (Test-Path $cfg.FaultStatePath) {
        $raw = Get-Content $cfg.FaultStatePath -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $s[$p.Name] = $p.Value }
    }
    return $s
}
function Save-FaultState {
    param([hashtable]$State)
    $dir = Split-Path -Parent $cfg.FaultStatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $o = New-Object psobject
    foreach ($k in $State.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $State[$k] }
    [System.IO.File]::WriteAllText($cfg.FaultStatePath, ($o | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}
$state = Get-FaultState

function Get-PrimaryInterfaceIndex {
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if (-not $r) { throw 'No default route found on this machine.' }
    return $r.ifIndex
}

function Show-Injected {
    Write-Host ''
    Write-Host "FAULT INJECTED: $Scenario" -ForegroundColor Red
    Write-Host "Simulated ticket: $($meta.Ticket)" -ForegroundColor Yellow
    Write-Host "Practice: log an incident (impact/urgency/priority), troubleshoot with the KBs, write work notes."
    Write-Host "Hint: start with $($meta.Kb). Answer key: docs/06-lab-scenarios.md"
    Write-Host "Revert: .\Invoke-LabFault.ps1 -Scenario $Scenario -Revert" -ForegroundColor DarkGray
}

$action = 'Inject'
if ($Revert) { $action = 'Revert' }
if (-not $PSCmdlet.ShouldProcess("$Scenario on $env:COMPUTERNAME", $action)) { return }

switch ($Scenario) {

    'AccountLockout' {
        if ($Revert) {
            Write-Host "Nothing to undo on the client. On $($cfg.DomainController.Name): .\Get-AccountLockoutInfo.ps1 -SamAccountName $UserName -Unlock"
            break
        }
        $target = "\\$($cfg.DomainController.Name)\IPC`$"
        for ($i = 1; $i -le $Attempts; $i++) {
            $null = & net.exe use $target "/user:$($cfg.NetBiosName)\$UserName" "Not-The-Password-$i!" 2>&1
        }
        $null = & net.exe use $target /delete /y 2>&1
        Show-Injected
    }

    'DnsMisconfig' {
        $idx = Get-PrimaryInterfaceIndex
        if ($Revert) {
            Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses
            Clear-DnsClientCache
            $state.Remove('DnsMisconfig')
            Write-LabOk "DNS servers reset to DHCP-provided values: $((Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4).ServerAddresses -join ', ')"
            break
        }
        $state['DnsMisconfig'] = @{ InterfaceIndex = $idx; Previous = @((Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4).ServerAddresses) }
        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @('1.1.1.1', '8.8.8.8')
        Clear-DnsClientCache
        Show-Injected
    }

    'DhcpScopeDown' {
        Assert-LabModule -Name DhcpServer
        if ($Revert) {
            Set-DhcpServerv4Scope -ScopeId $cfg.Dhcp.ScopeId -State Active
            Write-LabOk "Scope $($cfg.Dhcp.ScopeId) active. On clients: ipconfig /renew"
            break
        }
        Set-DhcpServerv4Scope -ScopeId $cfg.Dhcp.ScopeId -State InActive
        Show-Injected
        Write-Host "To reproduce on LT-WIN-001: ipconfig /release, then ipconfig /renew (or restart it)." -ForegroundColor DarkGray
    }

    'DhcpServiceDown' {
        if ($Revert) { Start-Service -Name DHCPServer; Write-LabOk 'DHCP Server service started'; break }
        Stop-Service -Name DHCPServer -Force
        Show-Injected
        Write-Host 'Watch Zabbix (Problems) and ServiceNow for the automated incident.' -ForegroundColor DarkGray
    }

    'ShareAccessRemoved' {
        if ($Revert) {
            $saved = $state['ShareAccessRemoved']
            if (-not $saved) { throw 'No saved state for ShareAccessRemoved.' }
            Add-ADGroupMember -Identity $saved.Group -Members $saved.User
            $state.Remove('ShareAccessRemoved')
            Write-LabOk "$($saved.User) re-added to $($saved.Group). The user must sign out/in (or klist purge) to get a new token."
            break
        }
        $u = Get-ADUser -Identity $UserName -Properties Department
        $group = "GG-$($u.Department)"
        Remove-ADGroupMember -Identity $group -Members $UserName -Confirm:$false
        $state['ShareAccessRemoved'] = @{ User = $UserName; Group = $group }
        Show-Injected
        Write-Host "Have $UserName sign out and back in on LT-WIN-001, then open S:\$($u.Department)." -ForegroundColor DarkGray
    }

    'WrongOU' {
        $comp = Get-ADComputer -Identity $ComputerName
        if ($Revert) {
            $target = $cfg.OU.Workstations
            if ($state['WrongOU']) { $target = $state['WrongOU'].OriginalParent }
            Move-ADObject -Identity $comp.DistinguishedName -TargetPath $target
            $state.Remove('WrongOU')
            Write-LabOk "$ComputerName moved back to $target. On the laptop: gpupdate /force"
            break
        }
        $parent = $comp.DistinguishedName -replace '^CN=[^,]+,', ''
        $state['WrongOU'] = @{ Computer = $ComputerName; OriginalParent = $parent }
        Move-ADObject -Identity $comp.DistinguishedName -TargetPath $cfg.OU.Staging
        Show-Injected
        Write-Host "On $ComputerName run gpupdate /force (or wait ~90 min) to see policies disappear." -ForegroundColor DarkGray
    }

    'BrokenTrust' {
        if ($Revert) {
            Write-Host "Repair runs on $($ComputerName): sign in with the LAPS local Administrator (Get-LapsADPassword -Identity $ComputerName -AsPlainText), then"
            Write-Host "  Test-ComputerSecureChannel -Repair -Credential $($cfg.NetBiosName)\$($cfg.Accounts.DomainAdmin)"
            Write-Host '  or: .\Invoke-EndpointRemediation.ps1 -Action RepairSecureChannel'
            break
        }
        $comp = Get-ADComputer -Identity $ComputerName
        Set-ADAccountPassword -Identity $comp -Reset -NewPassword (ConvertTo-LabSecureString (New-LabPassword -Length 32))
        Show-Injected
        Write-Host "Restart $ComputerName, then try to sign in as a domain user." -ForegroundColor DarkGray
    }

    'ClockSkew' {
        if ($Revert) {
            $mode = 'Manual'
            if ($state['ClockSkew']) { $mode = $state['ClockSkew'].StartMode }
            $map = @{ Auto = 'Automatic'; Manual = 'Manual'; Disabled = 'Manual' }
            Set-Service -Name w32time -StartupType $map[$mode]
            Start-Service -Name w32time
            $null = & w32tm.exe /resync /force
            $state.Remove('ClockSkew')
            Write-LabOk "w32time restored ($($map[$mode])) and resynced: $(Get-Date -Format 'HH:mm:ss')"
            break
        }
        $svc = Get-CimInstance Win32_Service -Filter "Name='w32time'"
        $state['ClockSkew'] = @{ StartMode = [string]$svc.StartMode }
        Stop-Service -Name w32time -Force
        Set-Service -Name w32time -StartupType Disabled
        Set-Date -Date (Get-Date).AddMinutes(10) | Out-Null
        $null = & klist.exe purge 2>&1
        Show-Injected
        Write-Host "If VMware Tools resets the clock, untick 'Synchronize guest time with host' (VM Settings > Options > VMware Tools)." -ForegroundColor DarkGray
    }

    'SpoolerStuck' {
        $printer = 'FIN-PRN-01'; $port = 'IP_10.10.10.250'
        if ($Revert) {
            Get-PrintJob -PrinterName $printer -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
            Remove-Printer -Name $printer -ErrorAction SilentlyContinue
            Restart-Service -Name Spooler -Force
            Remove-PrinterPort -Name $port -ErrorAction SilentlyContinue
            Write-LabOk "$printer and its port removed"
            break
        }
        if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) { Add-PrinterPort -Name $port -PrinterHostAddress '10.10.10.250' }
        $driver = $null
        foreach ($d in 'Generic / Text Only', 'Microsoft PCL6 Class Driver', 'Microsoft PS Class Driver', 'Microsoft Print To PDF') {
            if (Get-PrinterDriver -Name $d -ErrorAction SilentlyContinue) { $driver = $d; break }
            try { Add-PrinterDriver -Name $d -ErrorAction Stop; $driver = $d; break } catch { }
        }
        if (-not $driver) { throw 'No usable in-box printer driver found.' }
        if (-not (Get-Printer -Name $printer -ErrorAction SilentlyContinue)) {
            Add-Printer -Name $printer -DriverName $driver -PortName $port -Comment 'Finance floor printer (lab)' -Location 'HQ-3F'
        }
        1..3 | ForEach-Object { "Contoso lab test page $_ - $(Get-Date)" | Out-Printer -Name $printer }
        Show-Injected
    }

    'DiskFull' {
        $file = 'C:\Users\Public\Downloads\Q3-Finance-Archive.zip'
        if ($Revert) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; Write-LabOk "Removed $file"; break }
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $targetFree = [math]::Min($disk.Size * 0.10, 10GB) * 0.8      # below both critical thresholds (10% and 10 GB)
        $bytes = [int64]($disk.FreeSpace - $targetFree)
        if ($bytes -le 0) { Write-Warning 'C: is already below the critical threshold.'; break }
        $null = & fsutil.exe file createnew $file $bytes
        if ($LASTEXITCODE -ne 0) { throw "fsutil failed with exit code $LASTEXITCODE" }
        Show-Injected
    }

    'BitLockerRecovery' {
        if ($Revert) {
            # After recovery: restore the TPM protector and rotate the recovery password that was disclosed.
            $vol = Get-BitLockerVolume -MountPoint 'C:'
            if (-not ($vol.KeyProtector | Where-Object KeyProtectorType -eq 'Tpm')) { Add-BitLockerKeyProtector -MountPoint 'C:' -TpmProtector | Out-Null }
            $old = @($vol.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')
            Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector | Out-Null
            $new = @((Get-BitLockerVolume -MountPoint 'C:').KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' -and ($old.KeyProtectorId -notcontains $_.KeyProtectorId) })
            foreach ($n in $new) { Backup-BitLockerKeyProtector -MountPoint 'C:' -KeyProtectorId $n.KeyProtectorId | Out-Null }
            foreach ($o in $old) { Remove-BitLockerKeyProtector -MountPoint 'C:' -KeyProtectorId $o.KeyProtectorId | Out-Null }
            Write-LabOk "TPM protector present; recovery password rotated (new ID $($new[0].KeyProtectorId)) and escrowed to AD"
            break
        }
        $vol = Get-BitLockerVolume -MountPoint 'C:'
        if ([string]$vol.ProtectionStatus -ne 'On') { throw 'BitLocker is not on for C: - enable it first (docs/05-endpoint-management.md).' }
        $rp = @($vol.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')
        if ($rp.Count -eq 0) { throw 'C: has no recovery password protector - you would be locked out. Aborting.' }
        Write-Warning "Before continuing, confirm on DC01 that the key is escrowed: .\Get-BitLockerRecoveryKey.ps1 -ComputerName $env:COMPUTERNAME (Key ID $($rp[0].KeyProtectorId))"
        if (-not $PSCmdlet.ShouldContinue('Force BitLocker recovery at the next boot?', 'BitLockerRecovery')) { return }
        $null = & manage-bde.exe -forcerecovery C:
        Show-Injected
        Write-Host 'Restart the VM to see the recovery screen. After you are back in Windows, run this scenario with -Revert.' -ForegroundColor DarkGray
    }
}

Save-FaultState -State $state
