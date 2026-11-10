#Requires -Version 5.1
<#
.SYNOPSIS
    Bulk-creates the 50 lab users from data/users.csv (department OUs, groups, managers, home folders).

.DESCRIPTION
    Run on DC01 as CONTOSO\Administrator or adm.tech. Idempotent - existing users are updated only for
    group membership and manager. Columns: FirstName, LastName, Department, Title, Office, Phone,
    EmployeeId, Manager (sAMAccountName), IsManager (TRUE/FALSE).

    For every user:
      - account first.last in OU=<Department>,OU=Users,OU=Contoso
      - member of GG-<Department> and GG-AllStaff (+ GG-Managers for managers)
      - home folder \\DC01\Home$\<sam> mapped as H: (homeDirectory/homeDrive)

.PARAMETER InitialPassword
    Shared initial password for all lab users (prompted if omitted). 12+ characters to satisfy PSO-Standard-Users.

.PARAMETER ChangePasswordAtLogon
    Force users to change the password at first logon (realistic, but slower when you test as many personas).

.EXAMPLE
    .\04-Import-LabUsers.ps1
.EXAMPLE
    .\04-Import-LabUsers.ps1 -CsvPath ..\..\..\data\users.csv -ChangePasswordAtLogon
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CsvPath = (Join-Path $PSScriptRoot '..\..\..\data\users.csv'),
    [SecureString]$InitialPassword,
    [switch]$ChangePasswordAtLogon,
    [switch]$SkipHomeFolders
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabElevated
Assert-LabModule -Name ActiveDirectory
$cfg = Get-LabConfig

if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
$rows = @(Import-Csv -Path $CsvPath -Encoding UTF8)
$required = 'FirstName', 'LastName', 'Department', 'Title', 'Manager', 'IsManager'
$missingCols = @($required | Where-Object { $rows[0].PSObject.Properties.Name -notcontains $_ })
if ($missingCols.Count -gt 0) { throw "CSV is missing columns: $($missingCols -join ', ')" }

if (-not $InitialPassword) {
    $InitialPassword = Read-Host -AsSecureString 'Initial password for all lab users (12+ characters)'
}

$results = New-Object System.Collections.Generic.List[object]

# --- Pass 1: create accounts -------------------------------------------------------------------
Write-LabStep "Creating $($rows.Count) users from $CsvPath"
foreach ($r in $rows) {
    $sam = Get-LabSamAccountName -FirstName $r.FirstName -LastName $r.LastName
    $status = 'Exists'
    try {
        $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            $params = @{
                Name                  = "$($r.FirstName) $($r.LastName)"
                GivenName             = $r.FirstName
                Surname               = $r.LastName
                DisplayName           = "$($r.FirstName) $($r.LastName)"
                SamAccountName        = $sam
                UserPrincipalName     = "$sam@$($cfg.DomainFqdn)"
                EmailAddress          = "$sam@$($cfg.DomainFqdn)"
                Department            = $r.Department
                Title                 = $r.Title
                Company               = $cfg.Company
                Office                = $r.Office
                OfficePhone           = $r.Phone
                EmployeeID            = $r.EmployeeId
                Path                  = (Get-LabDepartmentOU -Department $r.Department)
                AccountPassword       = $InitialPassword
                Enabled               = $true
                ChangePasswordAtLogon = [bool]$ChangePasswordAtLogon
                Description           = "$($r.Title) - $($r.Department)"
            }
            if ($PSCmdlet.ShouldProcess($sam, 'New-ADUser')) {
                New-ADUser @params
                $status = 'Created'
            }
            else { $status = 'WhatIf' }
        }

        if ($status -ne 'WhatIf' -and -not $SkipHomeFolders) {
            # Preference variables do not flow into module scope, so pass -WhatIf explicitly.
            $unc = New-LabHomeFolder -SamAccountName $sam -WhatIf:$WhatIfPreference
            if ($PSCmdlet.ShouldProcess($sam, "Set home drive $($cfg.Shares.HomeDrive) -> $unc")) {
                Set-ADUser -Identity $sam -HomeDirectory $unc -HomeDrive $cfg.Shares.HomeDrive
            }
        }
    }
    catch {
        $status = "Failed: $($_.Exception.Message)"
    }
    $results.Add([pscustomobject]@{ SamAccountName = $sam; Department = $r.Department; Title = $r.Title; Status = $status })
    $color = 'Green'
    if ($status -eq 'Exists') { $color = 'DarkGray' } elseif ($status -like 'Failed*') { $color = 'Red' }
    Write-Host ('    {0,-22} {1,-11} {2}' -f $sam, $r.Department, $status) -ForegroundColor $color
}

# --- Pass 2: groups and managers -----------------------------------------------------------------
Write-LabStep 'Applying group membership and managers'
foreach ($r in $rows) {
    $sam = Get-LabSamAccountName -FirstName $r.FirstName -LastName $r.LastName
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) { continue }

    $groups = @("GG-$($r.Department)", $cfg.Groups.AllStaff)
    if ($r.IsManager -match '^(true|yes|1)$') { $groups += $cfg.Groups.Managers }
    $memberOf = @(Get-ADPrincipalGroupMembership -Identity $sam | Select-Object -ExpandProperty Name)
    foreach ($g in $groups) {
        if ($memberOf -notcontains $g -and $PSCmdlet.ShouldProcess($sam, "Add to $g")) {
            Add-ADGroupMember -Identity $g -Members $sam
        }
    }

    if ($r.Manager) {
        $mgr = Get-ADUser -Filter "SamAccountName -eq '$($r.Manager)'" -ErrorAction SilentlyContinue
        if ($mgr -and $PSCmdlet.ShouldProcess($sam, "Manager = $($r.Manager)")) {
            Set-ADUser -Identity $sam -Manager $mgr.DistinguishedName
        }
        elseif (-not $mgr) { Write-Warning "Manager '$($r.Manager)' for $sam not found" }
    }
}
Write-LabOk 'Groups and managers applied'

# --- Summary ------------------------------------------------------------------------------------
Write-LabStep 'Summary'
$results | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
Write-Host 'Verify:  Get-ADUser -Filter * -SearchBase "' -NoNewline
Write-Host $cfg.OU.Users -NoNewline
Write-Host '" | Measure-Object'
Write-Host '         Get-ADUserResultantPasswordPolicy -Identity emma.carter   # should return PSO-Standard-Users'
Write-Host 'Next:    05-Configure-GroupPolicy.ps1' -ForegroundColor Yellow
