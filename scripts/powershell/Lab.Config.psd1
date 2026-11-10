#
# Lab.Config.psd1 - single source of configuration for the lab-build, helpdesk and lab-faults scripts.
# Change values here (not inside scripts) if you want a different domain name, subnet or OU layout.
# See docs/01-lab-design.md for the reasoning behind each value.
#
@{
    Company          = 'Contoso Financial'
    DomainFqdn       = 'corp.contoso.internal'
    NetBiosName      = 'CONTOSO'
    DomainDN         = 'DC=corp,DC=contoso,DC=internal'
    RootOU           = 'Contoso'
    Departments      = @('Finance', 'HR', 'IT', 'Sales', 'Operations')

    DomainController = @{
        Name         = 'DC01'
        IPv4         = '10.10.10.10'
        PrefixLength = 24
        Gateway      = '10.10.10.2'
    }

    Monitoring       = @{
        Name  = 'MON01'
        IPv4  = '10.10.10.20'
        Alias = 'zabbix'
    }

    Dns              = @{
        Forwarders       = @('10.10.10.2', '1.1.1.1')
        ReverseNetworkId = '10.10.10.0/24'
        ReverseZoneName  = '10.10.10.in-addr.arpa'
        NtpPeers         = 'time.windows.com,0x8 pool.ntp.org,0x8'
    }

    Dhcp             = @{
        ScopeName  = 'CORP-CLIENTS'
        ScopeId    = '10.10.10.0'
        StartRange = '10.10.10.100'
        EndRange   = '10.10.10.200'
        SubnetMask = '255.255.255.0'
        LeaseDays  = 8
        Router     = '10.10.10.2'
    }

    Shares           = @{
        LocalRoot       = 'C:\Shares'
        DepartmentsName = 'Departments'
        HomeName        = 'Home$'
        HomeDrive       = 'H:'
    }

    Groups           = @{
        AllStaff      = 'GG-AllStaff'
        Managers      = 'GG-Managers'
        HelpDeskTier1 = 'GG-HelpDesk-Tier1'
        HelpDeskTier2 = 'GG-HelpDesk-Tier2'
    }

    Accounts         = @{
        DomainAdmin     = 'adm.tech'
        Tier1           = 'hd.tier1'
        Tier2           = 'hd.tier2'
        ServiceAccount  = 'svc-scanner'
        ControlTestSeed = 'legacy.contractor'
    }

    # Where help desk scripts write audit trails and evidence (created on first use).
    AuditLogPath     = 'C:\HelpDeskLogs\helpdesk-audit.csv'
    EvidencePath     = 'C:\HelpDeskLogs\Evidence'
    GpoBackupPath    = 'C:\GPOBackups'

    # Fault injection safety: Invoke-LabFault.ps1 refuses to run unless the machine is in this domain.
    LabSafetyDomain  = 'corp.contoso.internal'
    FaultStatePath   = 'C:\ProgramData\ContosoLab\fault-state.json'
}
