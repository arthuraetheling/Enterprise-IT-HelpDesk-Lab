#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses an AD account lockout: status per DC, bad-password counters and the lockout SOURCE computer.

.DESCRIPTION
    Used by Tier 1 (KB0001). Run on DC01 or an RSAT workstation as hd.tier1 (member of Event Log Readers).
      - Account state: enabled, locked, expired, password expired, password last set
      - badPwdCount / LastBadPasswordAttempt queried on EVERY domain controller (these attributes are not
        replicated, so a single DC can hide where the bad attempts happened)
      - Security event 4740 (account locked out) on the PDC emulator -> "Caller Computer Name"
      - Optional event 4771 (Kerberos pre-auth failed, status 0x18) -> client IP address
      - -Unlock unlocks the account after you have identified and removed the source

.EXAMPLE
    .\Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter
.EXAMPLE
    .\Get-AccountLockoutInfo.ps1 -SamAccountName emma.carter -Unlock -TicketNumber INC0010001
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SamAccountName,
    [switch]$Unlock,
    [int]$Hours = 24,
    [switch]$IncludeKerberosFailures,
    [string]$TicketNumber = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabModule -Name ActiveDirectory

$props = 'LockedOut', 'lockoutTime', 'badPwdCount', 'LastBadPasswordAttempt', 'PasswordLastSet', 'PasswordExpired',
         'Enabled', 'AccountExpirationDate', 'msDS-UserPasswordExpiryTimeComputed', 'DisplayName', 'Department', 'LastLogonDate'
$user = Get-ADUser -Identity $SamAccountName -Properties $props
$pdc  = (Get-ADDomain).PDCEmulator
$since = (Get-Date).AddHours(-$Hours)

function Get-EventField {
    param($EventRecord, [string]$Name)
    $xml = [xml]$EventRecord.ToXml()
    ($xml.Event.EventData.Data | Where-Object { $_.Name -eq $Name } | Select-Object -First 1).'#text'
}

function Get-SecurityEvent {
    param([string]$Computer, [int]$Id)
    $filter = @{ LogName = 'Security'; Id = $Id; StartTime = $since }
    $isLocal = ($Computer.Split('.')[0] -ieq $env:COMPUTERNAME)
    try {
        if ($isLocal) { Get-WinEvent -FilterHashtable $filter -ErrorAction Stop }
        else { Get-WinEvent -ComputerName $Computer -FilterHashtable $filter -ErrorAction Stop }
    }
    catch {
        if ($_.Exception.Message -match 'No events were found') { return @() }
        Write-Warning "Cannot read Security log on ${Computer}: $($_.Exception.Message) (requires Event Log Readers + remote event log firewall rule)"
        return @()
    }
}

# --- Account state --------------------------------------------------------------------------------
$expiry = $null
$raw = $user.'msDS-UserPasswordExpiryTimeComputed'
if ($raw -and $raw -ne 0 -and $raw -ne [long]::MaxValue) { $expiry = [datetime]::FromFileTime($raw) }

$lockoutTime = $null
if ($user.lockoutTime -and $user.lockoutTime -ne 0) { $lockoutTime = [datetime]::FromFileTime($user.lockoutTime) }

Write-LabStep "Account: $($user.DisplayName) ($SamAccountName) - $($user.Department)"
[pscustomobject]@{
    Enabled                = $user.Enabled
    LockedOut              = $user.LockedOut
    LockoutTime            = $lockoutTime
    AccountExpires         = $user.AccountExpirationDate
    PasswordExpired        = $user.PasswordExpired
    PasswordLastSet        = $user.PasswordLastSet
    PasswordExpires        = $expiry
    LastLogonDate          = $user.LastLogonDate
} | Format-List

# --- Per-DC bad password counters ---------------------------------------------------------------
Write-LabStep 'Bad password counters per domain controller (not replicated)'
$perDc = foreach ($dc in (Get-ADDomainController -Filter *)) {
    try {
        $u = Get-ADUser -Identity $SamAccountName -Server $dc.HostName -Properties badPwdCount, LastBadPasswordAttempt, lockoutTime
        [pscustomobject]@{
            DomainController       = $dc.HostName
            Site                   = $dc.Site
            IsPDC                  = ($dc.HostName -eq $pdc)
            BadPwdCount            = $u.badPwdCount
            LastBadPasswordAttempt = $u.LastBadPasswordAttempt
        }
    }
    catch { [pscustomobject]@{ DomainController = $dc.HostName; Site = $dc.Site; IsPDC = ($dc.HostName -eq $pdc); BadPwdCount = 'unreachable'; LastBadPasswordAttempt = $null } }
}
$perDc | Format-Table -AutoSize

# --- Lockout source (4740 on the PDC emulator) -----------------------------------------------------
Write-LabStep "Lockout events (4740) on PDC emulator $pdc - last $Hours h"
$lockouts = @(Get-SecurityEvent -Computer $pdc -Id 4740 | Where-Object { (Get-EventField $_ 'TargetUserName') -ieq $SamAccountName } |
    ForEach-Object {
        [pscustomobject]@{
            Time           = $_.TimeCreated
            User           = Get-EventField $_ 'TargetUserName'
            CallerComputer = Get-EventField $_ 'TargetDomainName'   # 4740 stores the caller computer in this field
            ReportedBy     = $_.MachineName
        }
    })
if ($lockouts.Count -gt 0) { $lockouts | Format-Table -AutoSize }
else { Write-LabSkip 'No 4740 events for this user in the window (is auditing enabled? see 03-Build-ADStructure.ps1)' }

if ($IncludeKerberosFailures) {
    Write-LabStep 'Kerberos pre-authentication failures (4771, status 0x18 = bad password)'
    $krb = @(Get-SecurityEvent -Computer $pdc -Id 4771 | Where-Object { (Get-EventField $_ 'TargetUserName') -ieq $SamAccountName } |
        ForEach-Object {
            [pscustomobject]@{
                Time      = $_.TimeCreated
                Status    = Get-EventField $_ 'Status'
                ClientIP  = (Get-EventField $_ 'IpAddress') -replace '^::ffff:', ''
                ClientPort = Get-EventField $_ 'IpPort'
            }
        })
    if ($krb.Count -gt 0) { $krb | Format-Table -AutoSize } else { Write-LabSkip 'No 4771 events found' }
}

# --- Guidance ---------------------------------------------------------------------------------------
$sources = @($lockouts | Where-Object { $_.CallerComputer } | Group-Object CallerComputer | Sort-Object Count -Descending)
Write-LabStep 'Assessment'
if ($sources.Count -gt 0) {
    $top = $sources[0]
    Write-Host ("  Most likely source: {0} ({1} lockout event(s)). On that device check, in order:" -f $top.Name, $top.Count) -ForegroundColor Yellow
    Write-Host '   1. Credential Manager (control keymgr.dll) - saved Windows credentials for file shares/servers'
    Write-Host '   2. Mapped drives / scheduled tasks / services running as this user with an old password'
    Write-Host '   3. Mobile mail app or second laptop still using the previous password'
    Write-Host '  If the caller is a DC, server or blank, use -IncludeKerberosFailures to get the client IP.'
}
elseif ($user.LockedOut) {
    Write-Host '  Account is locked but no source was found in the window - increase -Hours or check auditing.' -ForegroundColor Yellow
}
else {
    Write-Host '  Account is not locked. If the user still cannot sign in, check password expiry, account expiry and MFA.' -ForegroundColor Green
}

# --- Unlock -----------------------------------------------------------------------------------------
if ($Unlock) {
    if (-not $user.LockedOut) { Write-LabSkip 'Account is not locked - nothing to unlock' }
    elseif ($PSCmdlet.ShouldProcess($SamAccountName, 'Unlock-ADAccount')) {
        Unlock-ADAccount -Identity $SamAccountName
        Write-LabOk "Unlocked $SamAccountName"
        $src = 'unknown'
        if ($sources.Count -gt 0) { $src = $sources[0].Name }
        Write-LabAudit -Action 'Unlock' -Target $SamAccountName -TicketNumber $TicketNumber -Details "Lockout source: $src"
        Write-Host ''
        Write-Host "Ticket work note: Verified identity; account locked by bad attempts from $src. Removed stale credential on source, unlocked account, user confirmed sign-in. See KB0001."
    }
}
