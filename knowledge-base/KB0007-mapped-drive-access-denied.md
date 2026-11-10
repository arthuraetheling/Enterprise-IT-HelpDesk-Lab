# KB0007 · Mapped drive missing or "Access denied" on a department share

| Field | Value |
|---|---|
| KB ID | KB0007 |
| Applies to | `S:` → `\\DC01\Departments` (Group Policy Preferences in `CON-U-Standard-User`) and `H:` → `\\DC01\Home$\<user>` (from the account's `homeDirectory`/`homeDrive`); Windows 11 |
| Category | Network › file share (access changes: Account & Access › access request) |
| Audience | Tier 1 (Contoso Service Desk) |
| Owner | Contoso Identity & Access |
| Last reviewed | 2026-11 |
| Typical priority | P3 (cannot reach files needed today) · P4 (workaround available) |
| Related scripts | [`New-Employee.ps1`](../scripts/powershell/helpdesk/New-Employee.ps1) (sets the H: drive), [`Invoke-NetworkTriage.ps1`](../scripts/powershell/endpoint/Invoke-NetworkTriage.ps1) |
| Related scenario | `ShareAccessRemoved` — on DC01: `.\Invoke-LabFault.ps1 -Scenario ShareAccessRemoved -UserName emma.carter` ([lab scenarios](../docs/06-lab-scenarios.md)) |

## How access works (AGDLP)

```text
emma.carter --member of--> GG-Finance --member of--> DL-FS-Finance-RW --Modify--> \\DC01\Departments\Finance
```

Access-based enumeration is on: users only **see** the department folders they are allowed to open.

## Symptoms

- **S:** is missing from *This PC*, or S: is there but the department folder is not.
- *"\\DC01\Departments\Finance is not accessible. You might not have permission to use this network resource.
  Contact the administrator of this server to find out if you have access permissions. Access is denied."*
- **H:** is missing, or *"The network path was not found."*
- The drive shows a red X (*Disconnected Network Drive*).

## Likely causes

| Symptom | Most likely cause |
|---|---|
| Folder missing or *Access is denied* | User not in `GG-<Dept>` (new hire not finished, department transfer, removed in error) |
| Still denied right after access was granted | The new group is not in the user's sign-in token yet |
| S: missing entirely | Group Policy not applied ([KB0008](KB0008-group-policy-not-applying.md)) or DNS/connectivity ([KB0004](KB0004-dns-resolution-failure.md)) |
| H: missing | `homeDirectory`/`homeDrive` not set, or the home folder does not exist |
| Red X | Offline, VPN not connected, or DC01 unreachable |
| Repeated credential prompts | Wrong credentials saved for DC01 ([KB0001](KB0001-account-lockout.md)) |

## Quick checks

In the user's session (no admin needed):

```powershell
net use
whoami /groups | findstr /i "GG-"
gpresult /r /scope:user
Test-NetConnection DC01 -Port 445
```

On DC01 or an RSAT workstation:

```powershell
Get-ADPrincipalGroupMembership emma.carter | Select-Object Name
Get-ADGroupMember DL-FS-Finance-RW | Select-Object Name, objectClass
Get-ADUser emma.carter -Properties Department, HomeDirectory, HomeDrive | Select-Object Name, Department, HomeDirectory, HomeDrive
```

Expected for Emma: member of `GG-Finance`; `GG-Finance` is a member of `DL-FS-Finance-RW`;
`HomeDirectory = \\DC01\Home$\emma.carter`, `HomeDrive = H:`.

## Resolution (Tier 1)

**1. Rule out connectivity and policy.** S: missing entirely or a red X → follow
[KB0004](KB0004-dns-resolution-failure.md) / [KB0008](KB0008-group-policy-not-applying.md) first.

**2. Missing group membership → access request, not a quick fix.**
- Confirm the access is appropriate: the user's `Department` matches the folder, **and** the data owner (department
  manager, e.g. Olivia Bennett for Finance) approves.
- Tier 1 does **not** change group membership. Attach the manager's approval to an access request (RITM) and route
  it to Contoso Identity & Access.
- If the access worked before and the user has not changed role, say so — Identity & Access can check who removed it
  (event **4729**, *a member was removed from a security-enabled global group*, on the domain controllers).

**3. After the group change, refresh the user's token.** Most reliable: **sign out and sign back in** (this also
re-runs the S: drive mapping). Quick alternative without signing out:

```powershell
klist purge
net use S: /delete
```

Then reopen `\\DC01\Departments`. If Explorer still says *Access is denied*, sign out — an existing connection to
DC01 can keep the old group list until it closes.

**4. H: drive problems.** Wrong or missing `homeDirectory`/`homeDrive` → Contoso Identity & Access. Home folder
missing or permissions wrong → Contoso Infrastructure Ops.

**5. Credential prompts** → clear saved DC01 credentials as in [KB0001](KB0001-account-lockout.md).

## Escalation

| Condition | Escalate to | Priority guidance |
|---|---|---|
| Group membership change needed (approval attached) | Contoso Identity & Access | P3/P4 |
| Several users in one department lose access at once | Contoso Infrastructure Ops (file services) | P2 |
| `homeDirectory`/`homeDrive` wrong or missing | Contoso Identity & Access | P4 |
| Folder or NTFS permissions wrong, share unavailable | Contoso Infrastructure Ops | P3 |

Attach: user, folder path, exact error text or screenshot, `whoami /groups` and group-membership output, approval
reference (RITM), and when access last worked.

## Verification

- After signing back in, `whoami /groups | findstr /i "GG-Finance"` shows the group.
- The user opens `S:\Finance` and can create and delete a test file (Modify rights).
- H: is present and opens the user's own folder.

## Prevention

- Grant access only through role groups (AGDLP) — never add individual users to folder permissions.
- Department transfers follow the onboarding/offboarding SOPs so old access is removed and new access approved
  ([SOP-001](../sops/SOP-001-new-hire-onboarding.md), [SOP-002](../sops/SOP-002-employee-offboarding.md)).
- Access-review removals are confirmed with the manager first ([SOP-008](../sops/SOP-008-quarterly-access-review.md)).

## Ticket note example

```text
INC0010031 | Access denied to S:\Finance | emma.carter (Finance) | P3
Issue: Since 08:30 Emma gets "Access is denied" on S:\Finance on LT-WIN-001; it worked yesterday. S: itself is present.
Steps taken:
  1. whoami /groups shows no GG-Finance; Get-ADPrincipalGroupMembership confirms she is not a member.
     Department attribute = Finance; no transfer or offboarding request on record.
  2. Manager Olivia Bennett confirmed by directory callback that Emma still needs Finance access.
  3. Routed to Contoso Identity & Access referencing her onboarding request RITM0010006 and the manager approval;
     asked IAM to review event 4729 for who removed the membership.
  4. IAM re-added her to GG-Finance at 09:20; user signed out and back in.
Result: S:\Finance opens; test file created and deleted successfully.
Next action: Resolve. IAM tracking the unexplained removal as a control finding. KB0007 linked.
```

Format: [ticket work note template](../itil/templates/ticket-work-note-template.md)
