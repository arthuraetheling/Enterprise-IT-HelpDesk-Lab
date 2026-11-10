# KB0004 · Internal names fail but the internet works (DNS resolution failure)

| Field | Value |
|---|---|
| KB ID | KB0004 |
| Applies to | Windows 11 laptops (`LT-WIN-###`) on the corporate LAN or VPN; internal DNS on DC01 (`10.10.10.10`), zone `corp.contoso.internal` |
| Category | Network › dns |
| Audience | Tier 1 (Contoso Service Desk) → Tier 2 for steps that need local admin |
| Owner | Contoso Network Operations |
| Last reviewed | 2026-11 |
| Typical priority | P3 single user · P2/P1 if many users are affected (DNS on DC01 down) |
| Related scripts | [`Invoke-NetworkTriage.ps1`](../scripts/powershell/endpoint/Invoke-NetworkTriage.ps1), [`Invoke-EndpointRemediation.ps1`](../scripts/powershell/endpoint/Invoke-EndpointRemediation.ps1) (`-Action FlushDns`) |
| Related scenario | `DnsMisconfig` — on LT-WIN-001: `.\Invoke-LabFault.ps1 -Scenario DnsMisconfig` ([lab scenarios](../docs/06-lab-scenarios.md)) |

## Symptoms

- Public websites open, but `\\DC01\Departments`, the S: and H: drives and internal tools do not.
- Explorer: **"Windows can't find '\\DC01\Departments'. Check the spelling and try again."**
- Slow sign-in, `gpupdate` errors, "We can't sign you in" messages for network resources.
- `nslookup dc01.corp.contoso.internal` fails (*Non-existent domain* or time-out) while `nslookup www.microsoft.com` works.

## Likely causes

| Cause | Why it breaks internal names only |
|---|---|
| Adapter DNS set manually to a public resolver (e.g. 1.1.1.1, 8.8.8.8) | The `corp.contoso.internal` zone exists only on DC01 — public DNS has never heard of it |
| VPN or third-party "privacy"/network software overrode DNS | Same effect, often only while the software is running |
| Stale or negative entries in the DNS client cache | A failed lookup is cached for a few minutes, even after the fault is fixed |
| Override in the `hosts` file | Points an internal name to a wrong or old address |
| DNS suffix missing | Short names (`dc01`) fail while the FQDN (`dc01.corp.contoso.internal`) works |
| DNS service on DC01 down or unreachable | Affects **everyone** — this is an outage, not a laptop problem |

## Quick checks

```powershell
ipconfig /all
```

Expected on a healthy laptop: **DHCP Enabled: Yes**, **DNS Servers: 10.10.10.10**, **Default Gateway: 10.10.10.2**,
connection-specific DNS suffix **corp.contoso.internal**.

```powershell
Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, ServerAddresses
Resolve-DnsName dc01.corp.contoso.internal                         # uses the laptop's configured DNS server
Resolve-DnsName dc01.corp.contoso.internal -Server 10.10.10.10     # asks DC01 directly
Test-NetConnection 10.10.10.10 -Port 53
```

| Result | Meaning |
|---|---|
| Fails normally, **works** with `-Server 10.10.10.10` | Laptop uses the wrong DNS server → Resolution step 2 |
| Fails both ways and port 53 fails | DC01 unreachable or DNS down → check other users, escalate |
| FQDN works, short name `dc01` fails | DNS suffix missing → check the suffix search list in `ipconfig /all` |
| Everything resolves but the app still fails | Stale cache → Resolution step 1 |

Capture a full layered check for the ticket (adapter → IP → gateway → DNS → ports → verdict):

```powershell
.\Invoke-NetworkTriage.ps1 -InternalHost dc01.corp.contoso.internal
```

## Resolution (Tier 1)

**1. Flush the DNS client cache.**

```powershell
ipconfig /flushdns
# or: .\Invoke-EndpointRemediation.ps1 -Action FlushDns
```

**2. Wrong DNS server on the adapter** *(needs local admin — Tier 2, or an elevated remote session).* GUI:
*Settings › Network & internet › Ethernet (or Wi-Fi) › DNS server assignment › Edit › Automatic (DHCP)*. PowerShell:

```powershell
Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object Name, InterfaceDescription
Set-DnsClientServerAddress -InterfaceAlias 'Ethernet0' -ResetServerAddresses   # use the name from the line above
ipconfig /renew
ipconfig /flushdns
```

**3. Check the hosts file** for internal names (editing it needs admin):

```powershell
Select-String -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Pattern '^\s*[^#\s]'
```

**4. VPN connected?** Disconnect and re-test. If internal names fail only while connected, the VPN is not pushing
corporate DNS → escalate to Network Operations ([KB0006](KB0006-vpn-connection-failure.md)).

**5. Ask how it changed.** A DNS server does not change by itself — note any VPN, "privacy" app or home-network
guide the user mentions.

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| Fix needs local admin (adapter settings, hosts file) | Contoso Desktop Support | Keep P3 |
| Several users affected, or DC01 does not answer on port 53 | Contoso Network Operations — one parent incident | P2; P1 if company-wide → [SOP-005](../sops/SOP-005-major-incident-communications.md) |
| VPN pushes the wrong DNS servers | Contoso Network Operations | P3 |
| Unapproved software keeps changing DNS | Contoso Desktop Support → problem record | P3/P4 |

Attach: `ipconfig /all`, both `Resolve-DnsName` results, the `Invoke-NetworkTriage.ps1` output and the time the
issue started.

## Verification

```powershell
Resolve-DnsName dc01.corp.contoso.internal                  # returns 10.10.10.10
Test-NetConnection dc01.corp.contoso.internal -Port 445     # TcpTestSucceeded : True
nltest /dsgetdc:corp.contoso.internal                       # locates DC01
```

- S: and H: reconnect; `gpupdate /force` completes without errors.

## Prevention

- Standard users cannot change adapter settings — keep it that way (no local admin for daily accounts).
- Only approved VPN and network software; anything that rewrites DNS goes through change control.
- Recurring cases with the same cause → link them and open a Problem record
  ([problem management](../itil/problem-management.md)).

## Ticket note example

```text
INC0010021 | Cannot reach S: drive, internet works | emma.carter (Finance) | P3
Issue: Since 10:05 Emma can browse the web but S:, H: and \\DC01 are unreachable on LT-WIN-001.
Steps taken:
  1. ipconfig /all: DNS Servers = 1.1.1.1 (static); DHCP Enabled = Yes for the IP address.
  2. Resolve-DnsName dc01.corp.contoso.internal failed; with -Server 10.10.10.10 it returned 10.10.10.10.
  3. Invoke-NetworkTriage.ps1 verdict: wrong DNS server; gateway and DC01 reachable. Output attached.
  4. Escalated to Contoso Desktop Support for the admin step; Tier 2 reset DNS to automatic (DHCP) and flushed the cache.
Result: dc01 resolves to 10.10.10.10; S: and H: reconnected; gpupdate /force successful.
Next action: Resolve. No change record explains the static DNS - flagged to the Desktop Support lead. KB0004 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md) · Process:
[incident management](../itil/incident-management.md)
