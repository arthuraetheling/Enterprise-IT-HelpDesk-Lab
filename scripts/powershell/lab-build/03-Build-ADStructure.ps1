#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the Contoso AD structure: OUs, groups (AGDLP), privileged/service accounts, fine-grained
    password policies, help desk delegation, Windows LAPS, audit policy and file shares.

.DESCRIPTION
    Run on DC01 as CONTOSO\Administrator (member of Schema Admins - required for Update-LapsADSchema).
    Idempotent: existing objects are left alone. See docs/01-lab-design.md sections 4 and 6.

      1. OU tree under OU=Contoso
      2. Security groups + nesting (GG-<Dept> -> DL-FS-<Dept>-RW, Tier2 -> Tier1)
      3. Accounts: adm.tech (Domain Admins), hd.tier1, hd.tier2, svc-scanner (PNE exception),
         legacy.contractor (expired-but-enabled control-test seed)
      4. Fine-grained password policies (PSO-Privileged-Admins, PSO-Standard-Users)
      5. Delegation: Tier 1 reset/unlock on OU=Users; Tier 2 BitLocker read on OU=Workstations;
         Tier 1 in "Event Log Readers" for lockout investigations
      6. Windows LAPS schema + permissions on OU=Workstations
      7. Advanced audit policy for lockout investigations (4740, 4771, 4776)
      8. redircmp -> OU=Workstations (new domain joins receive the baseline GPOs)
      9. File shares \\DC01\Departments (ABE) and \\DC01\Home$ with NTFS permissions

.PARAMETER AccountPassword
    Initial password for adm.tech, hd.tier1, hd.tier2, svc-scanner and legacy.contractor.
    Prompted if omitted. Use at least 15 characters (PSO-Privileged-Admins applies to admins).

.EXAMPLE
    .\03-Build-ADStructure.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [SecureString]$AccountPassword
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabElevated
Assert-LabModule -Name ActiveDirectory
$cfg = Get-LabConfig
$ou  = $cfg.OU
$nb  = $cfg.NetBiosName

if (-not $AccountPassword) {
    $AccountPassword = Read-Host -AsSecureString 'Initial password for lab admin/service accounts (15+ chars)'
}

# ------------------------------------------------------------------------------------------------
function Initialize-LabOU {
    param([string]$Name, [string]$Path, [string]$Description)
    $dn = "OU=$Name,$Path"
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
        Write-LabSkip "OU $dn"
        return
    }
    if ($PSCmdlet.ShouldProcess($dn, 'New-ADOrganizationalUnit')) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -Description $Description -ProtectedFromAccidentalDeletion $true
        Write-LabOk "OU $dn"
    }
}

function Initialize-LabGroup {
    param([string]$Name, [ValidateSet('Global', 'DomainLocal')][string]$Scope, [string]$Description)
    if (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue) {
        Write-LabSkip "Group $Name"
        return
    }
    if ($PSCmdlet.ShouldProcess($Name, "New-ADGroup ($Scope)")) {
        New-ADGroup -Name $Name -SamAccountName $Name -GroupScope $Scope -GroupCategory Security `
            -Path $ou.Groups -Description $Description
        Write-LabOk "Group $Name ($Scope)"
    }
}

function Add-LabGroupMember {
    param([string]$Group, [string[]]$Members)
    if (-not (Get-ADGroup -Filter "Name -eq '$Group'" -ErrorAction SilentlyContinue)) {
        Write-LabSkip "Group $Group not found (WhatIf run?) - skipping membership"
        return
    }
    $current = @(Get-ADGroupMember -Identity $Group | Select-Object -ExpandProperty SamAccountName)
    $toAdd = @($Members | Where-Object { $current -notcontains $_ })
    if ($toAdd.Count -eq 0) { Write-LabSkip "$Group membership"; return }
    if ($PSCmdlet.ShouldProcess($Group, "Add members: $($toAdd -join ', ')")) {
        Add-ADGroupMember -Identity $Group -Members $toAdd
        Write-LabOk "$Group += $($toAdd -join ', ')"
    }
}

function Initialize-LabUser {
    param(
        [string]$Sam, [string]$DisplayName, [string]$Path, [string]$Description,
        [switch]$PasswordNeverExpires, [Nullable[datetime]]$AccountExpires
    )
    if (Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue) {
        Write-LabSkip "User $Sam"
        return
    }
    $parts = $DisplayName.Split(' ', 2)
    $params = @{
        Name                 = $DisplayName
        DisplayName          = $DisplayName
        GivenName            = $parts[0]
        SamAccountName       = $Sam
        UserPrincipalName    = "$Sam@$($cfg.DomainFqdn)"
        Path                 = $Path
        Description          = $Description
        AccountPassword      = $AccountPassword
        Enabled              = $true
        PasswordNeverExpires = [bool]$PasswordNeverExpires
        Company              = $cfg.Company
    }
    if ($parts.Count -gt 1) { $params.Surname = $parts[1] }
    if ($AccountExpires) { $params.AccountExpirationDate = $AccountExpires }
    if ($PSCmdlet.ShouldProcess($Sam, 'New-ADUser')) {
        New-ADUser @params
        Write-LabOk "User $Sam"
    }
}

function Grant-LabDsacl {
    param([string]$ObjectDN, [string]$Grant, [string]$Label)
    if ($PSCmdlet.ShouldProcess($ObjectDN, "dsacls /G $Grant")) {
        $null = & dsacls.exe $ObjectDN /I:S /G $Grant
        if ($LASTEXITCODE -eq 0) { Write-LabOk $Label }
        else { Write-Warning "dsacls failed ($LASTEXITCODE) for: $Label" }
    }
}

# --- 1. OUs --------------------------------------------------------------------------------------
Write-LabStep 'Creating OU structure'
Initialize-LabOU -Name $cfg.RootOU -Path $cfg.DomainDN -Description "$($cfg.Company) root OU"
foreach ($child in 'Users', 'Admins', 'Groups', 'ServiceAccounts', 'Computers', 'Disabled') {
    Initialize-LabOU -Name $child -Path $ou.Root -Description "$($cfg.Company) $child"
}
foreach ($dept in $cfg.Departments) {
    Initialize-LabOU -Name $dept -Path $ou.Users -Description "$dept department users"
}
foreach ($child in 'Workstations', 'Servers', 'Staging') {
    Initialize-LabOU -Name $child -Path $ou.Computers -Description "$child computers"
}

# --- 2. Groups -----------------------------------------------------------------------------------
Write-LabStep 'Creating security groups (AGDLP)'
foreach ($dept in $cfg.Departments) {
    Initialize-LabGroup -Name "GG-$dept" -Scope Global -Description "$dept department members"
    Initialize-LabGroup -Name "DL-FS-$dept-RW" -Scope DomainLocal -Description "Modify on $($cfg.DeptShareUnc)\$dept"
}
Initialize-LabGroup -Name $cfg.Groups.AllStaff      -Scope Global -Description 'All standard user accounts (FGPP target)'
Initialize-LabGroup -Name $cfg.Groups.Managers      -Scope Global -Description 'People managers - access request approvers'
Initialize-LabGroup -Name $cfg.Groups.HelpDeskTier1 -Scope Global -Description 'Tier 1 Service Desk - reset password / unlock'
Initialize-LabGroup -Name $cfg.Groups.HelpDeskTier2 -Scope Global -Description 'Tier 2 Desktop Support - LAPS, BitLocker'

Write-LabStep 'Nesting groups'
foreach ($dept in $cfg.Departments) { Add-LabGroupMember -Group "DL-FS-$dept-RW" -Members "GG-$dept" }
Add-LabGroupMember -Group $cfg.Groups.HelpDeskTier1 -Members $cfg.Groups.HelpDeskTier2

# --- 3. Accounts -----------------------------------------------------------------------------
Write-LabStep 'Creating privileged, service and control-test accounts'
$acct = $cfg.Accounts
Initialize-LabUser -Sam $acct.DomainAdmin -DisplayName 'Lab Admin (Tier 0)' -Path $ou.Admins `
    -Description 'Domain admin - use only under a change record'
Initialize-LabUser -Sam $acct.Tier1 -DisplayName 'Help Desk Tier1' -Path $ou.Admins -Description 'Tier 1 Service Desk analyst'
Initialize-LabUser -Sam $acct.Tier2 -DisplayName 'Help Desk Tier2' -Path $ou.Admins -Description 'Tier 2 Desktop Support analyst'
Initialize-LabUser -Sam $acct.ServiceAccount -DisplayName 'Scanner Service' -Path $ou.ServiceAccounts -PasswordNeverExpires `
    -Description 'Scan-to-folder service account. PNE exception EXC-001 approved by Lucas Moreno, review 2027-05'
Initialize-LabUser -Sam $acct.ControlTestSeed -DisplayName 'Legacy Contractor' -Path (Get-LabDepartmentOU -Department 'Finance') `
    -AccountExpires ([datetime]'2026-06-30') -Description 'Contractor - contract ended 2026-06-30 (control-test seed)'

Add-LabGroupMember -Group 'Domain Admins'            -Members $acct.DomainAdmin
Add-LabGroupMember -Group $cfg.Groups.HelpDeskTier1  -Members $acct.Tier1
Add-LabGroupMember -Group $cfg.Groups.HelpDeskTier2  -Members $acct.Tier2
Add-LabGroupMember -Group 'GG-Finance'               -Members $acct.ControlTestSeed
Add-LabGroupMember -Group $cfg.Groups.AllStaff       -Members $acct.ControlTestSeed

# --- 4. Fine-grained password policies -------------------------------------------------------
Write-LabStep 'Creating fine-grained password policies'
$psos = @(
    @{ Name = 'PSO-Privileged-Admins'; Precedence = 10; MinPasswordLength = 15; MaxPasswordAge = (New-TimeSpan -Days 60)
       LockoutThreshold = 3; LockoutDuration = (New-TimeSpan -Minutes 30); LockoutObservationWindow = (New-TimeSpan -Minutes 30)
       Subjects = @('Domain Admins', $cfg.Groups.HelpDeskTier1, $cfg.Groups.HelpDeskTier2) },
    @{ Name = 'PSO-Standard-Users'; Precedence = 20; MinPasswordLength = 12; MaxPasswordAge = (New-TimeSpan -Days 90)
       LockoutThreshold = 5; LockoutDuration = (New-TimeSpan -Minutes 15); LockoutObservationWindow = (New-TimeSpan -Minutes 15)
       Subjects = @($cfg.Groups.AllStaff) }
)
foreach ($p in $psos) {
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($p.Name)'" -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($p.Name, 'New-ADFineGrainedPasswordPolicy')) {
            New-ADFineGrainedPasswordPolicy -Name $p.Name -Precedence $p.Precedence -MinPasswordLength $p.MinPasswordLength `
                -ComplexityEnabled $true -PasswordHistoryCount 24 -MinPasswordAge (New-TimeSpan -Days 1) `
                -MaxPasswordAge $p.MaxPasswordAge -LockoutThreshold $p.LockoutThreshold -LockoutDuration $p.LockoutDuration `
                -LockoutObservationWindow $p.LockoutObservationWindow -ReversibleEncryptionEnabled $false `
                -ProtectedFromAccidentalDeletion $true
            Write-LabOk "$($p.Name) (precedence $($p.Precedence), min length $($p.MinPasswordLength), lockout $($p.LockoutThreshold))"
        }
    }
    else { Write-LabSkip $p.Name }

    if (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($p.Name)'" -ErrorAction SilentlyContinue) {
        $applied = @(Get-ADFineGrainedPasswordPolicySubject -Identity $p.Name | Select-Object -ExpandProperty Name)
        $missing = @($p.Subjects | Where-Object { $applied -notcontains $_ })
        if ($missing.Count -gt 0 -and $PSCmdlet.ShouldProcess($p.Name, "Apply to $($missing -join ', ')")) {
            Add-ADFineGrainedPasswordPolicySubject -Identity $p.Name -Subjects $missing
            Write-LabOk "$($p.Name) applies to $($missing -join ', ')"
        }
    }
}

# --- 5. Delegation ---------------------------------------------------------------------------------
Write-LabStep 'Delegating help desk rights (least privilege)'
$t1 = "$nb\$($cfg.Groups.HelpDeskTier1)"
$t2 = "$nb\$($cfg.Groups.HelpDeskTier2)"
Grant-LabDsacl -ObjectDN $ou.Users -Grant "${t1}:CA;Reset Password;user" -Label 'Tier 1: Reset Password on user objects in OU=Users'
Grant-LabDsacl -ObjectDN $ou.Users -Grant "${t1}:RPWP;lockoutTime;user"  -Label 'Tier 1: read/write lockoutTime (unlock)'
Grant-LabDsacl -ObjectDN $ou.Users -Grant "${t1}:RPWP;pwdLastSet;user"   -Label 'Tier 1: read/write pwdLastSet (must change at next logon)'
Grant-LabDsacl -ObjectDN $ou.Workstations -Grant "${t2}:GA;;msFVE-RecoveryInformation" `
    -Label 'Tier 2: read BitLocker recovery information under OU=Workstations'
Add-LabGroupMember -Group 'Event Log Readers' -Members $cfg.Groups.HelpDeskTier1

# --- 6. Windows LAPS ------------------------------------------------------------------------------
Write-LabStep 'Configuring Windows LAPS'
if (Get-Command -Name Update-LapsADSchema -ErrorAction SilentlyContinue) {
    try {
        if ($PSCmdlet.ShouldProcess('AD schema', 'Update-LapsADSchema')) {
            Update-LapsADSchema -Confirm:$false
            Set-LapsADComputerSelfPermission  -Identity $ou.Workstations | Out-Null
            Set-LapsADReadPasswordPermission  -Identity $ou.Workstations -AllowedPrincipals $t2 | Out-Null
            Set-LapsADResetPasswordPermission -Identity $ou.Workstations -AllowedPrincipals $t2 | Out-Null
            Write-LabOk 'LAPS schema extended; computers can write their password; Tier 2 can read/reset'
        }
    }
    catch {
        Write-Warning "Windows LAPS setup failed: $($_.Exception.Message). Run as CONTOSO\Administrator (Schema Admins) and re-run."
    }
}
else {
    Write-Warning 'Windows LAPS cmdlets not found. Install the latest cumulative update (April 2023 or later) and re-run.'
}

# --- 7. Audit policy for lockout investigations -------------------------------------------------
Write-LabStep 'Enabling audit subcategories used by Get-AccountLockoutInfo.ps1'
$auditSubcategories = @{
    '{0CCE9235-69AE-11D9-BED3-505054503030}' = 'User Account Management (4740 lockouts)'
    '{0CCE9242-69AE-11D9-BED3-505054503030}' = 'Kerberos Authentication Service (4771 pre-auth failures)'
    '{0CCE923F-69AE-11D9-BED3-505054503030}' = 'Credential Validation (4776 NTLM failures)'
}
foreach ($guid in $auditSubcategories.Keys) {
    if ($PSCmdlet.ShouldProcess($auditSubcategories[$guid], 'auditpol success+failure')) {
        $null = & auditpol.exe /set "/subcategory:$guid" /success:enable /failure:enable
        if ($LASTEXITCODE -eq 0) { Write-LabOk $auditSubcategories[$guid] }
        else { Write-Warning "auditpol failed for $($auditSubcategories[$guid])" }
    }
}

# --- 8. Default computer container ---------------------------------------------------------------
Write-LabStep 'Redirecting the default computers container to OU=Workstations'
if ($PSCmdlet.ShouldProcess($ou.Workstations, 'redircmp')) {
    $null = & redircmp.exe $ou.Workstations
    if ($LASTEXITCODE -eq 0) { Write-LabOk 'New domain joins land in OU=Workstations' }
    else { Write-Warning "redircmp exit code $LASTEXITCODE" }
}

# --- 9. File shares ----------------------------------------------------------------------------
Write-LabStep 'Creating file shares'
$root     = $cfg.Shares.LocalRoot
$deptRoot = Join-Path $root $cfg.Shares.DepartmentsName
$homeRoot = Join-Path $root 'Home'
$sidSystem = '*S-1-5-18'; $sidAdmins = '*S-1-5-32-544'; $sidAuthUsers = '*S-1-5-11'

if ($PSCmdlet.ShouldProcess($root, 'Create folders, NTFS permissions and SMB shares')) {
    foreach ($p in @($deptRoot, $homeRoot)) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }

    $allStaffSid = '*' + (Get-ADGroup $cfg.Groups.AllStaff).SID.Value
    $null = & icacls.exe $deptRoot /inheritance:r /grant:r "${sidSystem}:(OI)(CI)F" "${sidAdmins}:(OI)(CI)F" "${allStaffSid}:(RX)"
    foreach ($dept in $cfg.Departments) {
        $path = Join-Path $deptRoot $dept
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
        $dlSid = '*' + (Get-ADGroup "DL-FS-$dept-RW").SID.Value
        $null = & icacls.exe $path /inheritance:r /grant:r "${sidSystem}:(OI)(CI)F" "${sidAdmins}:(OI)(CI)F" "${dlSid}:(OI)(CI)M"
        Write-LabOk "$path -> DL-FS-$dept-RW Modify"
    }
    $null = & icacls.exe $homeRoot /inheritance:r /grant:r "${sidSystem}:(OI)(CI)F" "${sidAdmins}:(OI)(CI)F" "${sidAuthUsers}:(RX)"

    $shares = @(
        @{ Name = $cfg.Shares.DepartmentsName; Path = $deptRoot; Description = 'Department shares (S:) - access-based enumeration' },
        @{ Name = $cfg.Shares.HomeName;        Path = $homeRoot; Description = 'User home folders (H:)' }
    )
    foreach ($s in $shares) {
        if (Get-SmbShare -Name $s.Name -ErrorAction SilentlyContinue) { Write-LabSkip "Share $($s.Name)"; continue }
        New-SmbShare -Name $s.Name -Path $s.Path -Description $s.Description -FolderEnumerationMode AccessBased `
            -FullAccess 'BUILTIN\Administrators' -ChangeAccess 'NT AUTHORITY\Authenticated Users' | Out-Null
        Write-LabOk "Share \\$($cfg.DomainController.Name)\$($s.Name) -> $($s.Path)"
    }
}

Write-LabStep 'Done'
Write-Host 'Verify:  Get-ADOrganizationalUnit -Filter * -SearchBase "' -NoNewline; Write-Host $ou.Root -NoNewline; Write-Host '" | Select Name'
Write-Host '         Get-ADFineGrainedPasswordPolicy -Filter * | Select Name, Precedence, LockoutThreshold'
Write-Host '         Get-ADUserResultantPasswordPolicy -Identity hd.tier1'
Write-Host 'Next:    04-Import-LabUsers.ps1' -ForegroundColor Yellow
