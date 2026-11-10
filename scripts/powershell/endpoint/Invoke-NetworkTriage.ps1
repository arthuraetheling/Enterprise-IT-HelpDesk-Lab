#Requires -Version 5.1
<#
.SYNOPSIS
    Layered network triage for "no internet / can't reach the share / VPN won't connect" tickets.

.DESCRIPTION
    Standalone, read-only, no admin needed. Walks the stack bottom-up and stops guessing where the evidence is:

      1. Adapter        - is a NIC up? Wi-Fi or Ethernet? any VPN adapter connected?
      2. IP address     - DHCP or static, APIPA (169.254.x.x) detection, lease times, DHCP server
      3. Gateway        - default route present and answering
      4. DNS servers    - reachable on TCP 53; flags public resolvers on a domain-joined device
      5. Name resolution- external name, internal name, AD DC locator SRV record (_ldap._tcp.dc._msdcs)
      6. Services       - TCP 53/88/389/445 to a domain controller, HTTPS 443 to the internet
      7. Verdict        - most likely fault, the matching KB, and a ticket-ready summary

.PARAMETER InternalHost
    Internal name to resolve/test (default: the AD domain if joined, e.g. corp.contoso.internal).

.PARAMETER Format
    Console (default) or Object (returns the results for scripting) or Json (prints JSON).

.EXAMPLE
    .\Invoke-NetworkTriage.ps1
.EXAMPLE
    .\Invoke-NetworkTriage.ps1 -InternalHost dc01.corp.contoso.internal
#>
[CmdletBinding()]
param(
    [string]$InternalHost,
    [string]$ExternalHost = 'www.microsoft.com',
    [int[]]$DcPorts = @(53, 88, 389, 445),
    [int]$TimeoutMs = 2000,
    [ValidateSet('Console', 'Object', 'Json')][string]$Format = 'Console'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$steps = New-Object System.Collections.Generic.List[object]
function Add-Step {
    param([string]$Layer, [string]$Test, [ValidateSet('Pass', 'Fail', 'Warn', 'Info', 'Skip')][string]$Result, [string]$Detail)
    $steps.Add([pscustomobject]@{ Layer = $Layer; Test = $Test; Result = $Result; Detail = $Detail })
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$Timeout = $TimeoutMs)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if ($task.Wait($Timeout)) { return $client.Connected }
        return $false
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Test-PrivateAddress {
    param([string]$Ip)
    return ($Ip -match '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)')
}

$cs = Get-CimInstance Win32_ComputerSystem
$domainJoined = [bool]$cs.PartOfDomain
$domain = $cs.Domain
if (-not $InternalHost -and $domainJoined) { $InternalHost = $domain }

$facts = @{ Adapter = $null; IPv4 = $null; Apipa = $false; Gateway = $null; GatewayOk = $false; DnsServers = @();
            DnsReachable = 0; PublicDns = $false; ExternalDns = $false; InternalDns = $null; DcLocator = $null;
            DcHost = $null; DcPortsOk = $null; HttpsOk = $false; Vpn = @() }

# --- 1. Adapter ---------------------------------------------------------------------------------------
$up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
$vpnPattern = 'VPN|TAP-|WireGuard|AnyConnect|Secure Client|GlobalProtect|PANGP|Fortinet|Juniper|Pulse|Zscaler|Cisco'
$facts.Vpn = @($up | Where-Object { $_.InterfaceDescription -match $vpnPattern -or $_.Name -match $vpnPattern } | Select-Object -ExpandProperty Name)
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
$primary = $null
if ($route) { $primary = $up | Where-Object ifIndex -eq $route.ifIndex | Select-Object -First 1 }
if (-not $primary) { $primary = $up | Where-Object { $_.InterfaceDescription -notmatch $vpnPattern } | Select-Object -First 1 }

if (-not $primary) {
    Add-Step 'Adapter' 'Active network adapter' 'Fail' 'No adapter is Up (Wi-Fi off, cable unplugged, airplane mode or driver issue)'
}
else {
    $facts.Adapter = $primary.Name
    Add-Step 'Adapter' 'Active network adapter' 'Pass' ("{0} - {1}, {2}, MAC {3}" -f $primary.Name, $primary.InterfaceDescription, $primary.LinkSpeed, $primary.MacAddress)
}
if ($facts.Vpn.Count -gt 0) { Add-Step 'Adapter' 'VPN adapter' 'Info' "Connected: $($facts.Vpn -join ', ')" }

# --- 2. IP configuration --------------------------------------------------------------------------------
if ($primary) {
    $ipc = Get-NetIPConfiguration -InterfaceIndex $primary.ifIndex -ErrorAction SilentlyContinue
    $ipv4 = @($ipc.IPv4Address | Select-Object -ExpandProperty IPAddress)
    $wmi = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$($primary.ifIndex)" -ErrorAction SilentlyContinue
    $dhcp = $false
    if ($wmi) { $dhcp = [bool]$wmi.DHCPEnabled }

    if ($ipv4.Count -eq 0) {
        Add-Step 'IP' 'IPv4 address' 'Fail' 'No IPv4 address on the adapter'
    }
    else {
        $facts.IPv4 = $ipv4[0]
        if ($facts.IPv4 -like '169.254.*') {
            $facts.Apipa = $true
            Add-Step 'IP' 'IPv4 address' 'Fail' "$($facts.IPv4) is APIPA - the device did not get a DHCP lease"
        }
        else {
            $mode = 'static'
            if ($dhcp) { $mode = 'DHCP' }
            $prefix = @($ipc.IPv4Address)[0].PrefixLength
            Add-Step 'IP' 'IPv4 address' 'Pass' "$($facts.IPv4)/$prefix ($mode)"
        }
    }
    if ($dhcp -and $wmi -and $wmi.DHCPServer) {
        Add-Step 'IP' 'DHCP lease' 'Info' ("Server {0}, obtained {1}, expires {2}" -f $wmi.DHCPServer, $wmi.DHCPLeaseObtained, $wmi.DHCPLeaseExpires)
    }

    # --- 3. Gateway -------------------------------------------------------------------------------------
    if ($route) {
        $facts.Gateway = $route.NextHop
        $facts.GatewayOk = Test-Connection -ComputerName $facts.Gateway -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($facts.GatewayOk) { Add-Step 'Gateway' 'Default gateway' 'Pass' "$($facts.Gateway) answers ping" }
        else { Add-Step 'Gateway' 'Default gateway' 'Warn' "$($facts.Gateway) does not answer ping (may be filtered)" }
    }
    else { Add-Step 'Gateway' 'Default gateway' 'Fail' 'No default route' }

    # --- 4. DNS servers ---------------------------------------------------------------------------------
    $facts.DnsServers = @(Get-DnsClientServerAddress -InterfaceIndex $primary.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ServerAddresses)
    if ($facts.DnsServers.Count -eq 0) { Add-Step 'DNS' 'DNS servers configured' 'Fail' 'No DNS servers on the adapter' }
    else {
        # Send a real query to each server (UDP with TCP fallback). Many home routers answer DNS only over UDP,
        # so a TCP-53 port probe alone would report false failures.
        $probeName = $ExternalHost
        if ($domainJoined) { $probeName = $domain }
        foreach ($d in $facts.DnsServers) {
            $ok = $false; $how = ''
            try {
                $null = Resolve-DnsName -Name $probeName -Server $d -DnsOnly -QuickTimeout -ErrorAction Stop
                $ok = $true; $how = "answers queries ($probeName)"
            }
            catch {
                if ($_.Exception.Message -match 'does not exist|NXDOMAIN|9003') { $ok = $true; $how = "reachable but cannot resolve $probeName" }
                elseif (Test-TcpPort -HostName $d -Port 53) { $ok = $true; $how = 'TCP 53 open but the query failed' }
                else { $how = 'no response (UDP/TCP 53)' }
            }
            if ($ok) { $facts.DnsReachable++ }
            $tag = ''
            if (-not (Test-PrivateAddress $d)) { $tag = ' [public resolver]'; $facts.PublicDns = $true }
            $res = 'Fail'
            if ($ok) { $res = 'Pass' }
            Add-Step 'DNS' "DNS server $d" $res "$how$tag"
        }
        if ($domainJoined -and $facts.PublicDns) {
            Add-Step 'DNS' 'DNS server type' 'Warn' 'Domain-joined device is using a public resolver - internal names will not resolve'
        }
    }
}

# --- 5. Name resolution --------------------------------------------------------------------------------
try {
    $ext = Resolve-DnsName -Name $ExternalHost -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object Type -eq 'A' | Select-Object -First 1
    $facts.ExternalDns = $true
    Add-Step 'Resolution' "Resolve $ExternalHost" 'Pass' "-> $($ext.IPAddress)"
}
catch { Add-Step 'Resolution' "Resolve $ExternalHost" 'Fail' $_.Exception.Message }

if ($InternalHost) {
    try {
        $int = Resolve-DnsName -Name $InternalHost -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
        $facts.InternalDns = $true
        $ipText = ''
        if ($int) { $ipText = "-> $($int.IPAddress)" }
        Add-Step 'Resolution' "Resolve $InternalHost" 'Pass' $ipText
    }
    catch { $facts.InternalDns = $false; Add-Step 'Resolution' "Resolve $InternalHost" 'Fail' $_.Exception.Message }
}
else { Add-Step 'Resolution' 'Internal name' 'Skip' 'Device is not domain-joined; pass -InternalHost to test one' }

if ($domainJoined) {
    $srv = "_ldap._tcp.dc._msdcs.$domain"
    try {
        $dcs = @(Resolve-DnsName -Name $srv -Type SRV -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object Type -eq 'SRV')
        $facts.DcLocator = $true
        $facts.DcHost = $dcs[0].NameTarget
        Add-Step 'Resolution' 'AD DC locator (SRV)' 'Pass' ("{0} DC(s): {1}" -f $dcs.Count, (($dcs | Select-Object -ExpandProperty NameTarget) -join ', '))
    }
    catch { $facts.DcLocator = $false; Add-Step 'Resolution' 'AD DC locator (SRV)' 'Fail' "$srv not found - the device cannot locate a domain controller" }
}

# --- 6. Service ports ----------------------------------------------------------------------------------
if ($facts.DcHost) {
    $closed = @()
    foreach ($port in $DcPorts) { if (-not (Test-TcpPort -HostName $facts.DcHost -Port $port)) { $closed += $port } }
    $facts.DcPortsOk = ($closed.Count -eq 0)
    if ($facts.DcPortsOk) { Add-Step 'Services' "DC ports $($DcPorts -join '/')" 'Pass' "$($facts.DcHost) reachable on all ports" }
    else { Add-Step 'Services' "DC ports $($DcPorts -join '/')" 'Fail' "$($facts.DcHost) closed/filtered: $($closed -join ', ')" }
}
try {
    $resp = Invoke-WebRequest -Uri "https://$ExternalHost" -Method Head -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    $facts.HttpsOk = $true
    Add-Step 'Services' "HTTPS to $ExternalHost" 'Pass' "HTTP $($resp.StatusCode)"
}
catch {
    $code = $null
    if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code) { $facts.HttpsOk = $true; Add-Step 'Services' "HTTPS to $ExternalHost" 'Pass' "HTTP $code (server reachable)" }
    else { Add-Step 'Services' "HTTPS to $ExternalHost" 'Fail' $_.Exception.Message }
}
$proxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy([uri]"https://$ExternalHost")
if ($proxy.Host -ne $ExternalHost) { Add-Step 'Services' 'Proxy' 'Info' "System proxy in use: $proxy" }

# --- 7. Verdict -------------------------------------------------------------------------------------------
$verdict = 'Network path looks healthy - the issue is likely application- or account-specific.'
$kb = 'Check the application KB (e.g. KB0014 for Outlook) or account status (KB0001)'
if (-not $facts.Adapter) { $verdict = 'No active network adapter.'; $kb = 'Check Wi-Fi/airplane mode, cable, Device Manager driver; escalate hardware to Desktop Support' }
elseif ($facts.Apipa) { $verdict = 'DHCP failure: the device self-assigned 169.254.x.x.'; $kb = 'KB0005 - if several users are affected, escalate to Contoso Network Operations as a potential major incident' }
elseif (-not $facts.Gateway) { $verdict = 'No default gateway configured.'; $kb = 'KB0005 - check DHCP options / static configuration' }
elseif ($facts.DnsServers.Count -gt 0 -and $facts.DnsReachable -eq 0) { $verdict = 'DNS servers are unreachable.'; $kb = 'KB0004 - verify DNS server addresses; escalate to Network Operations if correct' }
elseif ($facts.InternalDns -eq $false -and $facts.ExternalDns) { $verdict = 'Internal names fail while internet names resolve - DNS misconfiguration (often a public resolver set manually or by a VPN/app).'; $kb = 'KB0004 - reset the adapter DNS to DHCP, flush the cache' }
elseif (-not $facts.ExternalDns -and $facts.InternalDns -ne $true) { $verdict = 'Name resolution is failing.'; $kb = 'KB0004' }
elseif ($facts.DcLocator -eq $false) { $verdict = 'The device cannot locate a domain controller (SRV lookup failed).'; $kb = 'KB0004 / KB0008 - check DNS servers point to the DC' }
elseif ($facts.DcPortsOk -eq $false) { $verdict = 'Domain controller reachable by name but some AD ports are blocked.'; $kb = 'Escalate to Contoso Infrastructure Ops / Network Operations with this output' }
elseif (-not $facts.HttpsOk) { $verdict = 'Internal network OK but HTTPS to the internet fails - proxy, firewall or upstream outage.'; $kb = 'KB0006 (if on VPN) - check proxy settings, test another site' }

$summary = [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    CollectedAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    Verdict      = $verdict
    NextStep     = $kb
    Steps        = $steps.ToArray()
}

switch ($Format) {
    'Object' { return $summary }
    'Json'   { $summary | ConvertTo-Json -Depth 5 }
    default {
        Write-Host ''
        Write-Host "Network triage - $env:COMPUTERNAME ($(if ($domainJoined) { "domain $domain" } else { 'not domain-joined' }))" -ForegroundColor Cyan
        Write-Host ('{0,-11} {1,-34} {2,-5} {3}' -f 'LAYER', 'TEST', 'RESULT', 'DETAIL')
        foreach ($s in $steps) {
            $color = @{ Pass = 'Green'; Fail = 'Red'; Warn = 'Yellow'; Info = 'Gray'; Skip = 'DarkGray' }[$s.Result]
            $detail = $s.Detail
            if ($detail.Length -gt 90) { $detail = $detail.Substring(0, 87) + '...' }
            Write-Host ('{0,-11} {1,-34} {2,-5} {3}' -f $s.Layer, $s.Test, $s.Result, $detail) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host "Verdict:   $verdict" -ForegroundColor Yellow
        Write-Host "Next step: $kb"
        Write-Host ''
        Write-Host 'Ticket note (paste into work notes):' -ForegroundColor Cyan
        $fails = @($steps | Where-Object { $_.Result -in 'Fail', 'Warn' } | ForEach-Object { "$($_.Test): $($_.Detail)" })
        if ($fails.Count -eq 0) { $fails = @('No failed checks') }
        Write-Host "Ran Invoke-NetworkTriage.ps1 on $env:COMPUTERNAME at $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Verdict: $verdict Findings: $($fails -join ' | ')"
    }
}
