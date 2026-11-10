#Requires -Version 5.1
<#
.SYNOPSIS
    Runs Get-EndpointHealth.ps1 and turns failing checks into de-duplicated ServiceNow incidents.

.DESCRIPTION
    Event-management pattern from docs/01-lab-design.md section 9:
      - every failing check -> one incident with correlation_id "<COMPUTER>-<CHECK>"
      - while that incident is open, repeat alerts add a work note (throttled) instead of a duplicate
      - when the check returns to OK: add a "condition cleared" note, or resolve it with -AutoResolve
      - Critical -> impact 3 / urgency 1 (P3); Warning -> impact 3 / urgency 2 (P4); group Contoso Desktop Support

    Credentials: pass -Credential, or -CredentialPath to a file created with
        Get-Credential | Export-Clixml -Path $env:LOCALAPPDATA\ContosoHelpDesk\snow.cred
    (DPAPI - readable only by the same user on the same machine). -RegisterScheduledTask runs it every
    -IntervalMinutes as the current user.

.EXAMPLE
    .\Invoke-HealthCheckAndAlert.ps1 -DryRun
.EXAMPLE
    python ..\..\..\tests\mock_servicenow.py     # in another window
    .\Invoke-HealthCheckAndAlert.ps1 -InstanceUrl http://127.0.0.1:8765 -Credential (Get-Credential svc.helpdesk.automation)
.EXAMPLE
    .\Invoke-HealthCheckAndAlert.ps1 -InstanceUrl https://dev12345.service-now.com -CredentialPath $env:LOCALAPPDATA\ContosoHelpDesk\snow.cred -AutoResolve
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstanceUrl,
    [pscredential]$Credential,
    [string]$CredentialPath,
    [string]$AssignmentGroup = 'Contoso Desktop Support',
    [ValidateSet('Warning', 'Critical')][string]$MinimumSeverity = 'Warning',
    [switch]$AutoResolve,
    [string]$CloseCode = 'Solution provided',
    [int]$NoteIntervalHours = 4,
    [switch]$DryRun,
    [switch]$RegisterScheduledTask,
    [int]$IntervalMinutes = 30,
    [string]$StatePath = (Join-Path $env:LOCALAPPDATA 'ContosoHelpDesk\alert-state.json'),
    # Extra parameters for Get-EndpointHealth.ps1, e.g. @{ DiskWarnPercent = 20 }
    [hashtable]$HealthCheckParameters = @{}
)

$ErrorActionPreference = 'Stop'
$healthScript = Join-Path $PSScriptRoot '..\endpoint\Get-EndpointHealth.ps1'
Import-Module (Join-Path $PSScriptRoot 'ServiceNow.psm1') -Force

# --- Optional: register as a scheduled task -------------------------------------------------------
if ($RegisterScheduledTask) {
    if (-not $InstanceUrl -or -not $CredentialPath) { throw '-RegisterScheduledTask needs -InstanceUrl and -CredentialPath.' }
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -InstanceUrl `"$InstanceUrl`" -CredentialPath `"$CredentialPath`" -MinimumSeverity $MinimumSeverity"
    if ($AutoResolve) { $argList += ' -AutoResolve' }
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
    $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    if ($PSCmdlet.ShouldProcess('Contoso-EndpointHealthToServiceNow', "Register task every $IntervalMinutes min")) {
        Register-ScheduledTask -TaskName 'Contoso-EndpointHealthToServiceNow' -Action $action -Trigger $trigger -Settings $settings `
            -Description 'Endpoint health check -> ServiceNow incidents (Enterprise IT Help Desk Lab)' -Force | Out-Null
        Write-Host "Scheduled task registered (every $IntervalMinutes minutes, current user)." -ForegroundColor Green
    }
    return
}

# --- Connect ----------------------------------------------------------------------------------------
if ($CredentialPath -and -not $Credential) { $Credential = Import-Clixml -Path $CredentialPath }
if ($DryRun) {
    if (-not $InstanceUrl) { $InstanceUrl = 'https://dev00000.service-now.com' }
    Connect-ServiceNow -InstanceUrl $InstanceUrl -DryRun
}
else {
    if (-not $InstanceUrl -or -not $Credential) { throw 'Provide -InstanceUrl and -Credential/-CredentialPath, or use -DryRun.' }
    Connect-ServiceNow -InstanceUrl $InstanceUrl -Credential $Credential
}

# --- Health check ---------------------------------------------------------------------------------
$health = & $healthScript -Format Object @HealthCheckParameters
$computer = $health.System.ComputerName
$severityRank = @{ OK = 0; Unknown = 0; Warning = 1; Critical = 2 }
$minRank = $severityRank[$MinimumSeverity]

$classification = @{
    'Disk'          = @('hardware', 'disk', 'KB0013')
    'Memory'        = @('hardware', 'memory', 'KB0013')
    'CPU'           = @('hardware', 'cpu', 'KB0013')
    'Uptime'        = @('software', 'os', 'KB0013')
    'PendingReboot' = @('software', 'os', 'KB0013')
    'Defender'      = @('security', 'malware alert', '')
    'Firewall'      = @('security', 'firewall', '')
    'Services'      = @('software', 'os', '')
    'EventLog'      = @('software', 'os', '')
    'Network'       = @('network', 'ip address', 'KB0005')
}

# --- State (note throttling) --------------------------------------------------------------------------
$state = @{}
if (Test-Path $StatePath) {
    try {
        $raw = Get-Content -Path $StatePath -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $state[$p.Name] = $p.Value }
    }
    catch { Write-Warning "Ignoring unreadable state file $StatePath" }
}

$actions = New-Object System.Collections.Generic.List[object]
$failingIds = @()

foreach ($c in $health.Checks) {
    if ($severityRank[$c.Status] -lt $minRank -or $severityRank[$c.Status] -eq 0) { continue }
    $corr = '{0}-{1}' -f $computer, $c.Id
    $failingIds += $corr
    $family = ($c.Id -split '-')[0]
    $cls = $classification[$family]
    if (-not $cls) { $cls = @('software', 'os', '') }
    $urgency = '2'; if ($c.Status -eq 'Critical') { $urgency = '1' }

    $open = @(Find-SnOpenIncident -CorrelationId $corr) | Select-Object -First 1
    if ($open) {
        $prev = $state[$corr]
        $due = $true
        if ($prev -and $prev.LastNote) {
            $due = ((Get-Date) - [datetime]$prev.LastNote).TotalHours -ge $NoteIntervalHours -or $prev.LastStatus -ne $c.Status
        }
        if ($due) {
            $null = Add-SnWorkNote -SysId $open.sys_id -Note ("[{0}] Still {1}: {2}. {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $c.Status, $c.Value, $c.Detail)
            $actions.Add([pscustomobject]@{ Check = $c.Check; Status = $c.Status; Action = "Updated $($open.number)"; CorrelationId = $corr })
            $state[$corr] = [pscustomobject]@{ Number = $open.number; SysId = $open.sys_id; LastStatus = $c.Status; LastNote = (Get-Date).ToString('o') }
        }
        else { $actions.Add([pscustomobject]@{ Check = $c.Check; Status = $c.Status; Action = "Open $($open.number) (note throttled)"; CorrelationId = $corr }) }
        continue
    }

    $kbText = ''
    if ($cls[2]) { $kbText = " Suggested KB: $($cls[2])." }
    $desc = @"
Automated alert from Invoke-HealthCheckAndAlert.ps1

Device:     $computer ($($health.System.Model))
User:       $($health.System.LoggedOnUser)
OS:         $($health.System.OS) $($health.System.Version)
Check:      $($c.Check)
Status:     $($c.Status)
Value:      $($c.Value)
Detail:     $($c.Detail)
Collected:  $($health.CollectedAt)
Correlation ID: $corr
$kbText
"@
    $inc = New-SnIncident -ShortDescription ("[Endpoint] {0}: {1} {2} - {3}" -f $computer, $c.Check, $c.Status, $c.Value) `
        -Description $desc -Impact '3' -Urgency $urgency -Category $cls[0] -Subcategory $cls[1] `
        -AssignmentGroup $AssignmentGroup -ConfigurationItem $computer -CorrelationId $corr
    if ($inc) {
        $actions.Add([pscustomobject]@{ Check = $c.Check; Status = $c.Status; Action = "Created $($inc.number) (P$(if ($inc.PSObject.Properties.Name -contains 'priority') { $inc.priority } else { '?' }))"; CorrelationId = $corr })
        $state[$corr] = [pscustomobject]@{ Number = $inc.number; SysId = $inc.sys_id; LastStatus = $c.Status; LastNote = (Get-Date).ToString('o') }
    }
}

# --- Recovery: open incidents for this host whose check is OK again -----------------------------------
foreach ($inc in @(Find-SnOpenIncident -CorrelationPrefix "$computer-")) {
    if ($failingIds -contains $inc.correlation_id) { continue }
    $msg = "[{0}] Condition cleared - health check returned OK." -f (Get-Date -Format 'yyyy-MM-dd HH:mm')
    if ($AutoResolve) {
        $null = Resolve-SnIncident -SysId $inc.sys_id -CloseCode $CloseCode -CloseNotes "$msg Auto-resolved by monitoring; reopen if the user still sees the issue."
        $actions.Add([pscustomobject]@{ Check = $inc.correlation_id; Status = 'OK'; Action = "Resolved $($inc.number)"; CorrelationId = $inc.correlation_id })
        $state.Remove($inc.correlation_id)
    }
    else {
        $prev = $state[$inc.correlation_id]
        if (-not ($prev -and $prev.LastStatus -eq 'OK')) {
            $null = Add-SnWorkNote -SysId $inc.sys_id -Note "$msg Awaiting analyst verification before resolving."
            $actions.Add([pscustomobject]@{ Check = $inc.correlation_id; Status = 'OK'; Action = "Noted recovery on $($inc.number)"; CorrelationId = $inc.correlation_id })
            $state[$inc.correlation_id] = [pscustomobject]@{ Number = $inc.number; SysId = $inc.sys_id; LastStatus = 'OK'; LastNote = (Get-Date).ToString('o') }
        }
    }
}

# --- Save state + summary -----------------------------------------------------------------------------
if (-not $DryRun) {
    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = New-Object psobject
    foreach ($k in $state.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $state[$k] }
    [System.IO.File]::WriteAllText($StatePath, ($obj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host ''
Write-Host "Health: $($health.Overall) on $computer - $($actions.Count) ServiceNow action(s)" -ForegroundColor Cyan
if ($actions.Count -gt 0) { $actions | Format-Table Check, Status, Action, CorrelationId -AutoSize | Out-String -Width 200 | Write-Host }
else { Write-Host 'No failing checks at or above the minimum severity and nothing to recover.' -ForegroundColor Green }
