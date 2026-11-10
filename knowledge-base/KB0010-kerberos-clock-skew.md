# KB0010 · Kerberos / clock skew errors (time synchronization)

| Field | Value |
|---|---|
| KB ID | KB0010 |
| Applies to | Domain-joined Windows 11 laptops; domain time hierarchy: DC01 (PDC emulator) ← `time.windows.com`, `pool.ntp.org` |
| Category | Software › OS |
| Audience | Tier 1 (Contoso Service Desk) → Tier 2 for elevated steps |
| Owner | Contoso Infrastructure Ops |
| Last reviewed | 2026-11 |
| Typical priority | P3 single device · P2/P1 if many devices or DC01 itself are affected |
| Related scripts | [`Invoke-EndpointRemediation.ps1`](../scripts/powershell/endpoint/Invoke-EndpointRemediation.ps1) (`-Action SyncTime`) |
| Related scenario | `ClockSkew` — on LT-WIN-001: `.\Invoke-LabFault.ps1 -Scenario ClockSkew` ([lab scenarios](../docs/06-lab-scenarios.md)) |

## Symptoms

- Sign-in fails with **"There is a time and/or date difference between the client and server."**
- S:, H: and other domain resources suddenly ask for credentials or deny access.
- Kerberos errors in the System log (clock-skew errors such as `KRB_AP_ERR_SKEW`).
- Websites show certificate date errors; one-time MFA codes are rejected.
- The laptop's clock visibly differs from the user's phone.

## Likely causes

| Cause | Notes |
|---|---|
| Windows Time service (`w32time`) stopped or disabled | The clock drifts with nothing correcting it |
| Clock set by hand | Often to "fix" a wrong time zone — which changes the real (UTC) time |
| Wrong time source | Laptop syncing from *Local CMOS Clock* instead of the domain hierarchy |
| Dead CMOS battery | Time resets after every power-off |
| Virtualization time sync (lab) | VMware Tools and Windows Time adjusting the same clock |
| DC01 time wrong | Affects **everyone** — infrastructure issue |

Kerberos tolerates at most **5 minutes** of difference between client and domain controller
(*Maximum tolerance for computer clock synchronization* in the Default Domain Policy).

## Quick checks

No admin needed:

```powershell
Get-Date
tzutil /g                                                                         # current time zone
w32tm /stripchart /computer:dc01.corp.contoso.internal /samples:3 /dataonly       # offset from DC01
Get-Service w32time | Select-Object Status, StartType
```

Elevated (Tier 2):

```powershell
w32tm /query /status
w32tm /query /source        # expected: DC01.corp.contoso.internal - not "Local CMOS Clock"
```

An offset of more than a few seconds is suspicious; more than 300 seconds breaks Kerberos.

## Resolution (Tier 1)

**1. Wrong time zone only?** *Settings › Time & language › Date & time › Time zone.* Changing the time zone does not
change the real (UTC) time, so it is safe — never move the clock by hand to compensate.

**2. Restart the time service and resync** *(elevated — Tier 2 or an elevated remote session):*

```powershell
Set-Service -Name w32time -StartupType Automatic
Start-Service w32time
w32tm /resync
# or: .\Invoke-EndpointRemediation.ps1 -Action SyncTime
```

If `w32tm /resync` reports *"The computer did not resync because no time data was available"*, reset the laptop to
the domain hierarchy and try again:

```powershell
w32tm /config /syncfromflags:domhier /update
Restart-Service w32time
w32tm /resync /rediscover
```

GUI alternative: *Settings › Time & language › Date & time › Sync now*.

**3. Refresh Kerberos tickets** once the clock is right: `klist purge`, then sign out and back in.

**4. Lab note:** a VM can also take time from the host through VMware Tools. DC01, as PDC emulator, should take time
only from its external NTP peers — do not let host sync fight Windows Time.

**5. Time resets after every shutdown** → hardware (CMOS battery) → Tier 2.

### Reference — domain-wide checks on DC01 (Infrastructure Ops)

```powershell
w32tm /monitor                   # offset of each DC
w32tm /query /configuration
# PDC emulator source configuration (change under a change record)
w32tm /config /manualpeerlist:"time.windows.com,0x8 pool.ntp.org,0x8" /syncfromflags:manual /reliable:yes /update
```

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| Fix needs admin rights (service, resync) | Contoso Desktop Support | P3 |
| Several devices skewed, or DC01 differs from internet time | Contoso Infrastructure Ops | P2 — authentication failures spread quickly |
| Clock resets after every power-off | Contoso Desktop Support (hardware) | P4 |

Attach: `w32tm /stripchart` output, `w32tm /query /source` and `/status` (if available), `w32time` service state and
the time zone.

## Verification

- `w32tm /stripchart /computer:dc01.corp.contoso.internal /samples:3 /dataonly` shows an offset under one second.
- `w32tm /query /source` shows DC01; the user signs in and opens S: without prompts; `klist` lists fresh tickets.

## Prevention

- Keep `w32time` running; standard users cannot change the system time — do not grant that right.
- Monitor time offset on DC01; correct the PDC emulator's source only under change control.
- Replace laptops whose clock resets on every boot.

## Ticket note example

```text
INC0010041 | Cannot open S: - clock 10 min fast | emma.carter (Finance) | P3
Issue: Since 11:20 S: and H: deny access on LT-WIN-001; laptop clock is ~10 minutes ahead of the user's phone.
Steps taken:
  1. tzutil /g = Eastern Standard Time (correct). w32tm /stripchart vs DC01: offset +600.4 s.
  2. Get-Service w32time: Stopped, StartType Disabled.
  3. Escalated for the admin step; Tier 2 ran Invoke-EndpointRemediation.ps1 -Action SyncTime
     (service set to Automatic, started, resync). w32tm /query /source = DC01.corp.contoso.internal.
  4. klist purge; user signed out and back in.
Result: Offset now +0.02 s; S: and H: open normally.
Next action: Resolve. Asked Desktop Support to check how the time service was disabled. KB0010 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
