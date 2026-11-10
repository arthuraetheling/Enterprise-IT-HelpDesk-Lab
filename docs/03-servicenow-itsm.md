# 03 · ServiceNow ITSM Setup (Personal Developer Instance)

ServiceNow is the system of record for the lab: incidents, requests, problems, changes, knowledge and the
CMDB. A **Personal Developer Instance (PDI)** is free and includes the full ITSM suite.
Values (groups, categories, SLAs, numbering) come from [01-lab-design.md §8](01-lab-design.md#8-itsm-design-servicenow-personal-developer-instance).

> PDIs hibernate when idle and are reclaimed after a period of inactivity. Sign in regularly, and keep this
> page as your rebuild checklist. Menu labels below use the current "All" navigator - type the module name
> into the filter if a label differs in your release.

## 1. Get the instance

1. Sign up at **developer.servicenow.com** → *Request instance* (latest release).
2. Note the URL `https://devNNNNN.service-now.com` and the `admin` password from the developer portal.

## 2. People and groups

| Step | Where | What |
|---|---|---|
| Personas | *User Administration > Users > New* | `emma.carter`, `olivia.bennett`, `marcus.reed`, `priya.shah`, `daniel.kim`, `lucas.moreno` (user ID = AD sAMAccountName) |
| Analysts | same | `ava.thompson` (Tier 1), `omar.haddad` (Tier 2), `ryan.murphy` (Network) - role **itil** |
| Integration user | same | `svc.helpdesk.automation`, tick **Web service access only**, role **itil**, set a password |
| Groups | *User Administration > Groups > New* | Contoso Service Desk, Contoso Desktop Support, Contoso Identity & Access, Contoso Network Operations, Contoso Infrastructure Ops (add the analysts as members) |

Optional bulk load: *System Import Sets > Load Data* with `data/users.csv`, then a transform map to
**sys_user** (user_name = `first.last`, first_name, last_name, title, department).

## 3. Incident form configuration

1. **Categories** - open any incident, right-click the *Category* label > **Configure Choices**, add
   `account` (Account & Access), `email` (Email & Collaboration), `mobile` (Mobile Device),
   `printing` (Printing), `security` (Security). Add subcategories with the matching *dependent value*
   (for example `account lockout` depends on `account`).
2. **Priority matrix** - *Priority Lookup Rules* (Impact × Urgency → Priority). The out-of-box rules already
   match §8.3 (1/1 = P1 … 3/3 = P5); confirm, don't change.
3. **Assignment rules** - *Assignment Data Lookup* or *System Policy > Rules > Assignment*:
   `category = network` → Contoso Network Operations; `category = account` → Contoso Identity & Access;
   everything else → Contoso Service Desk.

## 4. SLA definitions

*Service Level Management > SLA Definitions > New* - one **resolution** and one **response** SLA per priority:

| Name | Duration | Start condition | Pause condition | Stop condition |
|---|---|---|---|---|
| Contoso P1 resolution | 4 h | Priority = 1 - Critical | State = On Hold **and** On hold reason = Awaiting Caller | State is Resolved or Closed |
| Contoso P2 resolution | 8 h | Priority = 2 - High | same | same |
| Contoso P3 resolution | 24 h | Priority = 3 - Moderate | same | same |
| Contoso P4 resolution | 72 h | Priority = 4 - Low | same | same |
| Contoso P5 resolution | 120 h | Priority = 5 - Planning | same | same |
| Contoso Px response | 15 m / 30 m / 2 h / 8 h / 24 h | Priority = x | - | Assigned to is not empty, or State changes from New |

Schedule: 24 × 7 (lab simplification). Add a *50% / 75%* SLA warning notification to the assignment group
lead - this implements the "75% of SLA → notify lead" escalation rule.

## 5. Knowledge base

1. *Knowledge > Administration > Knowledge Bases > New*: **Contoso IT Knowledge** (owner: you; managers:
   Contoso Service Desk).
2. Create articles from `knowledge-base/KB0001`…`KB0017` (paste the rendered GitHub view; keep the KB number in
   the title). Publish KB0001, KB0004, KB0005, KB0011 first - they back the most common scenarios.
3. On every resolved incident, use **Attach knowledge** so the KB link rate KPI ([07](07-metrics-reporting.md)) is real.

## 6. CMDB

Either create CIs by hand (*Configuration > Servers > Windows* for DC01, *Linux* for MON01,
*Configuration > Computers* for LT-WIN-001) or push them from discovery:

```powershell
$cred = Get-Credential svc.helpdesk.automation
.\scripts\powershell\endpoint\Get-EndpointInventory.ps1 -OutputPath C:\Lab\inventory
.\scripts\powershell\integration\Sync-InventoryToCmdb.ps1 -InventoryPath C:\Lab\inventory `
    -InstanceUrl https://devNNNNN.service-now.com -Credential $cred
```

Add relationships in the CI relationship editor: LT-WIN-001 *Depends on* DC01 (authentication, DNS, DHCP,
file shares). During an outage, the dependency view shows which users a DC01 incident affects.

## 7. Problem, change and request records

| Record | How the lab uses it | Example |
|---|---|---|
| Problem | Created from 3+ linked incidents with the same symptom (*Related Records > Problem*); RCA in the work notes; known error published to KB | [PRB0040001](../itil/examples/PRB0040001-recurring-account-lockouts.md) |
| Normal change | Every GPO / DNS / DHCP edit; CAB approval by Lucas Moreno; backout = snapshot + `Restore-GPO` | [CHG0030001](../itil/examples/CHG0030001-deploy-workstation-baseline-gpo.md) |
| Emergency change | Restoring a service during a P1 | DHCP scope re-activation in [INC0010007 PIR](../itil/examples/INC0010007-dhcp-scope-outage-pir.md) |
| Request (RITM) | Onboarding / offboarding / access requests with manager approval | `New-Employee.ps1 -TicketNumber RITM0010001` |

## 8. Reports and dashboard

*Reports > Create new* - then add them to a dashboard named **Contoso Service Desk**:

| Report | Table | Type | Group by / filter |
|---|---|---|---|
| Open incidents by group | Incident | Bar | Assignment group; Active = true |
| Incidents by category (30 days) | Incident | Bar | Category; Opened on Last 30 days |
| SLA breaches | Task SLA | List | Has breached = true; Task type = Incident |
| Aged backlog | Incident | List | Active = true; Opened before 14 days ago |
| Created vs resolved | Incident | Trend | Opened / Resolved per week |

## 9. Export for the metrics script

Incident list → personalize columns: number, opened_at, resolved_at, closed_at, state, priority, category,
subcategory, short_description, contact_type, assignment_group, caller_id, cmdb_ci, reassignment_count,
reopen_count → right-click the header → **Export > CSV**. Then:

```powershell
python scripts/python/ticket_metrics.py --input C:\Downloads\incident.csv --note "ServiceNow PDI export"
```

The script maps ServiceNow column names automatically and derives first-contact resolution from
`reassignment_count` and `assignment_group` when no FCR column exists.

## 10. API smoke test (PowerShell)

```powershell
Import-Module .\scripts\powershell\integration\ServiceNow.psm1
Connect-ServiceNow -InstanceUrl https://devNNNNN.service-now.com -Credential (Get-Credential svc.helpdesk.automation)
$inc = New-SnIncident -ShortDescription 'API smoke test from LT-WIN-001' -Impact 3 -Urgency 3 `
          -Category software -AssignmentGroup 'Contoso Service Desk' -CorrelationId 'LAB-SMOKE-TEST'
$inc.number
Find-SnOpenIncident -CorrelationId 'LAB-SMOKE-TEST'
Resolve-SnIncident -SysId $inc.sys_id -CloseNotes 'Smoke test complete'
```

No instance yet? Run `python tests/mock_servicenow.py` and use `-InstanceUrl http://127.0.0.1:8765` - the
mock implements the same Table API calls and prints every request it receives.

> **Close codes:** recent releases use values such as *Solution provided*; older ones use
> *Solved (Permanently)*. If resolving fails with a data-policy error, check the choice list on the
> incident's *Resolution code* field and pass that value with `-CloseCode`.
