#Requires -Version 5.1
<#
.SYNOPSIS
    Retrieves the BitLocker recovery password escrowed in AD DS for a computer (Tier 2, KB0011).

.DESCRIPTION
    Recovery information is stored as msFVE-RecoveryInformation child objects of the computer account.
    The object name is "<timestamp>{<recovery password ID>}". Match the first 8 characters of the
    Key ID shown on the user's recovery screen with -KeyId before reading the password to them.

    Requires read access to msFVE-RecoveryPassword (Domain Admins, or GG-HelpDesk-Tier2 via the
    delegation in 03-Build-ADStructure.ps1). The retrieval is audited; the key itself is never logged.
    After the user is back in Windows, rotate the recovery password (see KB0011).

.EXAMPLE
    .\Get-BitLockerRecoveryKey.ps1 -ComputerName LT-WIN-001 -KeyId 1A2B3C4D -TicketNumber INC0010011
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputerName,
    [ValidatePattern('^[0-9A-Fa-f-]{4,36}$')][string]$KeyId,
    [string]$TicketNumber = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabModule -Name ActiveDirectory

$computer = Get-ADComputer -Identity $ComputerName
$records = @(Get-ADObject -SearchBase $computer.DistinguishedName -SearchScope OneLevel `
        -Filter "objectClass -eq 'msFVE-RecoveryInformation'" -Properties 'msFVE-RecoveryPassword', whenCreated |
    ForEach-Object {
        $id = ''
        if ($_.Name -match '\{([0-9A-Fa-f-]{36})\}') { $id = $Matches[1].ToUpperInvariant() }
        [pscustomobject]@{
            Computer         = $ComputerName
            Created          = $_.whenCreated
            KeyId            = $id
            RecoveryPassword = $_.'msFVE-RecoveryPassword'
        }
    } | Sort-Object Created -Descending)

if ($records.Count -eq 0) {
    Write-Warning "No recovery information in AD for $ComputerName. Check that CON-C-Workstation-BitLocker applied BEFORE encryption, or escalate to Contoso Desktop Support lead."
    Write-LabAudit -Action 'BitLockerKeyLookup' -Target $ComputerName -TicketNumber $TicketNumber -Result Failed -Details 'No recovery objects found'
    return
}

if ($KeyId) {
    $prefix = ($KeyId -replace '-', '').ToUpperInvariant()
    $records = @($records | Where-Object { ($_.KeyId -replace '-', '').StartsWith($prefix) })
    if ($records.Count -eq 0) {
        Write-Warning "No recovery key on $ComputerName matches Key ID $KeyId. Confirm the ID on the recovery screen (and that this is the right device)."
        Write-LabAudit -Action 'BitLockerKeyLookup' -Target $ComputerName -TicketNumber $TicketNumber -Result Failed -Details "KeyId $KeyId not matched"
        return
    }
}

if (@($records | Where-Object { -not $_.RecoveryPassword }).Count -gt 0) {
    Write-Warning 'Some recovery passwords are empty - your account lacks read access to msFVE-RecoveryPassword (confidential attribute).'
}

Write-LabAudit -Action 'BitLockerKeyLookup' -Target $ComputerName -TicketNumber $TicketNumber -Details "KeyId(s): $(($records.KeyId) -join ', ')"
$records | Format-List Computer, Created, KeyId, RecoveryPassword
Write-Host 'Read the 48-digit password to the VERIFIED user in groups of six. After recovery, rotate it (KB0011).' -ForegroundColor Yellow
