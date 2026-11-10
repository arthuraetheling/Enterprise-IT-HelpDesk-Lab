#Requires -Version 5.1
<#
.SYNOPSIS
    Checks a Windows endpoint against the Contoso security baseline and produces audit evidence.

.DESCRIPTION
    Standalone and read-only. Runs without admin rights (a few controls report Unknown unless elevated).
    Each control maps to a business control in docs/01-lab-design.md section 10.

      CMP-01 BitLocker protection on the OS drive          BC-03
      CMP-02 BitLocker recovery password protector exists BC-03 (admin)
      CMP-03 Defender real-time protection on             BC-09
      CMP-04 Defender signatures <= 3 days old            BC-09
      CMP-05 Windows Firewall on for all profiles         BC-09
      CMP-06 OS build >= -MinimumBuild (supported)        BC-09
      CMP-07 Last update installed <= -MaxPatchAgeDays    BC-09
      CMP-08 Screen lock enforced <= 900 s                BC-09
      CMP-09 Local Administrators limited to allow-list   BC-01
      CMP-10 Windows LAPS policy configured               BC-02
      CMP-11 Logon banner configured                      BC-09
      CMP-12 PowerShell script-block logging enabled      BC-10
      CMP-13 Secure Boot enabled                          BC-09
      CMP-14 TPM present and ready                        BC-03 (admin)
      CMP-15 Device is domain- or Entra-joined (managed)  BC-11

    Exit code: 0 = all evaluated controls pass, 1 = at least one failure.

.EXAMPLE
    .\Test-EndpointCompliance.ps1
.EXAMPLE
    .\Test-EndpointCompliance.ps1 -Format Csv -OutputPath \\DC01\Evidence$\Compliance
#>
[CmdletBinding()]
param(
    [int]$MinimumBuild = 26100,
    [int]$MaxPatchAgeDays = 35,
    [int]$MaxInactivitySeconds = 900,
    [int]$SignatureMaxAgeDays = 3,
    [string[]]$AllowedLocalAdmins = @('Domain Admins'),
    [ValidateSet('Console', 'Object', 'Csv', 'Json')][string]$Format = 'Console',
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$controls = New-Object System.Collections.Generic.List[object]

function Add-Control {
    param([string]$Id, [string]$Name, [string]$Ref, [string]$Expected, [string]$Actual,
          [ValidateSet('Pass', 'Fail', 'Unknown')][string]$Result, [string]$Remediation = '')
    $controls.Add([pscustomobject]@{
        ComputerName = $env:COMPUTERNAME; CheckedAt = (Get-Date).ToString('s'); Id = $Id; Control = $Name; Ref = $Ref
        Expected = $Expected; Actual = $Actual; Result = $Result; Remediation = $Remediation
    })
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($item -and $item.PSObject.Properties.Name -contains $Name) { return $item.$Name }
    return $null
}

# --- CMP-01 / CMP-02 BitLocker ------------------------------------------------------------------
$bl = $null
if ($isAdmin) { try { $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop } catch { $bl = $null } }
if ($bl) {
    $on = ([string]$bl.ProtectionStatus -eq 'On')
    $res = 'Fail'; if ($on) { $res = 'Pass' }
    Add-Control 'CMP-01' 'BitLocker on OS drive' 'BC-03' 'Protection On, XtsAes256' "$($bl.ProtectionStatus), $($bl.VolumeStatus), $($bl.EncryptionMethod)" $res 'Enable BitLocker after CON-C-Workstation-BitLocker applies (see docs/05-endpoint-management.md)'
    $types = @($bl.KeyProtector | ForEach-Object { [string]$_.KeyProtectorType })
    $hasRp = $types -contains 'RecoveryPassword'
    $res = 'Fail'; if ($hasRp) { $res = 'Pass' }
    Add-Control 'CMP-02' 'Recovery password protector' 'BC-03' 'RecoveryPassword protector (escrowed to AD)' ($types -join ', ') $res 'Add-BitLockerKeyProtector -RecoveryPasswordProtector, then Backup-BitLockerKeyProtector'
}
else {
    # Non-admin fallback: the shell exposes the protection state without elevation (best effort).
    $map = @{ 0 = 'Not BitLocker capable'; 1 = 'On'; 2 = 'Off'; 3 = 'Encrypting'; 4 = 'Decrypting'; 5 = 'Suspended'; 6 = 'On (locked)'; 8 = 'Waiting for activation' }
    $state = $null
    try { $state = (New-Object -ComObject Shell.Application).NameSpace("$env:SystemDrive\").Self.ExtendedProperty('System.Volume.BitLockerProtection') } catch { }
    if ($null -eq $state -or $state -eq '') {
        Add-Control 'CMP-01' 'BitLocker on OS drive' 'BC-03' 'Protection On' 'Unavailable (edition without BitLocker, or no access)' 'Unknown' 'Run elevated on a Pro/Enterprise device'
    }
    else {
        $label = $map[[int]$state]
        if (-not $label) { $label = "state $state" }
        $res = 'Fail'; if ([int]$state -in 1, 6) { $res = 'Pass' }
        Add-Control 'CMP-01' 'BitLocker on OS drive' 'BC-03' 'Protection On' "$label (shell, non-admin)" $res 'Enable BitLocker; on Windows Home only Device Encryption is available'
    }
    Add-Control 'CMP-02' 'Recovery password protector' 'BC-03' 'RecoveryPassword protector' 'Requires elevation' 'Unknown'
}

# --- CMP-03 / CMP-04 Defender ------------------------------------------------------------------
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $res = 'Fail'; if ($mp.RealTimeProtectionEnabled) { $res = 'Pass' }
    Add-Control 'CMP-03' 'Defender real-time protection' 'BC-09' 'Enabled' ([string]$mp.RealTimeProtectionEnabled) $res 'Set-MpPreference -DisableRealtimeMonitoring $false; check tamper protection / third-party AV'
    $age = [int]$mp.AntivirusSignatureAge
    $res = 'Fail'; if ($age -le $SignatureMaxAgeDays) { $res = 'Pass' }
    Add-Control 'CMP-04' 'Defender signature age' 'BC-09' "<= $SignatureMaxAgeDays days" "$age day(s)" $res 'Update-MpSignature'
}
catch {
    Add-Control 'CMP-03' 'Defender real-time protection' 'BC-09' 'Enabled' 'Defender status unavailable (third-party AV?)' 'Unknown'
    Add-Control 'CMP-04' 'Defender signature age' 'BC-09' "<= $SignatureMaxAgeDays days" 'Unavailable' 'Unknown'
}

# --- CMP-05 Firewall --------------------------------------------------------------------------------
try {
    $fw = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    $off = @($fw | Where-Object { [string]$_.Enabled -ne 'True' } | Select-Object -ExpandProperty Name)
    $res = 'Pass'; $actual = 'All profiles on'
    if ($off.Count -gt 0) { $res = 'Fail'; $actual = "Off: $($off -join ', ')" }
    Add-Control 'CMP-05' 'Windows Firewall (all profiles)' 'BC-09' 'Domain/Private/Public on' $actual $res 'Set-NetFirewallProfile -All -Enabled True (or fix the GPO)'
}
catch { Add-Control 'CMP-05' 'Windows Firewall (all profiles)' 'BC-09' 'All on' 'Unavailable' 'Unknown' }

# --- CMP-06 OS build --------------------------------------------------------------------------------
$cvPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int](Get-RegValue $cvPath 'CurrentBuild')
$ubr = Get-RegValue $cvPath 'UBR'
$dv = Get-RegValue $cvPath 'DisplayVersion'
$res = 'Fail'; if ($build -ge $MinimumBuild) { $res = 'Pass' }
Add-Control 'CMP-06' 'Supported OS build' 'BC-09' ">= $MinimumBuild" ("{0} build {1}.{2}" -f $dv, $build, $ubr) $res 'Upgrade to a supported Windows 11 feature update'

# --- CMP-07 Patch age ------------------------------------------------------------------------------
$last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
if ($last) {
    $days = [int]((Get-Date) - [datetime]$last.InstalledOn).TotalDays
    $res = 'Fail'; if ($days -le $MaxPatchAgeDays) { $res = 'Pass' }
    Add-Control 'CMP-07' 'Patch currency' 'BC-09' "Update within $MaxPatchAgeDays days" ("{0} installed {1} ({2} days ago)" -f $last.HotFixID, ([datetime]$last.InstalledOn).ToString('yyyy-MM-dd'), $days) $res 'Run Windows Update; check WU policy / ResetWindowsUpdate'
}
else { Add-Control 'CMP-07' 'Patch currency' 'BC-09' "Update within $MaxPatchAgeDays days" 'No hotfix history available' 'Unknown' }

# --- CMP-08 Screen lock -----------------------------------------------------------------------------
$machineLock = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'InactivityTimeoutSecs'
$ssTimeout = Get-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop' 'ScreenSaveTimeOut'
$ssSecure = Get-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop' 'ScreenSaverIsSecure'
$okMachine = ($machineLock -and [int]$machineLock -gt 0 -and [int]$machineLock -le $MaxInactivitySeconds)
$okUser = ($ssTimeout -and [int]$ssTimeout -le $MaxInactivitySeconds -and [string]$ssSecure -eq '1')
$actual = "Machine inactivity: $(if ($machineLock) { "$machineLock s" } else { 'not set' }); screen saver policy: $(if ($ssTimeout) { "$ssTimeout s, secure=$ssSecure" } else { 'not set' })"
$res = 'Fail'; if ($okMachine -or $okUser) { $res = 'Pass' }
Add-Control 'CMP-08' 'Screen lock enforced' 'BC-09' "<= $MaxInactivitySeconds s by policy" $actual $res 'Apply CON-C-Workstation-Baseline / CON-U-Standard-User'

# --- CMP-09 Local Administrators ---------------------------------------------------------------------
$members = @()
try {
    $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Sid = [string]$_.SID } })
}
catch {
    # Fallback for the known Get-LocalGroupMember bug with orphaned/Entra SIDs.
    try {
        $grp = [ADSI]("WinNT://$env:COMPUTERNAME/" + (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1] + ',group')
        $members = @($grp.Invoke('Members') | ForEach-Object {
            $path = $_.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $_, $null)
            $sidBytes = $_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null)
            $sid = ''; try { $sid = (New-Object Security.Principal.SecurityIdentifier($sidBytes, 0)).Value } catch { }
            [pscustomobject]@{ Name = ($path -replace '^WinNT://', '' -replace '/', '\'); Sid = $sid }
        })
    }
    catch { $members = $null }
}
if ($null -eq $members) {
    Add-Control 'CMP-09' 'Local Administrators membership' 'BC-01' 'Built-in Administrator (LAPS) + allow-list' 'Could not enumerate' 'Unknown'
}
else {
    $violations = @($members | Where-Object {
        $short = $_.Name.Split('\')[-1]
        -not ($_.Sid -match '-500$' -or $_.Sid -match '-512$' -or $AllowedLocalAdmins -contains $short)
    } | Select-Object -ExpandProperty Name)
    $res = 'Pass'; $actual = "$($members.Count) member(s), all allowed"
    if ($violations.Count -gt 0) { $res = 'Fail'; $actual = "Not allowed: $($violations -join ', ')" }
    Add-Control 'CMP-09' 'Local Administrators membership' 'BC-01' "Built-in Administrator (LAPS), Domain Admins, $($AllowedLocalAdmins -join ', ')" $actual $res 'Remove standard users from local Administrators; use LAPS for elevation'
}

# --- CMP-10 Windows LAPS ---------------------------------------------------------------------------
$backup = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS' 'BackupDirectory'
$legacy = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd' 'AdmPwdEnabled'
$actual = 'Not configured'; $res = 'Fail'
if ($backup -eq 2) { $actual = 'Windows LAPS -> Active Directory'; $res = 'Pass' }
elseif ($backup -eq 1) { $actual = 'Windows LAPS -> Microsoft Entra ID'; $res = 'Pass' }
elseif ($legacy -eq 1) { $actual = 'Legacy Microsoft LAPS'; $res = 'Pass' }
Add-Control 'CMP-10' 'Windows LAPS policy' 'BC-02' 'BackupDirectory = 1 or 2' $actual $res 'Apply CON-C-Workstation-LAPS; then Invoke-LapsPolicyProcessing'

# --- CMP-11 Logon banner -------------------------------------------------------------------------------
$caption = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'legalnoticecaption'
$res = 'Fail'; $actual = 'Not set'
if ($caption) { $res = 'Pass'; $actual = [string]$caption }
Add-Control 'CMP-11' 'Logon banner' 'BC-09' 'legalnoticecaption set' $actual $res 'Apply CON-C-Workstation-Baseline'

# --- CMP-12 Script-block logging ---------------------------------------------------------------------
$sbl = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging'
$res = 'Fail'; if ($sbl -eq 1) { $res = 'Pass' }
Add-Control 'CMP-12' 'PowerShell script-block logging' 'BC-10' 'EnableScriptBlockLogging = 1' ([string]$(if ($null -ne $sbl) { $sbl } else { 'not set' })) $res 'Apply CON-C-Workstation-Baseline'

# --- CMP-13 Secure Boot ------------------------------------------------------------------------------
$sb = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
if ($null -eq $sb) { Add-Control 'CMP-13' 'Secure Boot' 'BC-09' 'Enabled' 'Not reported (legacy BIOS?)' 'Unknown' 'Enable UEFI + Secure Boot in firmware / VM settings' }
else {
    $res = 'Fail'; if ($sb -eq 1) { $res = 'Pass' }
    Add-Control 'CMP-13' 'Secure Boot' 'BC-09' 'Enabled' ([string]$(if ($sb -eq 1) { 'Enabled' } else { 'Disabled' })) $res 'Enable Secure Boot in firmware / VM settings'
}

# --- CMP-14 TPM ----------------------------------------------------------------------------------------
if ($isAdmin) {
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $res = 'Fail'; if ($tpm.TpmPresent -and $tpm.TpmReady) { $res = 'Pass' }
        Add-Control 'CMP-14' 'TPM present and ready' 'BC-03' 'Present + Ready' "Present=$($tpm.TpmPresent), Ready=$($tpm.TpmReady)" $res 'Enable TPM in firmware (VMware: add a vTPM)'
    }
    catch { Add-Control 'CMP-14' 'TPM present and ready' 'BC-03' 'Present + Ready' $_.Exception.Message 'Unknown' }
}
else { Add-Control 'CMP-14' 'TPM present and ready' 'BC-03' 'Present + Ready' 'Requires elevation' 'Unknown' }

# --- CMP-15 Managed (joined) -----------------------------------------------------------------------
$cs = Get-CimInstance Win32_ComputerSystem
$entra = $false
try { $entra = [bool](((& dsregcmd.exe /status) 2>$null | Out-String) -match 'AzureAdJoined\s*:\s*YES') } catch { }
$res = 'Fail'; $actual = 'Workgroup / not managed'
if ($cs.PartOfDomain) { $res = 'Pass'; $actual = "Domain: $($cs.Domain)" }
elseif ($entra) { $res = 'Pass'; $actual = 'Microsoft Entra joined' }
Add-Control 'CMP-15' 'Device is managed (joined)' 'BC-11' 'Domain or Entra joined' $actual $res 'Join the domain (SOP-003) and register in the CMDB'

# --- Output ----------------------------------------------------------------------------------------------
$evaluated = @($controls | Where-Object Result -ne 'Unknown')
$passed = @($evaluated | Where-Object Result -eq 'Pass').Count
$failed = @($evaluated | Where-Object Result -eq 'Fail').Count
$score = 0
if ($evaluated.Count -gt 0) { $score = [math]::Round(($passed / $evaluated.Count) * 100, 0) }
$exitCode = 0; if ($failed -gt 0) { $exitCode = 1 }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

switch ($Format) {
    'Object' { return $controls.ToArray() }
    'Csv' {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $file = Join-Path $OutputPath "$($env:COMPUTERNAME)-compliance-$stamp.csv"
        $controls | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
        Write-Host "Compliance evidence written to $file ($passed/$($evaluated.Count) passed, $score%)"
    }
    'Json' {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $file = Join-Path $OutputPath "$($env:COMPUTERNAME)-compliance-$stamp.json"
        $doc = [pscustomobject]@{ ComputerName = $env:COMPUTERNAME; CheckedAt = (Get-Date).ToString('s'); Score = $score; Controls = $controls.ToArray() }
        [System.IO.File]::WriteAllText($file, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Compliance evidence written to $file ($passed/$($evaluated.Count) passed, $score%)"
    }
    default {
        Write-Host ''
        Write-Host "Endpoint compliance - $env:COMPUTERNAME (elevated: $isAdmin)" -ForegroundColor Cyan
        Write-Host ('{0,-7} {1,-34} {2,-6} {3,-8} {4}' -f 'ID', 'CONTROL', 'REF', 'RESULT', 'ACTUAL')
        foreach ($c in $controls) {
            $color = @{ Pass = 'Green'; Fail = 'Red'; Unknown = 'DarkGray' }[$c.Result]
            $actualText = $c.Actual
            if ($actualText.Length -gt 70) { $actualText = $actualText.Substring(0, 67) + '...' }
            Write-Host ('{0,-7} {1,-34} {2,-6} {3,-8} {4}' -f $c.Id, $c.Control, $c.Ref, $c.Result, $actualText) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host ("Score: {0}/{1} evaluated controls passed ({2}%), {3} unknown" -f $passed, $evaluated.Count, $score, ($controls.Count - $evaluated.Count)) -ForegroundColor Yellow
        foreach ($f in @($controls | Where-Object Result -eq 'Fail')) { Write-Host ("  FIX {0}: {1}" -f $f.Id, $f.Remediation) }
    }
}
exit $exitCode
