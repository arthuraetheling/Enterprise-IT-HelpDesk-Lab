#Requires -Version 5.1
<#
.SYNOPSIS
    Creates, configures and links the five lab GPOs (docs/01-lab-design.md section 5).

.DESCRIPTION
    Run on DC01 as adm.tech / CONTOSO\Administrator. Idempotent. Before touching existing GPOs it takes a
    pre-change backup (Backup-GPO) - that backup is the backout plan referenced by CHG0030001.
    After configuration it saves HTML reports (Get-GPOReport) as change evidence.

      CON-C-Workstation-Baseline  -> OU=Workstations  firewall, inactivity lock, logon banner, Windows Update,
                                                       Defender real-time protection, PowerShell script-block logging
      CON-C-Workstation-BitLocker -> OU=Workstations  XTS-AES 256, recovery info must be escrowed to AD DS
      CON-C-Workstation-LAPS      -> OU=Workstations  Windows LAPS -> AD, 30 days, 14 chars, complexity 4
      CON-U-Standard-User         -> OU=Users          password-protected screen saver (900 s)
      CON-U-Finance-USB-Deny      -> OU=Finance        deny all removable storage

    The S: drive mapping (Group Policy Preferences) is created manually in GPMC - see docs/02-build-guide.md.

.PARAMETER PilotOnly
    Create and configure the GPOs but do not link them (use for the pilot step of the change).

.EXAMPLE
    .\05-Configure-GroupPolicy.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$PilotOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabElevated
Assert-LabModule -Name GroupPolicy, ActiveDirectory
$cfg = Get-LabConfig
$ou  = $cfg.OU

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $cfg.GpoBackupPath $stamp

# --- Helpers ------------------------------------------------------------------------------------
function Initialize-LabGpo {
    param([string]$Name, [string]$Comment)
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if ($gpo) {
        Write-LabSkip "GPO $Name exists (id $($gpo.Id))"
        return $gpo
    }
    if ($PSCmdlet.ShouldProcess($Name, 'New-GPO')) {
        $gpo = New-GPO -Name $Name -Comment $Comment
        Write-LabOk "GPO $Name created"
        return $gpo
    }
    return $null
}

function Set-LabGpoValue {
    param($Gpo, [string]$Key, [string]$ValueName, [ValidateSet('DWord', 'String')][string]$Type, $Value)
    if (-not $Gpo) { return }
    if ($PSCmdlet.ShouldProcess("$($Gpo.DisplayName): $Key\$ValueName", "Set $Type $Value")) {
        Set-GPRegistryValue -Guid $Gpo.Id -Key $Key -ValueName $ValueName -Type $Type -Value $Value | Out-Null
    }
}

function Set-LabGpoLink {
    param($Gpo, [string]$Target)
    if (-not $Gpo) { return }
    if ($PilotOnly) { Write-LabSkip "PilotOnly: not linking $($Gpo.DisplayName)"; return }
    $linked = @((Get-GPInheritance -Target $Target).GpoLinks | Select-Object -ExpandProperty DisplayName)
    if ($linked -contains $Gpo.DisplayName) { Write-LabSkip "$($Gpo.DisplayName) already linked to $Target"; return }
    if ($PSCmdlet.ShouldProcess($Target, "Link $($Gpo.DisplayName)")) {
        New-GPLink -Guid $Gpo.Id -Target $Target -LinkEnabled Yes | Out-Null
        Write-LabOk "Linked $($Gpo.DisplayName) -> $Target"
    }
}

$labGpoNames = 'CON-C-Workstation-Baseline', 'CON-C-Workstation-BitLocker', 'CON-C-Workstation-LAPS',
               'CON-U-Standard-User', 'CON-U-Finance-USB-Deny'

# --- Pre-change backup (backout plan) ----------------------------------------------------------
$existing = @($labGpoNames | ForEach-Object { Get-GPO -Name $_ -ErrorAction SilentlyContinue } | Where-Object { $_ })
if ($existing.Count -gt 0 -and $PSCmdlet.ShouldProcess($backupDir, "Backup $($existing.Count) existing GPOs")) {
    Write-LabStep "Pre-change backup -> $backupDir\pre-change"
    New-Item -ItemType Directory -Path (Join-Path $backupDir 'pre-change') -Force | Out-Null
    foreach ($g in $existing) { Backup-GPO -Guid $g.Id -Path (Join-Path $backupDir 'pre-change') | Out-Null }
    Write-LabOk 'Restore with: Restore-GPO -Name <GPO> -Path <backup folder>'
}

# --- 1. Workstation baseline --------------------------------------------------------------------
Write-LabStep 'CON-C-Workstation-Baseline'
$g = Initialize-LabGpo -Name 'CON-C-Workstation-Baseline' -Comment 'Endpoint hardening baseline (BC-09, BC-10). Change: CHG0030001'
foreach ($p in 'DomainProfile', 'StandardProfile', 'PublicProfile') {
    Set-LabGpoValue $g "HKLM\Software\Policies\Microsoft\WindowsFirewall\$p" 'EnableFirewall' DWord 1
}
$sys = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System'
Set-LabGpoValue $g $sys 'InactivityTimeoutSecs' DWord 900
Set-LabGpoValue $g $sys 'legalnoticecaption' String "$($cfg.Company) - Authorized Use Only"
Set-LabGpoValue $g $sys 'legalnoticetext' String ("This system is for authorized $($cfg.Company) business use only. " +
    'Activity is monitored and logged. By signing in you agree to the Acceptable Use Policy.')
$wu = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'
Set-LabGpoValue $g $wu 'NoAutoUpdate' DWord 0
Set-LabGpoValue $g $wu 'AUOptions' DWord 4              # auto download and schedule the install
Set-LabGpoValue $g $wu 'ScheduledInstallDay' DWord 0     # every day
Set-LabGpoValue $g $wu 'ScheduledInstallTime' DWord 3    # 03:00
Set-LabGpoValue $g 'HKLM\Software\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' DWord 0
Set-LabGpoValue $g 'HKLM\Software\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging' DWord 1
Set-LabGpoLink $g $ou.Workstations

# --- 2. BitLocker -----------------------------------------------------------------------------
Write-LabStep 'CON-C-Workstation-BitLocker'
$g = Initialize-LabGpo -Name 'CON-C-Workstation-BitLocker' -Comment 'Data-at-rest encryption with AD DS key escrow (BC-03)'
$fve = 'HKLM\Software\Policies\Microsoft\FVE'
Set-LabGpoValue $g $fve 'EncryptionMethodWithXtsOs'  DWord 7   # XTS-AES 256 (OS drive)
Set-LabGpoValue $g $fve 'EncryptionMethodWithXtsFdv' DWord 7   # XTS-AES 256 (fixed data drives)
Set-LabGpoValue $g $fve 'EncryptionMethodWithXtsRdv' DWord 4   # AES-CBC 256 (removable, for compatibility)
Set-LabGpoValue $g $fve 'OSRecovery' DWord 1                   # "Choose how OS drives can be recovered" = Enabled
Set-LabGpoValue $g $fve 'OSManageDRA' DWord 1
Set-LabGpoValue $g $fve 'OSRecoveryPassword' DWord 2           # allow 48-digit recovery password
Set-LabGpoValue $g $fve 'OSRecoveryKey' DWord 2                # allow 256-bit recovery key
Set-LabGpoValue $g $fve 'OSHideRecoveryPage' DWord 1
Set-LabGpoValue $g $fve 'OSActiveDirectoryBackup' DWord 1      # save recovery information to AD DS
Set-LabGpoValue $g $fve 'OSActiveDirectoryInfoToStore' DWord 1 # recovery passwords and key packages
Set-LabGpoValue $g $fve 'OSRequireActiveDirectoryBackup' DWord 1 # do not enable until escrow succeeds
Set-LabGpoLink $g $ou.Workstations

# --- 3. Windows LAPS -----------------------------------------------------------------------------
Write-LabStep 'CON-C-Workstation-LAPS'
$g = Initialize-LabGpo -Name 'CON-C-Workstation-LAPS' -Comment 'Windows LAPS - unique local admin passwords escrowed to AD (BC-02)'
$laps = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'
Set-LabGpoValue $g $laps 'BackupDirectory' DWord 2               # 2 = Active Directory
Set-LabGpoValue $g $laps 'PasswordAgeDays' DWord 30
Set-LabGpoValue $g $laps 'PasswordLength' DWord 14
Set-LabGpoValue $g $laps 'PasswordComplexity' DWord 4            # upper + lower + digits + specials
Set-LabGpoValue $g $laps 'PostAuthenticationActions' DWord 3     # reset password and log off the managed account
Set-LabGpoValue $g $laps 'PostAuthenticationResetDelay' DWord 8  # hours after use
Set-LabGpoLink $g $ou.Workstations

# --- 4. Standard user experience --------------------------------------------------------------
Write-LabStep 'CON-U-Standard-User'
$g = Initialize-LabGpo -Name 'CON-U-Standard-User' -Comment 'User experience; S: drive (GPP) added manually in GPMC'
$desk = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
Set-LabGpoValue $g $desk 'ScreenSaveActive' String '1'
Set-LabGpoValue $g $desk 'ScreenSaverIsSecure' String '1'
Set-LabGpoValue $g $desk 'ScreenSaveTimeOut' String '900'
Set-LabGpoValue $g $desk 'SCRNSAVE.EXE' String 'scrnsave.scr'
Set-LabGpoLink $g $ou.Users

# --- 5. Finance removable storage --------------------------------------------------------------
Write-LabStep 'CON-U-Finance-USB-Deny'
$g = Initialize-LabGpo -Name 'CON-U-Finance-USB-Deny' -Comment 'Data-loss prevention for Finance (BC-08)'
Set-LabGpoValue $g 'HKCU\Software\Policies\Microsoft\Windows\RemovableStorageDevices' 'Deny_All' DWord 1
Set-LabGpoLink $g (Get-LabDepartmentOU -Department 'Finance')

# --- Evidence: post-change backup + HTML reports -------------------------------------------------
if ($PSCmdlet.ShouldProcess($backupDir, 'Post-change backup and HTML reports')) {
    Write-LabStep "Post-change backup and reports -> $backupDir"
    $post = Join-Path $backupDir 'post-change'
    New-Item -ItemType Directory -Path $post -Force | Out-Null
    foreach ($name in $labGpoNames) {
        $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
        if (-not $gpo) { continue }
        Backup-GPO -Guid $gpo.Id -Path $post | Out-Null
        Get-GPOReport -Guid $gpo.Id -ReportType Html -Path (Join-Path $backupDir "$name.html")
    }
    Write-LabOk 'Backups and reports saved'
}

Write-LabStep 'Next steps'
Write-Host '  1. In GPMC, edit CON-U-Standard-User > User Configuration > Preferences > Windows Settings > Drive Maps:'
Write-Host "     New mapped drive S: -> $($cfg.DeptShareUnc), Action Update, Reconnect, label 'Departments'."
Write-Host '  2. On LT-WIN-001: gpupdate /force, then gpresult /r (computer + user sections).'
Write-Host '  3. Record the result in CHG0030001 (see itil/examples).'
