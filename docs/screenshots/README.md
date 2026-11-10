# Screenshots (portfolio evidence)

Capture these while you build and operate the lab, save them here with the file names below, then uncomment
the image links in the main README. Blur passwords, recovery keys and any real personal data.

| File | What to capture | From |
|---|---|---|
| `aduc-ou-tree.png` | ADUC with the Contoso OU tree and a department OU open | Build Phase 1 |
| `gpmc-linked-gpos.png` | GPMC showing the five CON-* GPOs linked to their OUs | Build Phase 1 |
| `dhcp-scope.png` | DHCP console - scope CORP-CLIENTS with leases | Build Phase 1-2 |
| `fgpp.png` | `Get-ADFineGrainedPasswordPolicy -Filter *` output | Build Phase 1 |
| `gpresult-laptop.png` | `gpresult /r` on LT-WIN-001 | Build Phase 2 |
| `compliance-green.png` | `Test-EndpointCompliance.ps1` with all controls passing | Build Phase 2 |
| `bitlocker-key-in-ad.png` | `Get-BitLockerRecoveryKey.ps1` output (key blurred) | Endpoint management |
| `laps-password.png` | `Get-LapsADPassword` run as hd.tier2 (password blurred) | Endpoint management |
| `lockout-source.png` | `Get-AccountLockoutInfo.ps1` showing the event 4740 caller computer | Scenario 1 |
| `network-triage-dns.png` | `Invoke-NetworkTriage.ps1` verdict during DnsMisconfig | Scenario 2 |
| `zabbix-dashboard.png` | Zabbix dashboard with the DHCP problem active | Scenario 4 |
| `zabbix-to-servicenow.png` | The automatically created ServiceNow incident (number, priority, group) | Scenario 4 |
| `servicenow-incident-notes.png` | A resolved incident with structured work notes and a linked KB | Any scenario |
| `servicenow-problem.png` | Problem record linked to its incidents | Problem exercise |
| `servicenow-change.png` | Normal change with CAB approval | Change exercise |
| `ticket-metrics-dashboard.png` | `reports/ticket-metrics-dashboard.html` (90-day view) | Metrics |
| `access-review.png` | Access review HTML report | SOP-008 exercise |
