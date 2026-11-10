#Requires -Version 5.1
<#
    ServiceNow.psm1 - minimal ServiceNow Table API client for the lab (Windows PowerShell 5.1).

    Functions
      Connect-ServiceNow    -InstanceUrl https://devNNNNN.service-now.com -Credential <PSCredential> [-DryRun]
      Invoke-SnRequest      low-level GET/POST/PATCH with retries (429/5xx) and readable errors
      Resolve-SnReference   name -> sys_id lookup with caching (assignment groups, CIs, users, companies)
      New-SnIncident        create an incident (impact/urgency -> priority is calculated by ServiceNow)
      Find-SnOpenIncident   find active incidents by correlation_id (exact or prefix)
      Add-SnWorkNote        append an internal work note
      Resolve-SnIncident    set state Resolved with close code + notes
      Set-SnComputerCi      create-or-update a CMDB computer CI (match on serial number, then name)

    Authentication: basic auth with a dedicated integration user (role: itil) - lab only. In production use
    OAuth client credentials and a secret vault. Use -DryRun to print requests without sending anything, or
    point -InstanceUrl at tests/mock_servicenow.py (http://127.0.0.1:8765) for offline testing.
#>

Set-StrictMode -Version 2.0
$script:Sn = $null

function Connect-ServiceNow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstanceUrl,
        [pscredential]$Credential,
        [switch]$DryRun,
        [switch]$SkipValidation
    )
    $base = $InstanceUrl.TrimEnd('/')
    if ($base -notmatch '^https?://') { $base = "https://$base" }
    if ($base -match '^http://' -and $base -notmatch '^http://(127\.0\.0\.1|localhost)(:\d+)?$') {
        throw 'Use https:// for real instances (plain http is allowed only for the local mock).'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $headers = @{ Accept = 'application/json' }
    $user = 'dry-run'
    if ($Credential) {
        $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
        $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
        $user = $Credential.UserName
    }
    elseif (-not $DryRun) { throw 'A credential is required unless -DryRun is used.' }

    $script:Sn = [pscustomobject]@{ BaseUrl = $base; Headers = $headers; DryRun = [bool]$DryRun; Cache = @{}; User = $user }

    if (-not $DryRun -and -not $SkipValidation) {
        $me = @(Invoke-SnRequest -Path '/api/now/table/sys_user' -Query @{ sysparm_query = "user_name=$user"; sysparm_fields = 'sys_id,user_name'; sysparm_limit = 1 })
        if ($me.Count -eq 0) { Write-Warning "Connected to $base, but user '$user' was not returned from sys_user (check the itil role)." }
    }
    Write-Verbose "ServiceNow session: $base as $user (DryRun=$([bool]$DryRun))"
}

function Invoke-SnRequest {
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        [hashtable]$Body,
        [int]$MaxRetries = 2
    )
    if (-not $script:Sn) { throw 'Not connected. Run Connect-ServiceNow first.' }

    $uri = $script:Sn.BaseUrl + $Path
    if ($Query -and $Query.Count -gt 0) {
        $pairs = foreach ($k in $Query.Keys) { '{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Query[$k]) }
        $uri = $uri + '?' + ($pairs -join '&')
    }
    $json = $null
    if ($Body) { $json = $Body | ConvertTo-Json -Depth 5 -Compress }

    if ($script:Sn.DryRun) {
        if ($Method -eq 'GET') {
            Write-Host "[DRY-RUN] GET $uri" -ForegroundColor DarkYellow
            return @()
        }
        Write-Host "[DRY-RUN] $Method $uri" -ForegroundColor DarkYellow
        if ($json) { Write-Host "          $json" -ForegroundColor DarkYellow }
        $fake = @{ sys_id = 'dryrun-' + [guid]::NewGuid().ToString('N').Substring(0, 12); number = 'INC-DRYRUN' }
        return [pscustomobject]$fake
    }

    $attempt = 0
    while ($true) {
        try {
            $params = @{ Uri = $uri; Method = $Method; Headers = $script:Sn.Headers; ErrorAction = 'Stop' }
            if ($json) {
                $params['Body'] = [Text.Encoding]::UTF8.GetBytes($json)
                $params['ContentType'] = 'application/json; charset=utf-8'
            }
            $resp = Invoke-RestMethod @params
            if ($null -ne $resp -and $resp.PSObject.Properties.Name -contains 'result') { return $resp.result }
            return $resp
        }
        catch {
            $status = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            $detail = $_.Exception.Message
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
            if (($status -eq 429 -or $status -ge 500) -and $attempt -lt $MaxRetries) {
                $attempt++
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                continue
            }
            if ($status -eq 401) { $detail = "Authentication failed for '$($script:Sn.User)'. $detail" }
            throw "ServiceNow $Method $Path failed (HTTP $status): $detail"
        }
    }
}

function Resolve-SnReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][string]$Value
    )
    if ($script:Sn.DryRun) { return "<$Table.$Field=$Value>" }
    $key = "$Table|$Field|$Value"
    if ($script:Sn.Cache.ContainsKey($key)) { return $script:Sn.Cache[$key] }
    $rows = @(Invoke-SnRequest -Path "/api/now/table/$Table" -Query @{ sysparm_query = "$Field=$Value"; sysparm_fields = 'sys_id'; sysparm_limit = 1 })
    $id = $null
    if ($rows.Count -gt 0 -and $rows[0]) { $id = $rows[0].sys_id }
    $script:Sn.Cache[$key] = $id
    return $id
}

function New-SnIncident {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ShortDescription,
        [string]$Description,
        [ValidateSet('1', '2', '3')][string]$Impact = '3',
        [ValidateSet('1', '2', '3')][string]$Urgency = '3',
        [string]$Category,
        [string]$Subcategory,
        [string]$AssignmentGroup,
        [string]$ConfigurationItem,
        [string]$CallerUserName,
        [string]$CorrelationId,
        [string]$CorrelationDisplay = 'Contoso endpoint health check',
        [string]$WorkNote
    )
    $body = @{ short_description = $ShortDescription; impact = $Impact; urgency = $Urgency }
    if ($Description) { $body['description'] = $Description }
    if ($Category) { $body['category'] = $Category }
    if ($Subcategory) { $body['subcategory'] = $Subcategory }
    if ($AssignmentGroup) {
        $gid = Resolve-SnReference -Table 'sys_user_group' -Field 'name' -Value $AssignmentGroup
        if ($gid) { $body['assignment_group'] = $gid } else { Write-Warning "Assignment group '$AssignmentGroup' not found - incident will be unassigned." }
    }
    if ($ConfigurationItem) {
        $cid = Resolve-SnReference -Table 'cmdb_ci' -Field 'name' -Value $ConfigurationItem
        if ($cid) { $body['cmdb_ci'] = $cid } else { Write-Verbose "CI '$ConfigurationItem' not in the CMDB (run Sync-InventoryToCmdb.ps1)." }
    }
    if ($CallerUserName) {
        $uid = Resolve-SnReference -Table 'sys_user' -Field 'user_name' -Value $CallerUserName
        if ($uid) { $body['caller_id'] = $uid }
    }
    if ($CorrelationId) { $body['correlation_id'] = $CorrelationId; $body['correlation_display'] = $CorrelationDisplay }
    if ($WorkNote) { $body['work_notes'] = $WorkNote }

    if ($PSCmdlet.ShouldProcess($ShortDescription, 'Create ServiceNow incident')) {
        return Invoke-SnRequest -Method POST -Path '/api/now/table/incident' -Body $body `
            -Query @{ sysparm_fields = 'sys_id,number,priority,state,short_description,correlation_id' }
    }
}

function Find-SnOpenIncident {
    [CmdletBinding(DefaultParameterSetName = 'Exact')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Exact')][string]$CorrelationId,
        [Parameter(Mandatory, ParameterSetName = 'Prefix')][string]$CorrelationPrefix
    )
    $q = 'active=true^'
    if ($PSCmdlet.ParameterSetName -eq 'Exact') { $q += "correlation_id=$CorrelationId" } else { $q += "correlation_idSTARTSWITH$CorrelationPrefix" }
    return @(Invoke-SnRequest -Path '/api/now/table/incident' -Query @{
        sysparm_query = $q; sysparm_fields = 'sys_id,number,state,priority,correlation_id,short_description'; sysparm_limit = 50 })
}

function Add-SnWorkNote {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SysId, [Parameter(Mandatory)][string]$Note)
    if ($PSCmdlet.ShouldProcess($SysId, 'Add work note')) {
        return Invoke-SnRequest -Method PATCH -Path "/api/now/table/incident/$SysId" -Body @{ work_notes = $Note } -Query @{ sysparm_fields = 'sys_id,number,state' }
    }
}

function Resolve-SnIncident {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SysId,
        [string]$CloseCode = 'Solution provided',   # older releases use e.g. 'Solved (Permanently)'
        [Parameter(Mandatory)][string]$CloseNotes
    )
    if ($PSCmdlet.ShouldProcess($SysId, "Resolve incident ($CloseCode)")) {
        return Invoke-SnRequest -Method PATCH -Path "/api/now/table/incident/$SysId" `
            -Body @{ state = '6'; close_code = $CloseCode; close_notes = $CloseNotes } -Query @{ sysparm_fields = 'sys_id,number,state' }
    }
}

function Set-SnComputerCi {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$SerialNumber,
        [hashtable]$Attributes = @{},
        [string]$Class = 'cmdb_ci_computer'
    )
    $fields = 'sys_id,name,serial_number,sys_class_name'
    $existing = $null
    if ($SerialNumber) {
        $existing = @(Invoke-SnRequest -Path "/api/now/table/$Class" -Query @{ sysparm_query = "serial_number=$SerialNumber"; sysparm_fields = $fields; sysparm_limit = 1 }) | Select-Object -First 1
    }
    if (-not $existing) {
        $existing = @(Invoke-SnRequest -Path "/api/now/table/$Class" -Query @{ sysparm_query = "name=$Name"; sysparm_fields = $fields; sysparm_limit = 1 }) | Select-Object -First 1
    }
    $body = @{ name = $Name }
    if ($SerialNumber) { $body['serial_number'] = $SerialNumber }
    foreach ($k in $Attributes.Keys) { if ($null -ne $Attributes[$k] -and [string]$Attributes[$k] -ne '') { $body[$k] = [string]$Attributes[$k] } }

    if ($existing) {
        if ($PSCmdlet.ShouldProcess($Name, "Update $Class $($existing.sys_id)")) {
            $r = Invoke-SnRequest -Method PATCH -Path "/api/now/table/$Class/$($existing.sys_id)" -Body $body -Query @{ sysparm_fields = $fields }
            return [pscustomobject]@{ Name = $Name; Action = 'Updated'; SysId = $existing.sys_id; Result = $r }
        }
    }
    elseif ($PSCmdlet.ShouldProcess($Name, "Create $Class")) {
        $r = Invoke-SnRequest -Method POST -Path "/api/now/table/$Class" -Body $body -Query @{ sysparm_fields = $fields }
        return [pscustomobject]@{ Name = $Name; Action = 'Created'; SysId = $r.sys_id; Result = $r }
    }
}

Export-ModuleMember -Function Connect-ServiceNow, Invoke-SnRequest, Resolve-SnReference, New-SnIncident,
    Find-SnOpenIncident, Add-SnWorkNote, Resolve-SnIncident, Set-SnComputerCi
