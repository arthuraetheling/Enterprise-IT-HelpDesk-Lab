#Requires -Version 5.1
<#
    Lab.Common.psm1 - shared helpers for the lab-build, helpdesk and lab-faults scripts.
    Endpoint scripts (scripts/powershell/endpoint) are intentionally standalone and do NOT use this module,
    so they can be copied to any laptop on their own.
#>

Set-StrictMode -Version 2.0

$script:LabConfig = $null

function Get-LabConfig {
    <#
    .SYNOPSIS
        Loads Lab.Config.psd1 (cached) and adds the derived OU distinguished names.
    #>
    [CmdletBinding()]
    param([switch]$Reload)

    if ($script:LabConfig -and -not $Reload) { return $script:LabConfig }

    $path = Join-Path $PSScriptRoot 'Lab.Config.psd1'
    if (-not (Test-Path $path)) { throw "Lab configuration not found: $path" }
    $cfg = Import-PowerShellDataFile -Path $path

    $root = "OU=$($cfg.RootOU),$($cfg.DomainDN)"
    $cfg.OU = @{
        Root            = $root
        Users           = "OU=Users,$root"
        Admins          = "OU=Admins,$root"
        Groups          = "OU=Groups,$root"
        ServiceAccounts = "OU=ServiceAccounts,$root"
        Computers       = "OU=Computers,$root"
        Workstations    = "OU=Workstations,OU=Computers,$root"
        Servers         = "OU=Servers,OU=Computers,$root"
        Staging         = "OU=Staging,OU=Computers,$root"
        Disabled        = "OU=Disabled,$root"
    }
    $cfg.DcFqdn          = '{0}.{1}' -f $cfg.DomainController.Name, $cfg.DomainFqdn
    $cfg.HomeShareUnc    = '\\{0}\{1}' -f $cfg.DomainController.Name, $cfg.Shares.HomeName
    $cfg.DeptShareUnc    = '\\{0}\{1}' -f $cfg.DomainController.Name, $cfg.Shares.DepartmentsName

    $script:LabConfig = $cfg
    return $cfg
}

function Get-LabDepartmentOU {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Department)
    $cfg = Get-LabConfig
    if ($cfg.Departments -notcontains $Department) {
        throw "Unknown department '$Department'. Valid: $($cfg.Departments -join ', ')"
    }
    return "OU=$Department,$($cfg.OU.Users)"
}

function Assert-LabElevated {
    [CmdletBinding()]
    param()
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run in an elevated PowerShell session (Run as administrator).'
    }
}

function Assert-LabModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name)
    foreach ($n in $Name) {
        if (-not (Get-Module -ListAvailable -Name $n)) {
            throw "Required PowerShell module '$n' is not installed. On a server: Install-WindowsFeature RSAT-AD-PowerShell / GPMC / RSAT-DHCP. On Windows 11: Settings > System > Optional features > RSAT."
        }
        Import-Module $n -ErrorAction Stop -Verbose:$false
    }
}

function New-LabPassword {
    <#
    .SYNOPSIS
        Generates a random password with upper, lower, digit and symbol characters.
        Ambiguous characters (0 O o 1 l I) are excluded because temporary passwords are often read aloud.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(12, 64)][int]$Length = 16)

    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower  = 'abcdefghijkmnpqrstuvwxyz'
    $digit  = '23456789'
    $symbol = '!#$%*+-=?@_'
    $all    = $upper + $lower + $digit + $symbol

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $pick = {
            param([string]$set)
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            $set[[int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$set.Length)]
        }
        $chars = New-Object System.Collections.Generic.List[char]
        $chars.Add((& $pick $upper)); $chars.Add((& $pick $lower))
        $chars.Add((& $pick $digit)); $chars.Add((& $pick $symbol))
        while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }

        # Fisher-Yates shuffle so the guaranteed characters are not always first.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            $j = [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]($i + 1))
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return -join $chars
    }
    finally { $rng.Dispose() }
}

function ConvertTo-LabSecureString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlainText)
    return (ConvertTo-SecureString -String $PlainText -AsPlainText -Force)
}

function Get-LabSamAccountName {
    <#
    .SYNOPSIS
        Builds a first.last sAMAccountName (lowercase, letters/digits only, max 20 characters).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName
    )
    $clean = {
        param([string]$s)
        $normalized = $s.Normalize([Text.NormalizationForm]::FormD)
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in $normalized.ToCharArray()) {
            if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
                [void]$sb.Append($ch)
            }
        }
        ($sb.ToString().ToLowerInvariant() -replace '[^a-z0-9]', '')
    }
    $sam = '{0}.{1}' -f (& $clean $FirstName), (& $clean $LastName)
    if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }
    return $sam.TrimEnd('.')
}

function Write-LabAudit {
    <#
    .SYNOPSIS
        Appends one line to the help desk audit log (CSV). Never pass secrets in -Details.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Target,
        [string]$TicketNumber = '',
        [ValidateSet('Success', 'Failed', 'WhatIf', 'Info')][string]$Result = 'Success',
        [string]$Details = ''
    )
    $cfg = Get-LabConfig
    $dir = Split-Path -Parent $cfg.AuditLogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $entry = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        Operator  = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
        Computer  = $env:COMPUTERNAME
        Action    = $Action
        Target    = $Target
        Ticket    = $TicketNumber
        Result    = $Result
        Details   = $Details
    }
    $entry | Export-Csv -Path $cfg.AuditLogPath -Append -NoTypeInformation -Encoding UTF8
}

function New-LabHomeFolder {
    <#
    .SYNOPSIS
        Creates \\DC01\Home$\<sam> and grants the user Modify. Returns the UNC path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SamAccountName)

    $cfg = Get-LabConfig
    $unc = Join-Path $cfg.HomeShareUnc $SamAccountName
    if ($PSCmdlet.ShouldProcess($unc, 'Create home folder and grant Modify')) {
        if (-not (Test-Path $unc)) { New-Item -ItemType Directory -Path $unc -Force | Out-Null }
        $identity = '{0}\{1}' -f $cfg.NetBiosName, $SamAccountName
        $null = & icacls.exe $unc /grant "${identity}:(OI)(CI)M"
        if ($LASTEXITCODE -ne 0) { throw "icacls failed to grant $identity on $unc (exit $LASTEXITCODE)" }
    }
    return $unc
}

function Write-LabStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host ('==> {0}' -f $Message) -ForegroundColor Cyan
}

function Write-LabOk {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ('    [OK] {0}' -f $Message) -ForegroundColor Green
}

function Write-LabSkip {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ('    [--] {0}' -f $Message) -ForegroundColor DarkGray
}

Export-ModuleMember -Function Get-LabConfig, Get-LabDepartmentOU, Assert-LabElevated, Assert-LabModule,
    New-LabPassword, ConvertTo-LabSecureString, Get-LabSamAccountName, Write-LabAudit, New-LabHomeFolder,
    Write-LabStep, Write-LabOk, Write-LabSkip
