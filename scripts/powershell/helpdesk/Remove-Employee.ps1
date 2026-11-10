#Requires -Version 5.1
<#
.SYNOPSIS
    Employee offboarding: disables and de-provisions an AD account with an audit evidence file.

.DESCRIPTION
    Implements SOP-002 (control BC-05). Run on DC01 / RSAT as adm.tech or a delegated Identity & Access admin.
    Every step honors -WhatIf. Steps:
      1. Export evidence (account attributes + group memberships) to a CSV named after the ticket
      2. Disable the account
      3. Reset the password to a random value (kills password-based access, incl. cached network logons)
      4. Remove all group memberships except the primary group (Domain Users)
      5. Stamp the description: "DISABLED <date> per <ticket> by <operator>"
      6. Move the account to OU=Disabled
      7. Print the follow-up checklist (device recovery, mailbox/data handoff, MFA/session revocation)

.EXAMPLE
    .\Remove-Employee.ps1 -SamAccountName ava.turner -TicketNumber RITM0010002 -WhatIf
.EXAMPLE
    .\Remove-Employee.ps1 -SamAccountName ava.turner -TicketNumber RITM0010002
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SamAccountName,
    [Parameter(Mandatory)][ValidatePattern('^(RITM|REQ|INC)\d{7}$')][string]$TicketNumber,
    [string]$EvidencePath,
    [switch]$Force   # skip the single confirmation prompt
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabModule -Name ActiveDirectory
$cfg = Get-LabConfig
if (-not $EvidencePath) { $EvidencePath = Join-Path $cfg.EvidencePath 'Offboarding' }

$props = 'DisplayName', 'Department', 'Title', 'Manager', 'MemberOf', 'Description', 'Enabled', 'LastLogonDate',
         'PasswordLastSet', 'HomeDirectory', 'EmailAddress', 'DistinguishedName', 'whenCreated', 'adminCount'
$user = Get-ADUser -Identity $SamAccountName -Properties $props

$privileged = 'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators', $cfg.Groups.HelpDeskTier1, $cfg.Groups.HelpDeskTier2
$groupNames = @($user.MemberOf | ForEach-Object { (Get-ADGroup -Identity $_).Name })
$privHits = @($groupNames | Where-Object { $privileged -contains $_ })
if ($privHits.Count -gt 0 -or $user.adminCount -eq 1) {
    Write-Warning "$SamAccountName holds privileged access ($($privHits -join ', ')). Notify Contoso Identity & Access and rotate any shared secrets this person knew."
}

if (-not $WhatIfPreference -and -not $Force) {
    $question = "Offboard $($user.DisplayName) ($SamAccountName) per $TicketNumber? The account is disabled and removed from $($groupNames.Count) group(s)."
    if (-not $PSCmdlet.ShouldContinue($question, 'Confirm offboarding')) { Write-Warning 'Cancelled - no changes made.'; return }
}

$operator = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
$today = Get-Date -Format 'yyyy-MM-dd'
$steps = New-Object System.Collections.Generic.List[object]
function Add-Step { param([string]$Step, [string]$Result) $steps.Add([pscustomobject]@{ Step = $Step; Result = $Result }) }

# 1. Evidence -----------------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($EvidencePath, "Export evidence for $SamAccountName")) {
    if (-not (Test-Path $EvidencePath)) { New-Item -ItemType Directory -Path $EvidencePath -Force | Out-Null }
    $file = Join-Path $EvidencePath ("{0}-{1}-{2}.csv" -f $TicketNumber, $SamAccountName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [pscustomobject]@{
        Ticket            = $TicketNumber
        SamAccountName    = $SamAccountName
        DisplayName       = $user.DisplayName
        Department        = $user.Department
        Title             = $user.Title
        Manager           = $user.Manager
        DistinguishedName = $user.DistinguishedName
        WasEnabled        = $user.Enabled
        LastLogonDate     = $user.LastLogonDate
        PasswordLastSet   = $user.PasswordLastSet
        HomeDirectory     = $user.HomeDirectory
        Groups            = ($groupNames -join '; ')
        OffboardedBy      = $operator
        OffboardedAt      = (Get-Date).ToString('s')
    } | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
    Add-Step 'Evidence exported' $file
}

# 2. Disable --------------------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($SamAccountName, 'Disable account')) {
    Disable-ADAccount -Identity $SamAccountName
    Add-Step 'Account disabled' 'Done'
}

# 3. Scramble password ------------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($SamAccountName, 'Reset password to a random value')) {
    Set-ADAccountPassword -Identity $SamAccountName -Reset -NewPassword (ConvertTo-LabSecureString (New-LabPassword -Length 32))
    Add-Step 'Password scrambled' 'Done (value not recorded)'
}

# 4. Remove groups -----------------------------------------------------------------------------
foreach ($dn in @($user.MemberOf)) {
    $g = Get-ADGroup -Identity $dn
    if ($PSCmdlet.ShouldProcess($g.Name, "Remove $SamAccountName")) {
        Remove-ADGroupMember -Identity $g -Members $SamAccountName -Confirm:$false
        Add-Step "Removed from $($g.Name)" 'Done'
    }
}

# 5. Description -----------------------------------------------------------------------------------
$newDescription = "DISABLED $today per $TicketNumber by $operator"
if ($user.Description) { $newDescription += " | was: $($user.Description)" }
if ($newDescription.Length -gt 1024) { $newDescription = $newDescription.Substring(0, 1024) }
if ($PSCmdlet.ShouldProcess($SamAccountName, "Set description '$newDescription'")) {
    Set-ADUser -Identity $SamAccountName -Description $newDescription
    Add-Step 'Description stamped' $newDescription
}

# 6. Move to Disabled OU ---------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($SamAccountName, "Move to $($cfg.OU.Disabled)")) {
    Move-ADObject -Identity $user.DistinguishedName -TargetPath $cfg.OU.Disabled
    Add-Step 'Moved to OU=Disabled' $cfg.OU.Disabled
}

$result = 'Success'
if ($WhatIfPreference) { $result = 'WhatIf' }
Write-LabAudit -Action 'Offboarding' -Target $SamAccountName -TicketNumber $TicketNumber -Result $result `
    -Details "Removed groups: $($groupNames -join '|')"

# 7. Output ---------------------------------------------------------------------------------------
Write-LabStep "Offboarding summary - $SamAccountName ($TicketNumber)"
$steps | Format-Table -AutoSize -Wrap
Write-Host @"
Ticket work note:
[$TicketNumber] Offboarding - $($user.DisplayName) ($SamAccountName)
Steps:   Evidence exported; account disabled; password scrambled; removed from $($groupNames.Count) group(s)
         ($($groupNames -join ', ')); moved to OU=Disabled; description stamped.
Next:    [ ] Recover laptop + accessories (update CMDB status)   [ ] Manager confirms data/home-folder handoff
         [ ] Revoke MFA methods and cloud sessions               [ ] Remove/wipe mobile device in MDM (SOP-006 if not returned)
         [ ] Delete account after retention period (90 days) per records policy
"@
