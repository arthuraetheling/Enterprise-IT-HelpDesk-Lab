# KB0006 · VPN will not connect (or connects but internal resources fail)

| Field | Value |
|---|---|
| KB ID | KB0006 |
| Applies to | The corporate VPN client on Windows 11 and macOS laptops (vendor-neutral: SSL/TLS or IPsec clients) |
| Category | Network › vpn |
| Audience | Tier 1 (Contoso Service Desk) |
| Owner | Contoso Network Operations |
| Last reviewed | 2026-11 |
| Typical priority | P3 (one remote user cannot work) · P2 for a VIP · P1 if the VPN is down for everyone |
| Related | [KB0001](KB0001-account-lockout.md), [KB0002](KB0002-password-reset-identity-verification.md), [KB0003](KB0003-mfa-reregistration-new-phone.md), [KB0004](KB0004-dns-resolution-failure.md), [KB0010](KB0010-kerberos-clock-skew.md), [`Invoke-NetworkTriage.ps1`](../scripts/powershell/endpoint/Invoke-NetworkTriage.ps1) |
| Lab note | The lab has no VPN gateway; this article is for real-world triage. Practise the "connected but no internal DNS" branch with the `DnsMisconfig` scenario. |

## Symptoms

- The client reports *authentication failed*, *unable to reach the gateway/server*, or a *certificate* error.
- The tunnel connects, then drops every few minutes.
- Connected, but S:, H:, `\\DC01` and internal sites do not work.
- The VPN worked at home but fails at a hotel, airport or customer site.

## Likely causes

Work through them in this order — most VPN tickets are solved before step 4:

| # | Layer | Typical cause |
|---|---|---|
| 1 | Internet | No connectivity, or a hotel/airport **captive portal** not yet accepted |
| 2 | Time | Wrong clock or time zone → certificate and one-time-code failures |
| 3 | Identity | Expired or locked password, MFA prompt not received |
| 4 | Client | Outdated client, wrong gateway/profile, hung client service |
| 5 | Local network | Guest or hotel network blocks VPN traffic (IPsec uses UDP 500/4500; SSL VPNs use 443) |
| 6 | Internal access | Split tunnel or DNS not pushed → tunnel up but internal names fail |

## Quick checks

1. **Internet first.** Can the user open a public website?

```powershell
Test-NetConnection www.microsoft.com -Port 443
```

   On hotel or airport Wi-Fi, open a browser to any website to trigger the sign-in page; Windows may show
   *Action needed* on the network.

2. **Clock and time zone** correct on the laptop? (see [KB0010](KB0010-kerberos-clock-skew.md))
3. **Account state** — run on DC01 or an RSAT workstation:

```powershell
Get-ADUser marcus.reed -Properties Enabled, LockedOut, PasswordExpired |
  Select-Object Name, Enabled, LockedOut, PasswordExpired
```

4. **Exact error text** and a screenshot; client version (from the client's *About* screen).

## Resolution (Tier 1)

**1. No internet** → complete the captive portal, switch Wi-Fi network, or test with a **mobile hotspot**. If the
hotspot works, the local network is blocking VPN traffic — use the hotspot for now and note the location.

**2. Authentication errors** → locked out: [KB0001](KB0001-account-lockout.md); expired or forgotten:
[KB0002](KB0002-password-reset-identity-verification.md) (see its off-network notes); no MFA prompt:
[KB0003](KB0003-mfa-reregistration-new-phone.md).

**3. Client problems** → fully quit the client (system tray on Windows, menu bar on macOS), start it again, confirm
the correct gateway/profile is selected, then restart the laptop if needed. Update the client from the company
software portal if it is out of date.

**4. Connected but internal resources fail** → check that the VPN adapter received corporate DNS:

```powershell
Get-NetIPConfiguration                        # the VPN adapter should list 10.10.10.10 as DNS server
Resolve-DnsName dc01.corp.contoso.internal
.\Invoke-NetworkTriage.ps1 -InternalHost dc01.corp.contoso.internal
```

On macOS: `scutil --dns` (resolvers in use) and `netstat -rn` (routes through the tunnel).
*Split tunnel* means only corporate subnets go through the VPN; public sites go direct. If internal names fail,
corporate DNS is not being applied → [KB0004](KB0004-dns-resolution-failure.md), then escalate.

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| Several users cannot connect | Contoso Network Operations — parent incident | P2; P1 if all remote users → [SOP-005](../sops/SOP-005-major-incident-communications.md) |
| Valid, unlocked account and working MFA but authentication still fails | Contoso Network Operations (VPN authentication) | Same as ticket |
| Certificate errors, client crashes or missing profile | Contoso Desktop Support | P3 |
| Tunnel up but no internal DNS or routes | Contoso Network Operations | P3 |

Attach: user and device, location and network type (home, hotel, hotspot), exact error and screenshot, time of the
attempts, client version, `ipconfig /all`, `Invoke-NetworkTriage.ps1` output and the hotspot test result.

## Verification

- The client shows *Connected*; `Resolve-DnsName dc01.corp.contoso.internal` returns `10.10.10.10`.
- S: opens; disconnect and reconnect once to confirm it is stable.

## Prevention

- Test the VPN before travelling; keep the mobile-hotspot fallback in mind.
- Change an expiring password while still on-site — expired passwords are the top cause of remote lockouts.
- Keep the VPN client current through the software portal.

## Ticket note example

```text
INC0010027 | VPN cannot reach gateway | marcus.reed (Sales Manager) | P3
Issue: At a hotel, Marcus's VPN client reports "unable to reach the gateway" on LT-WIN-002.
Steps taken:
  1. Test-NetConnection www.microsoft.com -Port 443 failed; Windows showed "Action needed" on the hotel Wi-Fi.
  2. User opened a browser, accepted the hotel's terms page; public sites then loaded.
  3. VPN connected; Resolve-DnsName dc01.corp.contoso.internal -> 10.10.10.10; S: opened.
  4. Account check: PasswordExpired = False, but the password expires in 2 days.
Result: Connected and stable after one disconnect/reconnect test.
Next action: Resolve. Advised user to change his password today while connected (KB0002). KB0006 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
