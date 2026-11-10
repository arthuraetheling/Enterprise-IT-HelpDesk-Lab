#Requires -Version 5.1
<#
.SYNOPSIS
    Configures DNS, DHCP and time service on DC01 after promotion.

.DESCRIPTION
    Run on DC01 as CONTOSO\Administrator (elevated). Idempotent.
      DNS : DC points to itself, forwarders, reverse lookup zone, PTR for DC01, A/PTR for MON01,
            CNAME zabbix -> mon01, aging/scavenging.
      DHCP: installs the role, creates the DHCP security groups, authorizes the server in AD,
            creates scope CORP-CLIENTS with router / DNS server / DNS domain options.
      Time: DC01 (PDC emulator) syncs from external NTP peers; clients follow the domain hierarchy.

.EXAMPLE
    .\02-Configure-DnsDhcp.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Lab.Common.psm1') -Force
Assert-LabElevated
$cfg  = Get-LabConfig
$dc   = $cfg.DomainController
$zone = $cfg.DomainFqdn

Assert-LabModule -Name DnsServer

# --- DNS client on the DC itself --------------------------------------------------------------
Write-LabStep 'Pointing the DC DNS client at itself (primary) and loopback (secondary)'
$ifIndex = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $dc.IPv4).InterfaceIndex
if ($ifIndex -and $PSCmdlet.ShouldProcess("ifIndex $ifIndex", 'Set DNS servers')) {
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses @($dc.IPv4, '127.0.0.1')
    Write-LabOk "DNS client: $($dc.IPv4), 127.0.0.1"
}

# --- Forwarders --------------------------------------------------------------------------------
Write-LabStep 'Configuring DNS forwarders'
if ($PSCmdlet.ShouldProcess('DNS Server', "Forwarders $($cfg.Dns.Forwarders -join ', ')")) {
    Set-DnsServerForwarder -IPAddress $cfg.Dns.Forwarders -UseRootHint $true
    Write-LabOk "Forwarders: $($cfg.Dns.Forwarders -join ', ')"
}

# --- Reverse zone + records ------------------------------------------------------------------
Write-LabStep 'Creating reverse lookup zone and host records'
if (-not (Get-DnsServerZone -Name $cfg.Dns.ReverseZoneName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($cfg.Dns.ReverseZoneName, 'Add AD-integrated reverse zone')) {
        Add-DnsServerPrimaryZone -NetworkId $cfg.Dns.ReverseNetworkId -ReplicationScope Forest -DynamicUpdate Secure
        Write-LabOk "Reverse zone $($cfg.Dns.ReverseZoneName) created"
    }
}
else { Write-LabSkip "Reverse zone $($cfg.Dns.ReverseZoneName) exists" }

$dcLastOctet = $dc.IPv4.Split('.')[-1]
if (-not (Get-DnsServerResourceRecord -ZoneName $cfg.Dns.ReverseZoneName -Name $dcLastOctet -RRType Ptr -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess("$dcLastOctet PTR", 'Add PTR for DC01')) {
        Add-DnsServerResourceRecordPtr -ZoneName $cfg.Dns.ReverseZoneName -Name $dcLastOctet -PtrDomainName "$($cfg.DcFqdn)."
        Write-LabOk "PTR $($dc.IPv4) -> $($cfg.DcFqdn)"
    }
}

$monName = $cfg.Monitoring.Name.ToLowerInvariant()
if (-not (Get-DnsServerResourceRecord -ZoneName $zone -Name $monName -RRType A -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess("$monName.$zone", 'Add A + PTR')) {
        Add-DnsServerResourceRecordA -ZoneName $zone -Name $monName -IPv4Address $cfg.Monitoring.IPv4 -CreatePtr
        Write-LabOk "A $monName.$zone -> $($cfg.Monitoring.IPv4)"
    }
}
else { Write-LabSkip "A record $monName exists" }

$alias = $cfg.Monitoring.Alias
if (-not (Get-DnsServerResourceRecord -ZoneName $zone -Name $alias -RRType CName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess("$alias.$zone", "Add CNAME -> $monName.$zone")) {
        Add-DnsServerResourceRecordCName -ZoneName $zone -Name $alias -HostNameAlias "$monName.$zone"
        Write-LabOk "CNAME $alias.$zone -> $monName.$zone"
    }
}
else { Write-LabSkip "CNAME $alias exists" }

Write-LabStep 'Enabling DNS aging/scavenging (prevents stale records)'
if ($PSCmdlet.ShouldProcess('DNS Server', 'Enable scavenging (7d no-refresh / 7d refresh)')) {
    $sevenDays = New-TimeSpan -Days 7
    Set-DnsServerScavenging -ScavengingState $true -NoRefreshInterval $sevenDays -RefreshInterval $sevenDays `
        -ScavengingInterval $sevenDays -ApplyOnAllZones
    Write-LabOk 'Scavenging enabled'
}

# --- DHCP -------------------------------------------------------------------------------------
Write-LabStep 'Installing and authorizing DHCP'
if (-not (Get-WindowsFeature -Name DHCP).Installed) {
    if ($PSCmdlet.ShouldProcess('DHCP', 'Install-WindowsFeature')) {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
        Write-LabOk 'DHCP role installed'
    }
}
Assert-LabModule -Name DhcpServer

if ($PSCmdlet.ShouldProcess('DHCP', 'Create DHCP security groups, authorize in AD')) {
    Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue
    Restart-Service -Name DHCPServer
    $authorized = Get-DhcpServerInDC -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $dc.IPv4 }
    if (-not $authorized) {
        Add-DhcpServerInDC -DnsName $cfg.DcFqdn -IPAddress $dc.IPv4
        Write-LabOk "Authorized $($cfg.DcFqdn) in Active Directory"
    }
    else { Write-LabSkip 'DHCP server already authorized' }
    # Tell Server Manager that post-install configuration is complete (removes the yellow flag).
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2 -ErrorAction SilentlyContinue
}

Write-LabStep "Creating DHCP scope $($cfg.Dhcp.ScopeName)"
$scope = Get-DhcpServerv4Scope -ScopeId $cfg.Dhcp.ScopeId -ErrorAction SilentlyContinue
if (-not $scope) {
    if ($PSCmdlet.ShouldProcess($cfg.Dhcp.ScopeName, 'Add-DhcpServerv4Scope')) {
        Add-DhcpServerv4Scope -Name $cfg.Dhcp.ScopeName -StartRange $cfg.Dhcp.StartRange -EndRange $cfg.Dhcp.EndRange `
            -SubnetMask $cfg.Dhcp.SubnetMask -LeaseDuration (New-TimeSpan -Days $cfg.Dhcp.LeaseDays) -State Active
        Write-LabOk "Scope $($cfg.Dhcp.StartRange)-$($cfg.Dhcp.EndRange) created"
    }
}
else { Write-LabSkip "Scope $($cfg.Dhcp.ScopeId) exists (state: $($scope.State))" }

if ($PSCmdlet.ShouldProcess($cfg.Dhcp.ScopeId, 'Set options 003/006/015')) {
    Set-DhcpServerv4OptionValue -ScopeId $cfg.Dhcp.ScopeId -Router $cfg.Dhcp.Router `
        -DnsServer $dc.IPv4 -DnsDomain $cfg.DomainFqdn -Force
    Write-LabOk "Options: router $($cfg.Dhcp.Router), DNS $($dc.IPv4), domain $($cfg.DomainFqdn)"
}

# --- Time service -----------------------------------------------------------------------------
Write-LabStep 'Configuring the PDC emulator as the authoritative time source'
if ($PSCmdlet.ShouldProcess('w32time', "Sync from $($cfg.Dns.NtpPeers)")) {
    $null = & w32tm.exe /config "/manualpeerlist:$($cfg.Dns.NtpPeers)" /syncfromflags:manual /reliable:yes /update
    Restart-Service -Name w32time
    $null = & w32tm.exe /resync /nowait
    Write-LabOk 'w32time configured (check later with: w32tm /query /status)'
}

# --- Summary ------------------------------------------------------------------------------------
Write-LabStep 'Summary'
Get-DnsServerForwarder | Select-Object IPAddress, UseRootHint | Format-Table -AutoSize
Get-DhcpServerv4Scope | Select-Object ScopeId, Name, StartRange, EndRange, State, LeaseDuration | Format-Table -AutoSize
Get-DhcpServerv4OptionValue -ScopeId $cfg.Dhcp.ScopeId | Select-Object OptionId, Name, Value | Format-Table -AutoSize
Write-Host 'Next: 03-Build-ADStructure.ps1' -ForegroundColor Yellow
