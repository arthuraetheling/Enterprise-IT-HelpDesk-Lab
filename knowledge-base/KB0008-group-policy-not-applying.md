# KB0008 · Group Policy not applying

| Field | Value |
|---|---|
| KB ID | KB0008 |
| Applies to | Domain-joined Windows 11 laptops in `OU=Workstations` and users in `OU=Users,OU=Contoso` (`corp.contoso.internal`) |
| Category | Software › OS |
| Audience | Tier 1 (Contoso Service Desk) → Tier 2 for elevated checks |
| Owner | Contoso Infrastructure Ops (Group Policy owner) |
| Last reviewed | 2026-11 |
| Typical priority | P4 (settings missing, user can work) · P3 (user cannot work, e.g. no S: drive) |
| Related scripts | [`Invoke-EndpointRemediation.ps1`](../scripts/powershell/endpoint/Invoke-EndpointRemediation.ps1) (`-Action GpUpdate`), [`Test-EndpointCompliance.ps1`](../scripts/powershell/endpoint/Test-EndpointCompliance.ps1) |
| Related scenario | `WrongOU` — on DC01: `.\Invoke-LabFault.ps1 -Scenario WrongOU -ComputerName LT-WIN-001` ([lab scenarios](../docs/06-lab-scenarios.md)) |

## Expected policies

| Scope | GPO | Linked to |
|---|---|---|
| Computer | `CON-C-Workstation-Baseline`, `CON-C-Workstation-BitLocker`, `CON-C-Workstation-LAPS` | `OU=Workstations,OU=Computers,OU=Contoso` |
| User (all staff) | `CON-U-Standard-User` (screen-saver lock, **S:** drive) | `OU=Users,OU=Contoso` |
| User (Finance) | `CON-U-Finance-USB-Deny` | `OU=Finance,OU=Users,OU=Contoso` |

## Symptoms

- No *"Authorized use only"* logon banner; the screen does not lock after 15 minutes; S: is missing.
- A Finance user can still open a USB stick.
- `Test-EndpointCompliance.ps1` fails the screen-lock or LAPS checks.
- `gpupdate /force` reports errors, or reports success but nothing changes.
- System log shows **GroupPolicy** errors (for example event IDs 1030 or 1058).

## Likely causes

| Cause | Clue |
|---|---|
| Computer object in the wrong OU (e.g. `OU=Staging`, which has no baseline GPOs) | Computer DN in `gpresult` is not under `OU=Workstations` |
| User object outside `OU=Users,OU=Contoso` | No `CON-U-*` GPOs in the user section |
| Not refreshed yet | Background refresh runs every 90 minutes (+ up to 30 random); some settings apply only at sign-in or restart |
| Security filtering / permissions | `Filtering: Denied (Security)` — a GPO filtered to a group must still grant **Read** to Authenticated Users or Domain Computers |
| WMI filter evaluates false | `Filtering: Denied (WMI Filter)` |
| Link disabled or GPO section disabled | `Filtering: Disabled (Link)` or `Not Applied (Empty)` |
| Another GPO with higher precedence wins | The HTML report shows a different *Winning GPO* for the setting |
| Device cannot reach a DC | DNS ([KB0004](KB0004-dns-resolution-failure.md)), time ([KB0010](KB0010-kerberos-clock-skew.md)) or trust ([KB0009](KB0009-trust-relationship-failed.md)) problems |

> **Loopback processing** is not used in this lab. If user settings follow the *computer* instead of the user
> (kiosks, shared PCs, remote desktop hosts), look for *Configure user Group Policy loopback processing mode*
> (Merge/Replace) in a computer GPO.

## Quick checks

```powershell
gpresult /r /scope:user                          # no admin needed
gpresult /r /scope:computer                      # elevated prompt
gpresult /h "$env:PUBLIC\gpreport.html" /f       # full report incl. the winning GPO for every setting
```

Read: **Applied Group Policy Objects**, *The following GPOs were not applied because they were filtered out* (with
the reason), **Group Policy was applied from** (should be `DC01.corp.contoso.internal`), **Last time Group Policy
was applied**, and the computer's distinguished name.

On DC01 or an RSAT workstation:

```powershell
Get-ADComputer LT-WIN-001 | Select-Object Name, DistinguishedName
# expected: CN=LT-WIN-001,OU=Workstations,OU=Computers,OU=Contoso,DC=corp,DC=contoso,DC=internal

Get-GPInheritance -Target "OU=Workstations,OU=Computers,OU=Contoso,DC=corp,DC=contoso,DC=internal" |
  Select-Object -ExpandProperty GpoLinks | Select-Object DisplayName, Enabled, Enforced, Order
Get-GPPermission -Name "CON-C-Workstation-Baseline" -All |
  Select-Object @{ n = 'Trustee'; e = { $_.Trustee.Name } }, Permission
```

Detailed processing log on the laptop: *Event Viewer › Applications and Services Logs › Microsoft › Windows ›
GroupPolicy › Operational*.

## Resolution (Tier 1)

**1. Refresh policy**, then sign out/in (user settings) or restart (computer settings) if prompted:

```powershell
gpupdate /force
# or: .\Invoke-EndpointRemediation.ps1 -Action GpUpdate
```

**2. Wrong OU** → escalate to Contoso Identity & Access (AD object change). Reference command for the resolver,
followed by `gpupdate /force` and a restart on the laptop:

```powershell
Move-ADObject -Identity (Get-ADComputer LT-WIN-001).DistinguishedName `
  -TargetPath "OU=Workstations,OU=Computers,OU=Contoso,DC=corp,DC=contoso,DC=internal"
```

**3. Filtering, permission, link or setting problems** in the GPO itself → Contoso Infrastructure Ops. GPO edits are
made only under a change record.

**4. Errors contacting a domain controller** → work through [KB0004](KB0004-dns-resolution-failure.md),
[KB0010](KB0010-kerberos-clock-skew.md) and [KB0009](KB0009-trust-relationship-failed.md).

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| Computer or user object in the wrong OU | Contoso Identity & Access | P4 (P3 if the user cannot work) |
| GPO link, filter or settings wrong, or many devices affected | Contoso Infrastructure Ops — normal change | P3; P2 if the security baseline is missing fleet-wide |
| Processing errors on one device after DNS, time and trust are ruled out | Contoso Desktop Support | P3 |

Attach: `gpresult /r` for both scopes, the HTML report, the computer DN, relevant GroupPolicy event IDs and the
`Test-EndpointCompliance.ps1` result.

## Verification

- `gpresult /r` lists the three `CON-C-*` GPOs (computer) and `CON-U-Standard-User` (+ `CON-U-Finance-USB-Deny` for
  Finance users) under *Applied Group Policy Objects*.
- The logon banner appears at the next sign-in; the screen locks after 15 minutes idle; S: is mapped.
- `.\Test-EndpointCompliance.ps1` passes the screen-lock and LAPS checks.

## Prevention

- New domain joins land in `OU=Workstations` automatically (`redircmp`); never leave production devices in `OU=Staging`.
- Every GPO edit goes through change control and is tested on a pilot device first (control BC-07).
- Run the compliance check regularly so drift is found by IT, not by an auditor.

## Ticket note example

```text
INC0010034 | Workstation baseline not applied | LT-WIN-001 (emma.carter) | P4
Issue: Compliance report flagged LT-WIN-001: no screen lock after 15 min, no logon banner, LAPS check failed.
Steps taken:
  1. gpresult /r /scope:computer (elevated, via Tier 2): only Default Domain Policy applied;
     computer DN = CN=LT-WIN-001,OU=Staging,OU=Computers,OU=Contoso,...
  2. Get-GPInheritance confirms OU=Staging has no CON-C-* links (by design).
  3. Escalated to Contoso Identity & Access; object moved back to OU=Workstations at 14:10.
  4. gpupdate /force and restart.
Result: gpresult shows CON-C-Workstation-Baseline, -BitLocker and -LAPS applied; banner shown at sign-in;
        Test-EndpointCompliance.ps1 passes screen-lock and LAPS checks.
Next action: Resolve. Asked IAM to record why the object was moved (no change record found). KB0008 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
