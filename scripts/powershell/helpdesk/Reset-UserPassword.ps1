#Requires -Version 5.1
<#
.SYNOPSIS
    Tier 1 password reset with mandatory identity verification and an audit trail.

.DESCRIPTION
    Implements KB0002. Run as hd.tier1 (delegated Reset Password + lockoutTime + pwdLastSet on OU=Users).
      - Refuses privileged accounts (Admins OU, Domain Admins, help desk groups): those go to
        Contoso Identity & Access, per the least-privilege control BC-01.
      - Requires -VerificationMethod so every reset records HOW identity was verified.
      - Generates a random 14-character temporary password, forces change at next logon, unlocks the account.
      - Shows the temporary password once; it is never written to the log or the ticket.

.EXAMPLE
    .\Reset-UserPassword.ps1 -SamAccountName emma.carter -TicketNumber INC0010001 -VerificationMethod 'Manager callback'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SamAccountName,
    [Parameter(Mandatory)][ValidatePattern('^(INC|RITM)\d{7}$')][string]$TicketNumber,
    [Parameter(Mandatory)]
    [ValidateSet('Manager callback', 'Callback to number on file', 'In person with badge', 'Verified MFA prompt')]
    [string]$VerificationMethod,
    [switch]$NoUnlock
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabModule -Name ActiveDirectory
$cfg = Get-LabConfig

$user = Get-ADUser -Identity $SamAccountName -Properties MemberOf, adminCount, DisplayName, LockedOut, Enabled

# --- Guardrails -------------------------------------------------------------------------------------
$protectedGroups = @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators',
                     $cfg.Groups.HelpDeskTier1, $cfg.Groups.HelpDeskTier2)
$groupNames = @($user.MemberOf | ForEach-Object { (Get-ADGroup -Identity $_).Name })
$isPrivileged = ($user.adminCount -eq 1) -or ($user.DistinguishedName -like "*$($cfg.OU.Admins)") -or
                (@($groupNames | Where-Object { $protectedGroups -contains $_ }).Count -gt 0)
if ($isPrivileged) {
    Write-LabAudit -Action 'PasswordReset' -Target $SamAccountName -TicketNumber $TicketNumber -Result Failed -Details 'Refused: privileged account'
    throw "$SamAccountName is a privileged account. Reassign $TicketNumber to Contoso Identity & Access (Tier 1 may not reset it)."
}
if (-not $user.Enabled) {
    throw "$SamAccountName is disabled. Do not re-enable from Tier 1 - check for an offboarding record and escalate to Identity & Access."
}

# --- Reset ------------------------------------------------------------------------------------------
$temp = New-LabPassword -Length 14
if ($PSCmdlet.ShouldProcess($SamAccountName, 'Reset password, require change at next logon')) {
    Set-ADAccountPassword -Identity $SamAccountName -Reset -NewPassword (ConvertTo-LabSecureString $temp)
    Set-ADUser -Identity $SamAccountName -ChangePasswordAtLogon $true
    $unlocked = 'not locked'
    if ($user.LockedOut -and -not $NoUnlock) { Unlock-ADAccount -Identity $SamAccountName; $unlocked = 'unlocked' }

    Write-LabAudit -Action 'PasswordReset' -Target $SamAccountName -TicketNumber $TicketNumber `
        -Details "Verification: $VerificationMethod; account $unlocked; must change at next logon"

    Write-Host ''
    Write-Host "  Temporary password for $SamAccountName (read it to the verified caller; do not email or paste in chat):" -ForegroundColor Yellow
    Write-Host "      $temp" -ForegroundColor Yellow
    Write-Host ''
    Write-Host @"
Ticket work note:
[$TicketNumber] Password reset - $($user.DisplayName) ($SamAccountName)
Issue:   User unable to sign in / forgot password.
Steps:   Identity verified via: $VerificationMethod. Reset password to a temporary value (not recorded),
         set "must change at next logon", account $unlocked.
Result:  User signed in and set a new password while on the call.
Next:    Remind user to update the password on phone mail apps and saved credentials to avoid lockouts (KB0001).
"@
}
