# KB0012 · Print job stuck in the queue / printer offline

| Field | Value |
|---|---|
| KB ID | KB0012 |
| Applies to | Windows 11 laptops printing to network printers over Standard TCP/IP ports; Print Spooler service |
| Category | Printing › print queue |
| Audience | Tier 1 (Contoso Service Desk) — admin steps by Tier 2 |
| Owner | Contoso Desktop Support |
| Last reviewed | 2026-11 |
| Typical priority | P4 (another printer is available) · P3 (no alternative, deadline today) · P2/P3 if a department printer is down for everyone |
| Related scripts | [`Invoke-EndpointRemediation.ps1`](../scripts/powershell/endpoint/Invoke-EndpointRemediation.ps1) (`-Action RestartSpooler`) |
| Related scenario | `SpoolerStuck` — on LT-WIN-001: `.\Invoke-LabFault.ps1 -Scenario SpoolerStuck` (printer on the dead IP `10.10.10.250`) ([lab scenarios](../docs/06-lab-scenarios.md)) |

## Symptoms

- A document stays in the queue as **Error – Printing** or **Printing**, nothing comes out, and later jobs wait behind it.
- The printer shows **Offline**.
- A job cannot be cancelled — it stays at *Deleting*.
- Opening printer settings fails with **"Operation could not be completed (error 0x000006BA)"** or *"The print
  spooler service is not running."*

## Likely causes

| Cause | Clue |
|---|---|
| Printer off, out of paper/toner, jammed | Error on the printer panel; nobody can print |
| Printer IP changed or unreachable | `Test-NetConnection <IP> -Port 9100` fails; port address ≠ printer's real IP |
| One corrupt or very large job blocks the queue | Top job in error, the others waiting |
| Print Spooler hung or stopped | Error 0x000006BA; printer list empty |
| Queue paused or set to *Use Printer Offline* | Queue window title shows *Paused* / *Offline* |
| Driver problem | Garbled output, or the spooler crashes when printing from one application |
| Unexpected default printer | Jobs go to another printer — *Let Windows manage my default printer* is on |

## Quick checks (no admin needed)

1. Can **other people** print to the same printer? Any message on the printer's panel?
2. Open the queue: *Settings › Bluetooth & devices › Printers & scanners › (printer) › Open print queue*.
3. Collect the facts:

```powershell
Get-Printer | Select-Object Name, PrinterStatus, PortName, JobCount
Get-PrintJob -PrinterName "<printer name>" | Select-Object Id, DocumentName, JobStatus, SubmittedTime, Size
Get-PrinterPort -Name "<port name>" | Select-Object Name, PrinterHostAddress, PortNumber
Test-NetConnection <printer IP> -Port 9100      # 9100 = raw printing port used by most network printers
```

## Resolution (Tier 1)

**1. Printer-side problems first** — power, paper, toner, jams. If the printer is down for everyone, raise **one**
incident for the printer instead of fixing laptops one by one.

**2. Cancel the stuck job** — in the queue window, *Printer › Cancel All Documents* (or right-click the job ›
*Cancel*). PowerShell:

```powershell
Get-PrintJob -PrinterName "<printer name>" | Remove-PrintJob
```

**3. Paused or offline queue** — in the queue window, open the *Printer* menu and clear **Pause Printing** and
**Use Printer Offline**.

**4. Job will not clear → restart the spooler and empty the spool folder** *(admin — Tier 2 or elevated session)*:

```powershell
Stop-Service -Name Spooler -Force
Remove-Item -Path "$env:SystemRoot\System32\spool\PRINTERS\*" -Force
Start-Service -Name Spooler
# scripted alternative (preview first with -WhatIf):
.\Invoke-EndpointRemediation.ps1 -Action RestartSpooler -WhatIf
.\Invoke-EndpointRemediation.ps1 -Action RestartSpooler
```

**5. Printer unreachable** — compare the IP on the printer's panel or configuration page with the port's
`PrinterHostAddress`. A wrong or retired IP means a stale queue: remove it and add the current printer from the
approved printer list (*Printer properties › Ports* to correct a port needs admin).

**6. Driver problems** — remove and re-add the printer; driver clean-up in Print Management
(`printmanagement.msc`) is a Tier 2 task.

**7. Wrong default printer** — *Settings › Bluetooth & devices › Printers & scanners*, turn off **Let Windows
manage my default printer**, then set the correct default.

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| Printer unreachable for everyone, or IP conflict | Contoso Network Operations | P3 (P2 if the department cannot work) |
| Printer hardware fault (jams, fuser, error codes) | Contoso Desktop Support (vendor service call) | P3/P4 |
| Spooler crashes repeatedly or driver issues | Contoso Desktop Support | P3 |

Attach: printer name and IP, `Get-Printer` / `Get-PrintJob` / `Get-PrinterPort` output, the `Test-NetConnection`
result, the exact error text and who else is affected.

## Verification

- *Printers & scanners › (printer) › Print test page* prints successfully.
- `Get-PrintJob -PrinterName "<printer name>"` returns nothing; `Get-Service Spooler` shows *Running*.
- The user prints the original document.

## Prevention

- Network printers get DHCP reservations or static IPs, recorded in the CMDB.
- Install printers and drivers only from the approved list; remove queues for retired printers during refresh.
- Repeated stuck jobs from the same application → collect examples and raise a problem record.

## Ticket note example

```text
INC0010047 | Print jobs stuck | emma.carter (Finance) | P4
Issue: Emma's jobs to the Finance printer stay at "Error - Printing" on LT-WIN-001; colleagues printing fine.
Steps taken:
  1. Get-PrintJob: 3 jobs queued, top job in error. Get-PrinterPort: PrinterHostAddress = 10.10.10.250.
  2. Test-NetConnection 10.10.10.250 -Port 9100 -> TcpTestSucceeded False. Asset record: printer at that IP was retired;
     Emma's laptop still had the old queue.
  3. Cancel All Documents failed (stuck at Deleting); Tier 2 ran Invoke-EndpointRemediation.ps1 -Action RestartSpooler.
  4. Removed the stale queue; added the current Finance printer from the approved list and set it as default.
Result: Test page printed; original document printed; queue empty.
Next action: Resolve. Suggested Desktop Support remove retired printer queues fleet-wide. KB0012 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
