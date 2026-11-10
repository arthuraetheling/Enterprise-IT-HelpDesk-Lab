#Requires -Version 5.1
<#
.SYNOPSIS
    Quarterly access review (control BC-06): finds risky accounts and builds a manager attestation sheet.

.DESCRIPTION
    Implements SOP-008. Read-only. Produces, in -OutputPath:
      access-review-findings-<date>.csv   one row per finding (category, severity, account, recommendation)
      access-review-attestation-<date>.csv one row per user for manager sign-off (Decision/Comments blank)
      access-review-<date>.html           summary report for the evidence package

    Finding categories
      Inactive               enabled, no logon in -InactiveDays (or never logged on and older than that)
      PasswordNeverExpires   enabled account exempt from password expiry (service accounts need an exception)
      ExpiredButEnabled      account expiration date in the past but still enabled
      DisabledWithGroups     disabled account that still holds group memberships
      PrivilegedMember       members of privileged/admin groups (for explicit re-attestation)
      PasswordNotRequired    PASSWD_NOTREQD flag set
      NoManager              enabled standard user without a manager (orphaned ownership)

    Note: LastLogonDate is lastLogonTimestamp, which replicates with a 9-14 day lag - fine for a 90-day review.

.EXAMPLE
    .\Get-ADAccessReview.ps1 -InactiveDays 90
#>
[CmdletBinding()]
param(
    [int]$InactiveDays = 90,
    [string]$OutputPath,
    [string[]]$PrivilegedGroups = @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators',
        'Account Operators', 'Backup Operators', 'Server Operators', 'Group Policy Creator Owners',
        'GG-HelpDesk-Tier1', 'GG-HelpDesk-Tier2')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabModule -Name ActiveDirectory
$cfg = Get-LabConfig
if (-not $OutputPath) { $OutputPath = Join-Path $cfg.EvidencePath 'AccessReview' }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$now    = Get-Date
$cutoff = $now.AddDays(-$InactiveDays)
$date   = $now.ToString('yyyy-MM-dd')
$props  = 'DisplayName', 'Enabled', 'LastLogonDate', 'whenCreated', 'PasswordNeverExpires', 'PasswordNotRequired',
          'AccountExpirationDate', 'MemberOf', 'Manager', 'Department', 'Title', 'DistinguishedName', 'Description'

Write-LabStep "Collecting accounts from $($cfg.OU.Root)"
$users = @(Get-ADUser -Filter * -SearchBase $cfg.OU.Root -Properties $props)
$groupNameCache = @{}
function Get-GroupName { param([string]$Dn)
    if (-not $groupNameCache.ContainsKey($Dn)) { $groupNameCache[$Dn] = (Get-ADGroup -Identity $Dn).Name }
    $groupNameCache[$Dn]
}

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param($User, [string]$Category, [ValidateSet('High', 'Medium', 'Low', 'Info')][string]$Severity, [string]$Detail, [string]$Recommendation)
    $findings.Add([pscustomobject]@{
        Category       = $Category
        Severity       = $Severity
        SamAccountName = $User.SamAccountName
        DisplayName    = $User.DisplayName
        Department     = $User.Department
        Detail         = $Detail
        Recommendation = $Recommendation
    })
}

foreach ($u in $users) {
    $isService = ($u.DistinguishedName -like "*$($cfg.OU.ServiceAccounts)")
    $isAdmin   = ($u.DistinguishedName -like "*$($cfg.OU.Admins)")
    $groups    = @($u.MemberOf | ForEach-Object { Get-GroupName $_ })

    if ($u.Enabled) {
        if (($u.LastLogonDate -and $u.LastLogonDate -lt $cutoff) -or (-not $u.LastLogonDate -and $u.whenCreated -lt $cutoff)) {
            $last = 'never'
            if ($u.LastLogonDate) { $last = $u.LastLogonDate.ToString('yyyy-MM-dd') }
            Add-Finding $u 'Inactive' 'Medium' "Last logon: $last (threshold $InactiveDays days)" 'Confirm with manager; disable if no longer required'
        }
        if ($u.PasswordNeverExpires) {
            if ($isService) {
                Add-Finding $u 'PasswordNeverExpires' 'Low' "Service account. Description: $($u.Description)" 'Verify documented exception is current; prefer a gMSA'
            }
            else {
                Add-Finding $u 'PasswordNeverExpires' 'High' 'Interactive account exempt from password expiry' 'Clear PasswordNeverExpires'
            }
        }
        if ($u.AccountExpirationDate -and $u.AccountExpirationDate -lt $now) {
            Add-Finding $u 'ExpiredButEnabled' 'High' "Expired $($u.AccountExpirationDate.ToString('yyyy-MM-dd')), still enabled, groups: $($groups -join ', ')" 'Run Remove-Employee.ps1 under an offboarding ticket'
        }
        if ($u.PasswordNotRequired) {
            Add-Finding $u 'PasswordNotRequired' 'High' 'PASSWD_NOTREQD flag set' 'Set-ADUser -PasswordNotRequired $false'
        }
        if (-not $u.Manager -and -not $isService -and -not $isAdmin) {
            Add-Finding $u 'NoManager' 'Low' 'No manager recorded' 'Ask HR to supply the manager; required for attestation'
        }
    }
    elseif ($groups.Count -gt 0) {
        Add-Finding $u 'DisabledWithGroups' 'Medium' "Disabled but member of: $($groups -join ', ')" 'Remove memberships (Remove-Employee.ps1 does this)'
    }
}

Write-LabStep 'Expanding privileged group membership'
foreach ($pg in $PrivilegedGroups) {
    $grp = Get-ADGroup -Filter "Name -eq '$pg'" -ErrorAction SilentlyContinue
    if (-not $grp) { continue }
    foreach ($m in @(Get-ADGroupMember -Identity $grp -Recursive | Where-Object objectClass -eq 'user')) {
        $mu = Get-ADUser -Identity $m.distinguishedName -Properties DisplayName, Department
        Add-Finding $mu 'PrivilegedMember' 'Info' "Member of $pg" 'Re-attest need for privileged access (IT manager)'
    }
}

# --- Attestation sheet ---------------------------------------------------------------------------
$attestation = foreach ($u in ($users | Where-Object { $_.Enabled -and $_.DistinguishedName -like "*$($cfg.OU.Users)" })) {
    $mgrName = ''
    if ($u.Manager) { $mgrName = (Get-ADUser -Identity $u.Manager -Properties DisplayName).DisplayName }
    [pscustomobject]@{
        Manager        = $mgrName
        SamAccountName = $u.SamAccountName
        DisplayName    = $u.DisplayName
        Department     = $u.Department
        Title          = $u.Title
        Groups         = (@($u.MemberOf | ForEach-Object { Get-GroupName $_ }) -join '; ')
        Decision       = ''   # Keep / Modify / Remove - filled in by the manager
        Comments       = ''
    }
}

$findingsCsv    = Join-Path $OutputPath "access-review-findings-$date.csv"
$attestationCsv = Join-Path $OutputPath "access-review-attestation-$date.csv"
$htmlPath       = Join-Path $OutputPath "access-review-$date.html"
$findings | Sort-Object Severity, Category | Export-Csv -Path $findingsCsv -NoTypeInformation -Encoding UTF8
$attestation | Sort-Object Manager, DisplayName | Export-Csv -Path $attestationCsv -NoTypeInformation -Encoding UTF8

# --- HTML summary ---------------------------------------------------------------------------------
$enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
$summaryRows = ($findings | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
    "<tr><td>$(& $enc $_.Name)</td><td>$($_.Count)</td></tr>" }) -join "`n"
$detailRows = ($findings | Sort-Object @{ e = { @{ High = 0; Medium = 1; Low = 2; Info = 3 }[$_.Severity] } }, Category | ForEach-Object {
    "<tr class='$($_.Severity.ToLower())'><td>$(& $enc $_.Severity)</td><td>$(& $enc $_.Category)</td><td>$(& $enc $_.SamAccountName)</td><td>$(& $enc $_.Detail)</td><td>$(& $enc $_.Recommendation)</td></tr>" }) -join "`n"
$html = @"
<!doctype html><html><head><meta charset="utf-8"><title>Access Review $date</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1f2933}h1{font-size:20px}h2{font-size:16px;margin-top:24px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #d9dee3;padding:6px 8px;text-align:left;vertical-align:top}
th{background:#f3f5f7}tr.high td:first-child{color:#b42318;font-weight:600}tr.medium td:first-child{color:#b54708;font-weight:600}
.meta{color:#52606d;font-size:13px}
</style></head><body>
<h1>$(& $enc $cfg.Company) - Quarterly Access Review</h1>
<p class="meta">Generated $($now.ToString('yyyy-MM-dd HH:mm')) by $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME &middot; scope $(& $enc $cfg.OU.Root) &middot; $($users.Count) accounts &middot; inactivity threshold $InactiveDays days</p>
<h2>Findings by category</h2><table><tr><th>Category</th><th>Count</th></tr>$summaryRows</table>
<h2>Findings</h2><table><tr><th>Severity</th><th>Category</th><th>Account</th><th>Detail</th><th>Recommendation</th></tr>$detailRows</table>
<h2>Sign-off</h2><p>Reviewer: ____________________ Date: __________ &nbsp; IT Manager approval: ____________________</p>
</body></html>
"@
[System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($false)))

Write-LabStep 'Results'
$findings | Group-Object Severity | Select-Object @{ n = 'Severity'; e = { $_.Name } }, Count | Format-Table -AutoSize
$findings | Where-Object Severity -in 'High', 'Medium' | Format-Table Severity, Category, SamAccountName, Detail -AutoSize -Wrap
Write-LabOk "Findings:    $findingsCsv"
Write-LabOk "Attestation: $attestationCsv"
Write-LabOk "Report:      $htmlPath"
