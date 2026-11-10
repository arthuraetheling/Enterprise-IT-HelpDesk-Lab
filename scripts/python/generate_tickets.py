#!/usr/bin/env python3
"""
generate_tickets.py - reproducible synthetic ITSM dataset in ServiceNow export format.

The data is SIMULATED (seeded random) but modelled on real service-desk behaviour, so the metrics in
ticket_metrics.py have something meaningful to find:

  * 50 callers from data/users.csv, each with a laptop (LT-WIN / LT-MAC) and some with phones (MB-IOS / MB-AND)
  * business-hours arrival pattern (Monday peak), channel mix, Windows/macOS/iOS/Android split
  * priority = impact + urgency - 1 (ServiceNow default matrix); SLA targets from docs/01-lab-design.md
  * Tier 1 first-contact resolution vs escalation to resolver groups, reassignment "ping-pong", reopens
  * deliberate patterns: a VPN disconnect cluster (Oct 12-23), Finance account lockouts (Oct 27-Nov 3),
    Outlook credential prompts after an update (Oct 15-20) and a P1 DHCP outage on 2026-11-05
  * open backlog as of the end date, including a few tickets aged > 14 days (on hold for vendor/parts)

Numbers start at INC0020001 / RITM0020001 so they never collide with the example records in itil/.

Usage:  python scripts/python/generate_tickets.py [--count 500] [--days 90] [--end-date 2026-11-06] [--seed 42]
"""
from __future__ import annotations

import argparse
import csv
import math
import random
from datetime import date, datetime, time, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FMT = "%Y-%m-%d %H:%M:%S"

SLA_RESPONSE_MIN = {1: 15, 2: 30, 3: 120, 4: 480, 5: 1440}
SLA_RESOLVE_H = {1: 4, 2: 8, 3: 24, 4: 72, 5: 120}
PRIORITY_LABEL = {1: "1 - Critical", 2: "2 - High", 3: "3 - Moderate", 4: "4 - Low", 5: "5 - Planning"}

SD, DS, IAM, NET, INFRA = ("Contoso Service Desk", "Contoso Desktop Support", "Contoso Identity & Access",
                           "Contoso Network Operations", "Contoso Infrastructure Ops")
ANALYSTS = {
    SD: ["ava.thompson", "fatima.benali"],
    DS: ["omar.haddad", "ben.larsen", "zoe.kowalski"],
    IAM: ["arjun.mehta", "isabella.costa"],
    NET: ["ryan.murphy"],
    INFRA: ["isabella.costa"],
}

# (category, subcategory, short descriptions, weight, resolver group, P(first-contact fix), platform scope, KB, slowness)
INCIDENTS = [
    ("Account & Access", "account lockout", ["Account locked out", "Locked out after password change", "Account locked again this week"], 8, IAM, 0.92, "any", "KB0001", 1.0),
    ("Account & Access", "password reset", ["Forgot password", "Password expired while travelling", "Password not accepted at sign-in"], 8, IAM, 0.95, "any", "KB0002", 1.0),
    ("Account & Access", "mfa", ["New phone - MFA re-registration", "Authenticator prompts not arriving"], 4, IAM, 0.80, "mobile", "KB0003", 1.0),
    ("Account & Access", "file share", ["Access denied on department share", "S: drive missing after sign-in"], 4, IAM, 0.60, "windows", "KB0007", 1.0),
    ("Hardware", "laptop", ["Laptop will not power on", "Laptop overheating and shutting down", "Keyboard keys not responding"], 4, DS, 0.10, "laptop", "", 1.6),
    ("Hardware", "battery/power", ["Battery drains in under two hours", "Laptop not charging on dock"], 3, DS, 0.20, "laptop", "", 1.5),
    ("Hardware", "dock/monitor", ["External monitor not detected on dock", "Dock USB ports stopped working"], 3, DS, 0.40, "laptop", "", 1.3),
    ("Hardware", "bitlocker", ["BitLocker recovery key requested after BIOS update"], 2, DS, 0.05, "windows", "KB0011", 1.0),
    ("Hardware", "disk", ["Low disk space warning", "Laptop very slow - disk almost full"], 3, DS, 0.65, "windows", "KB0013", 1.0),
    ("Software", "os", ["Windows update failed with an error", "Laptop slow after latest update", "Blue screen after waking from sleep"], 5, DS, 0.45, "windows", "KB0013", 1.3),
    ("Software", "microsoft 365 apps", ["Excel crashes opening large workbook", "Word add-in missing", "Teams camera not detected"], 5, DS, 0.70, "desktop", "KB0014", 1.0),
    ("Software", "group policy", ["Mapped printer missing after sign-in", "Screen lock policy not applying"], 2, DS, 0.55, "windows", "KB0008", 1.0),
    ("Network", "vpn", ["VPN will not connect from hotel Wi-Fi", "VPN connected but file shares unreachable"], 5, NET, 0.50, "laptop", "KB0006", 1.8),
    ("Network", "wireless", ["Wi-Fi drops in conference room 4B", "Cannot join corporate Wi-Fi"], 4, NET, 0.45, "any", "", 1.8),
    ("Network", "dns", ["Internal sites not loading but internet works", "Cannot resolve intranet name"], 2, NET, 0.65, "windows", "KB0004", 1.4),
    ("Network", "dhcp", ["No network - 169.254 address", "Limited connectivity after restart"], 2, NET, 0.50, "windows", "KB0005", 1.4),
    ("Email & Collaboration", "outlook", ["Outlook not syncing new email", "Outlook search returns no results", "Outlook keeps prompting for password"], 6, DS, 0.78, "desktop", "KB0014", 1.0),
    ("Email & Collaboration", "mailbox", ["Mailbox full warning", "Cannot open shared mailbox"], 3, IAM, 0.60, "any", "", 1.0),
    ("Email & Collaboration", "teams", ["Teams meeting audio cutting out", "Teams status stuck on Away"], 3, DS, 0.75, "any", "", 1.0),
    ("Mobile Device", "enrollment", ["Cannot enroll new iPhone in MDM", "Company Portal sign-in fails on Android"], 3, DS, 0.50, "mobile", "KB0017", 1.2),
    ("Mobile Device", "email on device", ["Work email stopped syncing on phone", "Outlook mobile asks to sign in again"], 4, DS, 0.60, "mobile", "KB0017", 1.2),
    ("Mobile Device", "lost/stolen", ["Lost company phone at airport", "Phone stolen - remote wipe needed"], 1, DS, 0.20, "mobile", "KB0017", 1.0),
    ("Printing", "print queue", ["Print jobs stuck in queue", "Printer shows offline"], 4, DS, 0.75, "windows", "KB0012", 1.0),
    ("Printing", "printer mapping", ["Cannot add Finance floor printer", "Wrong default printer after sign-in"], 2, DS, 0.80, "desktop", "KB0012", 1.0),
    ("Security", "phishing report", ["Suspicious email reported", "Clicked a link in a suspicious email"], 3, IAM, 0.70, "any", "", 1.0),
    ("Security", "malware alert", ["Defender quarantined a file", "Antivirus alert on a download"], 1, DS, 0.30, "windows", "", 1.2),
]

REQUESTS = [
    ("Account & Access", "access request", ["Access to Finance share for a new project", "Add user to Sales distribution list"], 6, IAM),
    ("Account & Access", "new hire", ["New hire setup - account and laptop"], 3, IAM),
    ("Account & Access", "offboarding", ["Employee offboarding - disable access"], 2, IAM),
    ("Software", "application install", ["Install Power BI Desktop", "Install Visio", "Adobe Acrobat Pro licence"], 5, DS),
    ("Hardware", "hardware request", ["Second monitor", "Replacement charger", "New headset"], 4, DS),
    ("Mobile Device", "new device", ["New company iPhone setup"], 2, DS),
]

CHANNELS = [("phone", 30), ("self-service", 26), ("email", 19), ("chat", 12), ("walk-in", 8)]
MONITORED = {"disk", "os", "dhcp", "dns", "malware alert"}
PERSONA_DEVICES = {"emma.carter": "LT-WIN-001", "marcus.reed": "LT-WIN-002", "priya.shah": "LT-MAC-001"}
PERSONA_PHONES = {"olivia.bennett": "MB-IOS-001", "daniel.kim": "MB-AND-001"}


def load_users(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.DictReader(fh))
    users = []
    for r in rows:
        first = "".join(c for c in r["FirstName"].lower() if c.isalnum())
        last = "".join(c for c in r["LastName"].lower() if c.isalnum())
        sam = f"{first}.{last}"[:20].encode("ascii", "ignore").decode() or f"user{len(users)}"
        users.append({"sam": sam, "department": r["Department"], "manager": r.get("IsManager", "").upper() == "TRUE"})
    return users


def assign_devices(users: list[dict], rng: random.Random) -> None:
    win, mac, ios, andr = 3, 2, 2, 2
    for u in users:
        if u["sam"] in PERSONA_DEVICES:
            u["laptop"] = PERSONA_DEVICES[u["sam"]]
        elif u["department"] in ("HR", "Sales") and rng.random() < 0.35:
            u["laptop"] = f"LT-MAC-{mac:03d}"; mac += 1
        else:
            u["laptop"] = f"LT-WIN-{win:03d}"; win += 1
        if u["sam"] in PERSONA_PHONES:
            u["phone"] = PERSONA_PHONES[u["sam"]]
        elif rng.random() < 0.55:
            if rng.random() < 0.65:
                u["phone"] = f"MB-IOS-{ios:03d}"; ios += 1
            else:
                u["phone"] = f"MB-AND-{andr:03d}"; andr += 1
        else:
            u["phone"] = ""


def weighted(rng: random.Random, items, weight_index):
    total = sum(i[weight_index] for i in items)
    pick = rng.uniform(0, total)
    for i in items:
        pick -= i[weight_index]
        if pick <= 0:
            return i
    return items[-1]


def arrival(rng: random.Random, start: date, days: int, off_hours: float = 0.06) -> datetime:
    """Business-hours arrival with a Monday peak and morning/after-lunch bumps."""
    while True:
        d = start + timedelta(days=rng.randrange(days))
        dow = d.weekday()
        weight = [1.35, 1.1, 1.0, 1.0, 0.85, 0.12, 0.08][dow]
        if rng.random() < weight / 1.35:
            break
    if rng.random() < off_hours:
        hour = rng.choice([6, 7, 19, 20, 21, 22])
    else:
        hour = int(rng.choices(range(8, 18), weights=[6, 10, 9, 8, 5, 8, 8, 6, 5, 3])[0])
    return datetime.combine(d, time(hour, rng.randrange(60), rng.randrange(60)))


def lognormal(rng: random.Random, median: float, sigma: float) -> float:
    return math.exp(math.log(median) + rng.gauss(0, sigma))


def pick_device(user: dict, scope: str, rng: random.Random) -> tuple[str, str]:
    laptop, phone = user["laptop"], user.get("phone", "")
    if scope == "mobile" and phone:
        return phone, ("iOS" if phone.startswith("MB-IOS") else "Android")
    if scope == "mobile":
        return laptop, ("macOS" if laptop.startswith("LT-MAC") else "Windows")
    if scope == "windows" and laptop.startswith("LT-MAC"):
        return laptop, "macOS"
    if scope == "any" and phone and rng.random() < 0.15:
        return phone, ("iOS" if phone.startswith("MB-IOS") else "Android")
    return laptop, ("macOS" if laptop.startswith("LT-MAC") else "Windows")


class Generator:
    def __init__(self, users, start, days, end_dt, rng):
        self.users, self.start, self.days, self.end_dt, self.rng = users, start, days, end_dt, rng
        self.rows: list[dict] = []

    def caller(self, department: str | None = None) -> dict:
        pool = [u for u in self.users if not department or u["department"] == department]
        return self.rng.choice(pool)

    def add(self, *, ttype, opened, category, subcategory, short, group, fcr_p, scope, kb, slowness=1.0,
            caller=None, impact=None, urgency=None, channel=None, ci=None, platform=None, force_open=False):
        rng = self.rng
        caller = caller or self.caller()
        if impact is None:
            impact = 2 if (caller["manager"] and rng.random() < 0.35) else (3 if rng.random() < 0.88 else 2)
        if urgency is None:
            urgency = rng.choices([1, 2, 3], weights=[18, 52, 30])[0]
            if subcategory in ("lost/stolen", "malware alert", "laptop"):
                urgency = 1
        priority = max(1, min(5, impact + urgency - 1))
        if ttype == "Request":
            priority = max(priority, 3)
        if channel is None:
            if ttype == "Incident" and subcategory in MONITORED and rng.random() < 0.3:
                channel = "monitoring"   # raised automatically by Zabbix / the endpoint health check
            else:
                channel = rng.choices([c for c, _ in CHANNELS], weights=[w for _, w in CHANNELS])[0]
        device, plat = pick_device(caller, scope, rng)
        ci = ci or device
        platform = platform or plat

        # --- response ---
        if channel in ("phone", "walk-in", "chat"):
            response_min = rng.uniform(0.5, 4)
        else:
            response_min = lognormal(rng, SLA_RESPONSE_MIN[priority] * 0.30, 0.85)
        responded = opened + timedelta(minutes=response_min)

        # --- path: first-contact fix or escalation ---
        live = channel in ("phone", "walk-in", "chat")
        fcr = ttype == "Incident" and rng.random() < (fcr_p if live else fcr_p * 0.88)
        if fcr:
            reassign = 0
            assigned_group = SD
            hours = rng.uniform(0.15, 0.7) if live else lognormal(rng, 2.0, 0.7)
        else:
            assigned_group = group if group != SD else DS
            reassign = 1 if rng.random() > 0.11 else rng.choice([2, 3])
            median = SLA_RESOLVE_H[priority] * 0.22 * slowness
            hours = lognormal(rng, median, 0.95)
            if priority == 1:
                hours = rng.uniform(1.2, 3.6)   # major incidents get all hands; most restore inside 4 h
        if ttype == "Request":
            hours = lognormal(rng, 20 * slowness, 0.8)
        on_hold = rng.random() < 0.05 and not fcr
        if on_hold:
            hours += rng.uniform(72, 400)
        resolved = responded + timedelta(hours=hours)
        reopen = 1 if rng.random() < (0.035 if fcr else 0.05) else 0
        if reopen:
            resolved += timedelta(hours=rng.uniform(4, 30))

        if force_open or resolved > self.end_dt:
            state = "On Hold" if on_hold else rng.choice(["In Progress", "In Progress", "New"])
            resolved_s, closed_s = "", ""
            if state == "New":
                responded_s = "" if rng.random() < 0.5 else responded.strftime(FMT)
            else:
                responded_s = responded.strftime(FMT)
        else:
            responded_s = responded.strftime(FMT)
            resolved_s = resolved.strftime(FMT)
            closed = resolved + timedelta(days=3, hours=rng.uniform(0, 30))
            if closed > self.end_dt:
                state, closed_s = "Resolved", ""
            else:
                state, closed_s = "Closed", closed.strftime(FMT)

        breached = bool(resolved_s) and (resolved - opened).total_seconds() / 3600 > SLA_RESOLVE_H[priority]
        csat = ""
        if resolved_s and rng.random() < 0.34:
            mean = 3.1 if (breached or reopen) else 4.6
            csat = str(max(1, min(5, round(rng.gauss(mean, 0.7)))))
        kb_article = ""
        if kb and resolved_s and rng.random() < (0.82 if fcr else 0.45):
            kb_article = kb

        # "number" is assigned after sorting so that numbers increase with time, as in ServiceNow.
        self.rows.append({
            "number": "", "ticket_type": ttype, "opened_at": opened.strftime(FMT), "responded_at": responded_s,
            "resolved_at": resolved_s, "closed_at": closed_s, "state": state, "priority": PRIORITY_LABEL[priority],
            "impact": str(impact), "urgency": str(urgency), "category": category, "subcategory": subcategory,
            "short_description": short, "contact_type": channel, "assignment_group": assigned_group,
            "assigned_to": rng.choice(ANALYSTS[assigned_group]), "caller_id": caller["sam"],
            "caller_department": caller["department"], "cmdb_ci": ci, "platform": platform,
            "reassignment_count": str(reassign), "reopen_count": str(reopen),
            "first_contact_resolution": "true" if fcr else "false", "kb_article": kb_article, "csat": csat,
        })

    def random_incident(self, opened=None, force_open=False):
        item = weighted(self.rng, INCIDENTS, 3)
        cat, sub, shorts, _, group, fcr_p, scope, kb, slow = item
        self.add(ttype="Incident", opened=opened or arrival(self.rng, self.start, self.days), category=cat,
                 subcategory=sub, short=self.rng.choice(shorts), group=group, fcr_p=fcr_p, scope=scope, kb=kb,
                 slowness=slow, force_open=force_open)

    def random_request(self):
        cat, sub, shorts, _, group = weighted(self.rng, REQUESTS, 3)
        self.add(ttype="Request", opened=arrival(self.rng, self.start, self.days), category=cat, subcategory=sub,
                 short=self.rng.choice(shorts), group=group, fcr_p=0, scope="desktop", kb="", slowness=1.0,
                 impact=3, urgency=2)

    def cluster(self, first: date, last: date, n: int, department: str | None = None, **fields):
        """n incidents with the same symptom between first and last (optionally from one department)."""
        span = (last - first).days + 1
        for _ in range(n):
            caller = self.caller(department) if department else None
            self.add(ttype="Incident", opened=arrival(self.rng, first, span), caller=caller, **fields)


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate a synthetic ServiceNow-style ticket export")
    ap.add_argument("--count", type=int, default=500, help="approximate number of tickets (default 500)")
    ap.add_argument("--days", type=int, default=90)
    ap.add_argument("--end-date", default="2026-11-06", help="last day of the dataset (YYYY-MM-DD)")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--users", default=str(REPO / "data" / "users.csv"))
    ap.add_argument("--out", default=str(REPO / "data" / "tickets.csv"))
    args = ap.parse_args()

    rng = random.Random(args.seed)
    end = datetime.strptime(args.end_date, "%Y-%m-%d").date()
    start = end - timedelta(days=args.days - 1)
    end_dt = datetime.combine(end, time(17, 30))
    users = load_users(Path(args.users))
    assign_devices(users, rng)
    gen = Generator(users, start, args.days, end_dt, rng)

    # Deliberate patterns (they become "problem candidates" in ticket_metrics.py)
    year = end.year
    gen.cluster(date(year, 10, 12), date(year, 10, 23), 15, category="Network", subcategory="vpn",
                short="VPN disconnects every 30 minutes", group=NET, fcr_p=0.05, scope="laptop", kb="KB0006", slowness=2.2)
    gen.cluster(date(year, 10, 27), date(year, 11, 3), 9, department="Finance", category="Account & Access",
                subcategory="account lockout", short="Account locked again this week", group=IAM, fcr_p=0.8,
                scope="any", kb="KB0001")
    gen.cluster(date(year, 10, 15), date(year, 10, 20), 8, category="Email & Collaboration", subcategory="outlook",
                short="Outlook keeps prompting for password", group=DS, fcr_p=0.5, scope="desktop", kb="KB0014")
    p1_start = datetime(year, 11, 5, 9, 4, 0)
    gen.add(ttype="Incident", opened=p1_start, category="Network", subcategory="dhcp",
            short="Major incident - multiple users have no network (169.254 addresses)", group=NET, fcr_p=0, scope="any",
            kb="KB0005", impact=1, urgency=1, channel="phone", ci="DC01", platform="N/A")
    for i in range(6):
        gen.add(ttype="Incident", opened=p1_start + timedelta(minutes=3 + i * 4), category="Network", subcategory="dhcp",
                short="No network - 169.254 address", group=NET, fcr_p=0, scope="windows", kb="KB0005", impact=2, urgency=1)

    special = len(gen.rows)
    remaining = max(0, args.count - special)
    n_requests = int(remaining * 0.24)
    for _ in range(remaining - n_requests):
        gen.random_incident()
    for _ in range(n_requests):
        gen.random_request()
    for _ in range(4):  # aged backlog: on hold, opened 15-40 days before the end date
        gen.random_incident(opened=datetime.combine(end - timedelta(days=rng.randint(15, 40)), time(10, 15)), force_open=True)
        gen.rows[-1]["state"] = "On Hold"
        gen.rows[-1]["short_description"] += " (awaiting vendor/parts)"

    gen.rows.sort(key=lambda r: r["opened_at"])
    inc_n = req_n = 20000
    for r in gen.rows:
        if r["ticket_type"] == "Incident":
            inc_n += 1
            r["number"] = f"INC{inc_n:07d}"
        else:
            req_n += 1
            r["number"] = f"RITM{req_n:07d}"
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(gen.rows[0].keys()))
        writer.writeheader()
        writer.writerows(gen.rows)

    inc = sum(1 for r in gen.rows if r["ticket_type"] == "Incident")
    open_n = sum(1 for r in gen.rows if not r["resolved_at"])
    print(f"Wrote {len(gen.rows)} tickets ({inc} incidents, {len(gen.rows) - inc} requests, {open_n} open) "
          f"{start} to {end} -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
