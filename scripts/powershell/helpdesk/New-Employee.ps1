#Requires -Version 5.1
<#
.SYNOPSIS
    New-hire onboarding: creates the AD account, department access, home drive and a ticket work note.

.DESCRIPTION
    Implements SOP-001. Run on DC01 (or an RSAT workstation) as an account allowed to create users
    (adm.tech or a delegated Identity & Access admin). Supports -WhatIf.

    For each new hire:
      1. Builds a unique first.last sAMAccountName (adds 2, 3, ... on collision)
      2. Creates the user in OU=<Department>,OU=Users,OU=Contoso with title, manager, start date note
      3. Generates a random temporary password (must change at first logon) - shown once, never logged
      4. Adds GG-<Department> + GG-AllStaff (AGDLP -> department share access)
      5. Creates \\DC01\Home$\<sam> and maps it as H:
      6. Writes an audit line (no secrets) and prints a ticket work note to paste into the RITM

.EXAMPLE
    .\New-Employee.ps1 -FirstName Ava -LastName Turner -Department Sales -Title "Account Executive" -Manager marcus.reed -TicketNumber RITM0010001

.EXAMPLE
    .\New-Employee.ps1 -CsvPath ..\..\..\data\new-hires-sample.csv -WhatIf
    # CSV columns: FirstName, LastName, Department, Title, Manager, TicketNumber [, StartDate, AccountExpires]
    # Rows without TicketNumber use -TicketNumber as the fallback.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$FirstName,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$LastName,
    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [ValidateSet('Finance', 'HR', 'IT', 'Sales', 'Operations')][string]$Department,
    [Parameter(ParameterSetName = 'Single')][string]$Title = 'Employee',
    [Parameter(ParameterSetName = 'Single')][string]$Manager,
    [Parameter(ParameterSetName = 'Single')][datetime]$StartDate = (Get-Date).Date,
    [Parameter(ParameterSetName = 'Single')][Nullable[datetime]]$AccountExpires,

    [Parameter(Mandatory, ParameterSetName = 'Csv')][string]$CsvPath,

    # Required for a single hire. With -CsvPath, each row may carry its own TicketNumber column;
    # this parameter is the fallback for rows that do not.
    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'Csv')]
    [ValidatePattern('^(RITM|REQ|INC)\d{7}$')][string]$TicketNumber
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabModule -Name ActiveDirectory
$cfg = Get-LabConfig

function Get-UniqueSam {
    param([string]$First, [string]$Last)
    $base = Get-LabSamAccountName -FirstName $First -LastName $Last
    $sam = $base; $n = 2
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        $suffix = [string]$n
        $trimmed = $base
        if (($base.Length + $suffix.Length) -gt 20) { $trimmed = $base.Substring(0, 20 - $suffix.Length) }
        $sam = $trimmed + $suffix; $n++
    }
    return $sam
}

function Invoke-Onboarding {
    param($Hire)

    $TicketNumber = $Hire.TicketNumber   # per-hire ticket (shadows the script parameter)
    if ($TicketNumber -notmatch '^(RITM|REQ|INC)\d{7}$') {
        throw "Missing or invalid TicketNumber '$TicketNumber' - every onboarding needs an approved request (e.g. RITM0010001)."
    }
    $sam   = Get-UniqueSam -First $Hire.FirstName -Last $Hire.LastName
    $name  = "$($Hire.FirstName) $($Hire.LastName)"
    $path  = Get-LabDepartmentOU -Department $Hire.Department
    $groups = @("GG-$($Hire.Department)", $cfg.Groups.AllStaff)

    $mgr = $null
    if ($Hire.Manager) {
        $mgr = Get-ADUser -Filter "SamAccountName -eq '$($Hire.Manager)'" -Properties DisplayName -ErrorAction SilentlyContinue
        if (-not $mgr) { throw "Manager '$($Hire.Manager)' not found - confirm the approver on the request before continuing." }
    }

    if (-not $PSCmdlet.ShouldProcess("$sam ($name, $($Hire.Department))", 'Create account, groups and home drive')) {
        Write-LabAudit -Action 'Onboarding' -Target $sam -TicketNumber $TicketNumber -Result WhatIf -Details "Planned groups: $($groups -join ', ')"
        return [pscustomobject]@{ SamAccountName = $sam; Status = 'WhatIf'; Groups = $groups -join ', ' }
    }

    $temp = New-LabPassword -Length 14
    $params = @{
        Name                  = $name
        GivenName             = $Hire.FirstName
        Surname               = $Hire.LastName
        DisplayName           = $name
        SamAccountName        = $sam
        UserPrincipalName     = "$sam@$($cfg.DomainFqdn)"
        EmailAddress          = "$sam@$($cfg.DomainFqdn)"
        Department            = $Hire.Department
        Title                 = $Hire.Title
        Company               = $cfg.Company
        Path                  = $path
        AccountPassword       = (ConvertTo-LabSecureString $temp)
        ChangePasswordAtLogon = $true
        Enabled               = $true
        Description           = "Onboarded $((Get-Date).ToString('yyyy-MM-dd')) per $TicketNumber; start $(([datetime]$Hire.StartDate).ToString('yyyy-MM-dd'))"
    }
    if ($mgr) { $params.Manager = $mgr.DistinguishedName }
    if ($Hire.AccountExpires) { $params.AccountExpirationDate = [datetime]$Hire.AccountExpires }

    New-ADUser @params
    foreach ($g in $groups) { Add-ADGroupMember -Identity $g -Members $sam }

    $unc = New-LabHomeFolder -SamAccountName $sam -WhatIf:$false
    Set-ADUser -Identity $sam -HomeDirectory $unc -HomeDrive $cfg.Shares.HomeDrive

    Write-LabAudit -Action 'Onboarding' -Target $sam -TicketNumber $TicketNumber -Result Success `
        -Details "OU=$($Hire.Department); groups=$($groups -join '|'); home=$unc; manager=$($Hire.Manager)"

    Write-Host ''
    Write-Host "  Temporary password for $sam (deliver via approved channel - in person or to the manager by phone; never email/chat):" -ForegroundColor Yellow
    Write-Host "      $temp" -ForegroundColor Yellow

    $mgrText = 'n/a'
    if ($mgr) { $mgrText = "$($mgr.DisplayName) ($($Hire.Manager))" }
    $note = @"
[$TicketNumber] Onboarding completed - $name
Issue:   New hire account request approved by manager $mgrText.
Steps:   Created $sam in $path; added to $($groups -join ', '); home drive $($cfg.Shares.HomeDrive) -> $unc;
         temporary password set (must change at first logon), delivered via approved channel.
Result:  Account enabled. Department share access via $($groups[0]) -> DL-FS-$($Hire.Department)-RW.
Next:    Assign laptop in CMDB (SOP-003), Day-1 checklist with user (MFA, Outlook/Teams, printer).
"@
    Write-Host ''
    Write-Host $note
    return [pscustomobject]@{ SamAccountName = $sam; Status = 'Created'; Groups = $groups -join ', '; HomeDirectory = $unc }
}

# --- Main ----------------------------------------------------------------------------------------
$hires = @()
if ($PSCmdlet.ParameterSetName -eq 'Csv') {
    if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
    foreach ($row in (Import-Csv -Path $CsvPath -Encoding UTF8)) {
        $start = (Get-Date).Date
        if ($row.PSObject.Properties.Name -contains 'StartDate' -and $row.StartDate) { $start = [datetime]$row.StartDate }
        $expires = $null
        if ($row.PSObject.Properties.Name -contains 'AccountExpires' -and $row.AccountExpires) { $expires = [datetime]$row.AccountExpires }
        $rowTicket = $TicketNumber
        if ($row.PSObject.Properties.Name -contains 'TicketNumber' -and $row.TicketNumber) { $rowTicket = $row.TicketNumber.Trim() }
        $hires += [pscustomobject]@{
            FirstName = $row.FirstName; LastName = $row.LastName; Department = $row.Department
            Title = $row.Title; Manager = $row.Manager; StartDate = $start; AccountExpires = $expires
            TicketNumber = $rowTicket
        }
    }
}
else {
    $hires += [pscustomobject]@{
        FirstName = $FirstName; LastName = $LastName; Department = $Department; Title = $Title
        Manager = $Manager; StartDate = $StartDate; AccountExpires = $AccountExpires; TicketNumber = $TicketNumber
    }
}

$summary = foreach ($h in $hires) {
    try { Invoke-Onboarding -Hire $h }
    catch {
        Write-Warning "Onboarding failed for $($h.FirstName) $($h.LastName): $($_.Exception.Message)"
        Write-LabAudit -Action 'Onboarding' -Target "$($h.FirstName) $($h.LastName)" -TicketNumber ([string]$h.TicketNumber) -Result Failed -Details $_.Exception.Message
        [pscustomobject]@{ SamAccountName = "$($h.FirstName) $($h.LastName)"; Status = 'Failed'; Groups = '' }
    }
}
Write-Host ''
$summary | Format-Table SamAccountName, Status, Groups -AutoSize
