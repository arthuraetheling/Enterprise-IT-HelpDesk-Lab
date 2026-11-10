#!/usr/bin/env python3
"""
ticket_metrics.py - service desk KPI analysis and dashboard (standard library only).

Reads a ticket CSV - the synthetic export from generate_tickets.py *or* a real ServiceNow incident
list export (column names are matched case-insensitively, e.g. "number", "opened_at" / "Opened",
"priority" = "3 - Moderate") - and produces:

  reports/ticket-metrics-dashboard.html   self-contained interactive dashboard (light/dark, tooltips,
                                           keyboard focus, table view for every chart, 30/60/90-day filter)
  reports/ticket-metrics-summary.md       Markdown summary for the README / portfolio
  reports/ticket-metrics.json             the computed metrics bundle

KPIs follow docs/01-lab-design.md section 8: resolution & response SLA attainment by priority, first
contact resolution, MTTR (median/P90), reopen and reassignment rates, aged backlog, CSAT, KB link rate.
Recurring-issue detection applies the problem-management trigger (>= 3 incidents with the same symptom
within 7 days) and flags spikes as problem candidates.

Usage:  python scripts/python/ticket_metrics.py [--input data/tickets.csv] [--outdir reports] [--as-of 2026-11-06]
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
from collections import Counter, defaultdict
from datetime import date, datetime, time, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

SLA_RESPONSE_MIN = {1: 15, 2: 30, 3: 120, 4: 480, 5: 1440}
SLA_RESOLVE_H = {1: 4, 2: 8, 3: 24, 4: 72, 5: 120}
PRIORITY_NAME = {1: "P1 Critical", 2: "P2 High", 3: "P3 Moderate", 4: "P4 Low", 5: "P5 Planning"}
TARGETS = {"fcr": 70.0, "sla_p1p2": 95.0, "sla_other": 90.0, "sla_overall": 90.0, "response": 95.0,
           "reopen": 5.0, "reassign": 10.0, "aged": 5.0, "csat": 4.5, "kb": 60.0}
SERVICE_DESK = "Contoso Service Desk"
CHANNEL_ORDER = [("phone", "Phone"), ("self-service", "Self-service portal"), ("email", "Email"),
                 ("chat", "Chat"), ("walk-in", "Walk-up"), ("monitoring", "Monitoring")]
PLATFORM_ORDER = [("Windows", "Windows"), ("macOS", "macOS"), ("iOS", "iOS"), ("Android", "Android"),
                  ("N/A", "Infrastructure")]
AGING = [("0-2 days", 0, 2), ("3-7 days", 3, 7), ("8-14 days", 8, 14), ("Over 14 days", 15, 10 ** 6)]

ALIASES = {
    "number": ["number"], "ticket_type": ["ticket_type", "sys_class_name", "task_type", "type"],
    "opened_at": ["opened_at", "opened", "sys_created_on", "created"], "responded_at": ["responded_at", "u_responded_at", "responded"],
    "resolved_at": ["resolved_at", "resolved"], "closed_at": ["closed_at", "closed"],
    "state": ["state", "incident_state"], "priority": ["priority"], "category": ["category"],
    "subcategory": ["subcategory"], "short_description": ["short_description", "short description"],
    "contact_type": ["contact_type", "channel", "contact type"], "assignment_group": ["assignment_group", "assignment group"],
    "caller_id": ["caller_id", "caller"], "caller_department": ["caller_department", "department"],
    "cmdb_ci": ["cmdb_ci", "configuration item"], "platform": ["platform", "u_platform"],
    "reassignment_count": ["reassignment_count", "reassignment count"], "reopen_count": ["reopen_count", "reopen count"],
    "first_contact_resolution": ["first_contact_resolution", "u_first_contact_resolution", "fcr"],
    "kb_article": ["kb_article", "u_kb_article", "knowledge"], "csat": ["csat", "u_csat", "survey score"],
}
DATE_FORMATS = ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M", "%m/%d/%Y %H:%M:%S",
                "%m/%d/%Y %I:%M:%S %p", "%m/%d/%Y %H:%M", "%d-%m-%Y %H:%M:%S", "%Y-%m-%d")


# ----------------------------------------------------------------------------------------------- loading
def parse_dt(value: str):
    value = (value or "").strip()
    if not value:
        return None
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return None


def parse_priority(value: str) -> int:
    m = re.search(r"[1-5]", value or "")
    if m:
        return int(m.group(0))
    words = {"critical": 1, "high": 2, "moderate": 3, "medium": 3, "low": 4, "planning": 5}
    return words.get((value or "").strip().lower(), 4)


def to_int(value: str, default: int = 0) -> int:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def truthy(value: str) -> bool:
    return (value or "").strip().lower() in ("true", "yes", "1", "y")


def load_tickets(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        header_map = {}
        lower = {h.lower().strip(): h for h in (reader.fieldnames or [])}
        for canon, names in ALIASES.items():
            for n in names:
                if n in lower:
                    header_map[canon] = lower[n]
                    break
        missing = [c for c in ("number", "opened_at", "priority") if c not in header_map]
        if missing:
            raise SystemExit(f"Input is missing required columns: {', '.join(missing)}")
        rows = list(reader)

    tickets = []
    for r in rows:
        g = lambda k: (r.get(header_map[k], "") if k in header_map else "").strip()  # noqa: E731
        number = g("number")
        opened = parse_dt(g("opened_at"))
        if not number or not opened:
            continue
        ttype = g("ticket_type").lower()
        is_request = number.upper().startswith(("RITM", "REQ", "SCTASK")) or "request" in ttype
        p = parse_priority(g("priority"))
        responded, resolved = parse_dt(g("responded_at")), parse_dt(g("resolved_at"))
        state = g("state") or ("Resolved" if resolved else "Open")
        t = {
            "number": number, "type": "Request" if is_request else "Incident", "opened": opened,
            "responded": responded, "resolved": resolved, "state": state, "priority": p,
            "category": g("category") or "Uncategorized", "subcategory": g("subcategory"),
            "short": g("short_description"), "channel": g("contact_type").lower(),
            "group": g("assignment_group") or "Unassigned", "caller": g("caller_id"),
            "department": g("caller_department"), "ci": g("cmdb_ci"), "platform": g("platform") or "N/A",
            "reassign": to_int(g("reassignment_count")), "reopen": to_int(g("reopen_count")),
            "kb": g("kb_article"), "csat": to_int(g("csat"), 0) or None,
        }
        t["open"] = resolved is None and state.lower() not in ("closed", "canceled", "cancelled", "resolved")
        t["resolve_h"] = (resolved - opened).total_seconds() / 3600 if resolved else None
        t["respond_min"] = (responded - opened).total_seconds() / 60 if responded else None
        t["sla_met"] = t["resolve_h"] <= SLA_RESOLVE_H[p] if t["resolve_h"] is not None else None
        t["response_met"] = t["respond_min"] <= SLA_RESPONSE_MIN[p] if t["respond_min"] is not None else None
        if "first_contact_resolution" in header_map:
            t["fcr"] = truthy(g("first_contact_resolution"))
        else:  # derive: solved by the Service Desk without reassignment
            t["fcr"] = bool(resolved) and t["reassign"] == 0 and t["group"] == SERVICE_DESK
        tickets.append(t)
    if not tickets:
        raise SystemExit("No usable rows found in the input file.")
    return tickets


# ----------------------------------------------------------------------------------------------- helpers
def pct(num: float, den: float):
    return round(100.0 * num / den, 1) if den else None


def median(values):
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 2) if values else None


def p90(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    k = max(0, min(len(values) - 1, int(round(0.9 * (len(values) - 1)))))
    return round(values[k], 2)


def fmt_pct(v) -> str:
    return "n/a" if v is None else f"{v:.1f}%"


def fmt_h(v) -> str:
    if v is None:
        return "n/a"
    return f"{v:.1f} h" if v < 10 else f"{v:.0f} h"


def normalize_issue(text: str) -> str:
    s = re.sub(r"\(.*?\)", " ", text.lower())
    s = re.sub(r"\b(lt|mb)-[a-z]+-\d+\b", " ", s)
    s = re.sub(r"[^a-z0-9 ]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def peak_in_days(dates: list[datetime], days: int = 7) -> tuple[int, datetime | None]:
    ds = sorted(dates)
    best, best_start, j = 0, None, 0
    for i in range(len(ds)):
        while ds[i] - ds[j] >= timedelta(days=days):
            j += 1
        if i - j + 1 > best:
            best, best_start = i - j + 1, ds[j]
    return best, best_start


def short_date(d) -> str:
    return f"{d:%b} {d.day}" if d else ""


# ----------------------------------------------------------------------------------------------- metrics
def compute_window(all_tickets: list[dict], start: datetime, as_of: datetime, days: int, label: str) -> dict:
    w = [t for t in all_tickets if start <= t["opened"] <= as_of]
    inc = [t for t in w if t["type"] == "Incident"]
    req = [t for t in w if t["type"] == "Request"]
    res_inc = [t for t in inc if t["resolve_h"] is not None]
    responded = [t for t in inc if t["response_met"] is not None]

    sla = pct(sum(t["sla_met"] for t in res_inc), len(res_inc))
    response = pct(sum(t["response_met"] for t in responded), len(responded))
    fcr = pct(sum(t["fcr"] for t in res_inc), len(res_inc))
    reopen = pct(sum(t["reopen"] > 0 for t in res_inc), len(res_inc))
    reassign = pct(sum(t["reassign"] >= 2 for t in inc), len(inc))
    kb = pct(sum(bool(t["kb"]) for t in res_inc), len(res_inc))
    csat_vals = [t["csat"] for t in w if t["csat"]]
    csat = round(statistics.mean(csat_vals), 2) if csat_vals else None
    mttr, mttr90 = median(t["resolve_h"] for t in res_inc), p90(t["resolve_h"] for t in res_inc)
    mtta = median(t["respond_min"] for t in responded)

    # Backlog is a snapshot "as of" the end date (same in every window).
    backlog = [t for t in all_tickets if t["open"] and t["opened"] <= as_of]
    aged = [t for t in backlog if (as_of.date() - t["opened"].date()).days > 14]
    aged_pct = pct(len(aged), len(backlog))

    # Weekly trend: complete weeks starting on the first Monday inside the window.
    first_monday = (start + timedelta(days=(7 - start.weekday()) % 7)).date()
    weeks = []
    wk = first_monday
    while wk <= as_of.date():
        nxt = wk + timedelta(days=7)
        in_week = [t for t in w if wk <= t["opened"].date() < nxt]
        res_week = [t for t in in_week if t["type"] == "Incident" and t["resolve_h"] is not None]
        weeks.append({"week": wk.isoformat(), "incidents": sum(t["type"] == "Incident" for t in in_week),
                      "requests": sum(t["type"] == "Request" for t in in_week),
                      "sla": pct(sum(t["sla_met"] for t in res_week), len(res_week))})
        wk = nxt

    cat_counts = Counter(t["category"] for t in inc)
    by_category = [{"name": k, "count": v, "share": pct(v, len(inc))} for k, v in cat_counts.most_common()]

    sla_by_priority = []
    for p in range(1, 6):
        rows = [t for t in res_inc if t["priority"] == p]
        target = TARGETS["sla_p1p2"] if p <= 2 else TARGETS["sla_other"]
        met = sum(t["sla_met"] for t in rows)
        sla_by_priority.append({"priority": PRIORITY_NAME[p], "n": len(rows), "met": met, "attainment": pct(met, len(rows)),
                                "target": target, "targetH": SLA_RESOLVE_H[p], "medianH": median(t["resolve_h"] for t in rows)})

    aging = []
    for name, lo, hi in AGING:
        aging.append({"bucket": name, "count": sum(lo <= (as_of.date() - t["opened"].date()).days <= hi for t in backlog)})

    ch_counts = Counter(t["channel"] for t in w)
    channels = [{"name": name, "slot": i, "count": ch_counts.get(key, 0)} for i, (key, name) in enumerate(CHANNEL_ORDER)]
    other_ch = sum(v for k, v in ch_counts.items() if k not in dict(CHANNEL_ORDER))
    if other_ch:
        channels[-1]["count"] += other_ch  # unknown channels fold into the last slot rather than a 7th hue
    pl_counts = Counter(t["platform"] for t in inc)
    platforms = [{"name": name, "slot": i, "count": pl_counts.get(key, 0)} for i, (key, name) in enumerate(PLATFORM_ORDER)]
    other_pl = sum(v for k, v in pl_counts.items() if k not in dict(PLATFORM_ORDER))
    platforms[-1]["count"] += other_pl

    groups = []
    for gname in sorted({t["group"] for t in inc}):
        g_inc = [t for t in inc if t["group"] == gname]
        g_res = [t for t in g_inc if t["resolve_h"] is not None]
        groups.append({"name": gname, "count": len(g_inc), "resolved": len(g_res),
                       "medianH": median(t["resolve_h"] for t in g_res),
                       "sla": pct(sum(t["sla_met"] for t in g_res), len(g_res)),
                       "reassign": pct(sum(t["reassign"] >= 2 for t in g_inc), len(g_inc))})
    groups.sort(key=lambda g: -g["count"])

    # Recurring issues / problem candidates
    clusters = defaultdict(list)
    for t in inc:
        clusters[normalize_issue(t["short"])].append(t)
    recurring = []
    for key, items in clusters.items():
        if len(items) < 3:
            continue
        peak, peak_start = peak_in_days([t["opened"] for t in items], 7)
        # Baseline = the symptom's weekly rate OUTSIDE its busiest 7 days (floor 0.5/week so rare issues don't explode).
        baseline = (len(items) - peak) / max(1.0, (days - 7) / 7.0)
        spike = peak / max(baseline, 0.5)
        label_text = Counter(re.sub(r"\s*\(.*?\)", "", t["short"]).strip() for t in items).most_common(1)[0][0]
        sub = Counter(t["subcategory"] for t in items).most_common(1)[0][0]
        if sub == "password reset":
            action = "Deflect: self-service password reset"
        elif peak >= 5 and spike >= 3:
            action = "Problem candidate: open a PRB"
        elif peak >= 3:
            action = "Recurring: improve KB / automate"
        else:
            action = "Monitor"
        recurring.append({
            "issue": label_text, "category": items[0]["category"], "count": len(items), "peak7": peak,
            "peakStart": short_date(peak_start), "users": len({t["caller"] for t in items}),
            "first": short_date(min(t["opened"] for t in items)), "last": short_date(max(t["opened"] for t in items)),
            "spike": round(spike, 1), "action": action,
        })
    recurring.sort(key=lambda r: (r["action"] != "Problem candidate: open a PRB", -r["peak7"], -r["count"]))
    recurring = recurring[:10]

    kpis = {"tickets": len(w), "incidents": len(inc), "requests": len(req), "resolvedIncidents": len(res_inc),
            "sla": sla, "response": response, "fcr": fcr, "reopen": reopen, "reassign": reassign, "kb": kb,
            "csat": csat, "csatN": len(csat_vals), "mttrMedianH": mttr, "mttrP90H": mttr90, "mttaMedianMin": mtta,
            "backlog": len(backlog), "aged": len(aged), "agedPct": aged_pct}

    insights = build_insights(kpis, inc, res_inc, by_category, sla_by_priority, recurring, days, w)

    def ok(value, target, higher=True):
        if value is None:
            return None
        return value >= target if higher else value <= target

    hero = {"label": "Resolution SLA attainment", "display": fmt_pct(sla),
            "sub": f"{sum(t['sla_met'] for t in res_inc)} of {len(res_inc)} resolved incidents met their priority target",
            "target": f"Target ≥ {TARGETS['sla_overall']:.0f}%", "targetValue": TARGETS["sla_overall"],
            "ok": ok(sla, TARGETS["sla_overall"])}
    tiles = [
        {"label": "Tickets", "display": f"{len(w):,}", "sub": f"{len(inc)} incidents, {len(req)} requests", "ok": None},
        {"label": "First-contact resolution", "display": fmt_pct(fcr), "sub": f"Target ≥ {TARGETS['fcr']:.0f}%", "ok": ok(fcr, TARGETS["fcr"])},
        {"label": "Median time to resolve", "display": fmt_h(mttr), "sub": f"P90 {fmt_h(mttr90)}", "ok": None},
        {"label": "Response SLA", "display": fmt_pct(response), "sub": f"Target ≥ {TARGETS['response']:.0f}%", "ok": ok(response, TARGETS["response"])},
        {"label": "Reopen rate", "display": fmt_pct(reopen), "sub": f"Target ≤ {TARGETS['reopen']:.0f}%", "ok": ok(reopen, TARGETS["reopen"], False)},
        {"label": "Reassigned 2+ times", "display": fmt_pct(reassign), "sub": f"Target ≤ {TARGETS['reassign']:.0f}%", "ok": ok(reassign, TARGETS["reassign"], False)},
        {"label": "Aged backlog", "display": f"{len(aged)} of {len(backlog)}", "sub": f"Open > 14 days ({fmt_pct(aged_pct)}); target ≤ {TARGETS['aged']:.0f}%", "ok": ok(aged_pct if aged_pct is not None else 0.0, TARGETS["aged"], False)},
        {"label": "Customer satisfaction", "display": "n/a" if csat is None else f"{csat:.1f} / 5", "sub": f"{len(csat_vals)} responses; target ≥ {TARGETS['csat']}", "ok": ok(csat, TARGETS["csat"])},
        {"label": "KB link rate", "display": fmt_pct(kb), "sub": f"Target ≥ {TARGETS['kb']:.0f}%", "ok": ok(kb, TARGETS["kb"])},
    ]
    return {"label": label, "days": days, "start": start.date().isoformat(), "end": as_of.date().isoformat(),
            "kpis": kpis, "hero": hero, "tiles": tiles, "weekly": weeks, "byCategory": by_category,
            "slaByPriority": sla_by_priority, "aging": aging, "channels": channels, "platforms": platforms,
            "groups": groups, "recurring": recurring, "insights": insights}


def build_insights(k, inc, res_inc, by_category, sla_rows, recurring, days, w) -> list[dict]:
    out = []
    per_month = 30.0 / days
    access = next((c for c in by_category if c["name"] == "Account & Access"), None)
    pw = [t for t in inc if t["subcategory"] in ("password reset", "account lockout")]
    if access and access["share"] and access["share"] >= 15:
        out.append({"level": "action", "text": (
            f"Account & Access is {access['share']:.0f}% of incidents ({access['count']}); password resets and lockouts "
            f"alone are {len(pw)}. Self-service password reset could deflect about {round(len(pw) * per_month * 0.6)} tickets a month.")})
    for r in [r for r in recurring if r["action"].startswith("Problem candidate")][:3]:
        out.append({"level": "action", "text": (
            f"'{r['issue']}': {r['count']} incidents, {r['peak7']} of them within 7 days from {r['peakStart']} "
            f"({r['users']} users). Open a problem record and review changes made just before {r['peakStart']}.")})
    for s in sla_rows:
        if s["n"] >= 3 and s["attainment"] is not None and s["attainment"] < s["target"]:
            breaches = Counter(t["group"].replace("Contoso ", "") for t in res_inc
                               if PRIORITY_NAME[t["priority"]] == s["priority"] and not t["sla_met"])
            where = ""
            if breaches:
                where = "; misses by group: " + ", ".join(f"{g} {n}" for g, n in breaches.most_common(3))
            out.append({"level": "action", "text": (
                f"{s['priority']} resolution SLA is {s['attainment']:.1f}% against a {s['target']:.0f}% target "
                f"({s['met']} of {s['n']} met within {s['targetH']} h){where}.")})
    if k["fcr"] is not None:
        cats = []
        for c in by_category:
            rows = [t for t in res_inc if t["category"] == c["name"]]
            if len(rows) >= 10:
                cats.append((pct(sum(t["fcr"] for t in rows), len(rows)), c["name"]))
        cats.sort()
        worst = ", ".join(f"{name} ({v:.0f}%)" for v, name in cats[:2])
        if k["fcr"] < TARGETS["fcr"]:
            out.append({"level": "watch", "text": f"First-contact resolution is {k['fcr']:.1f}% against a {TARGETS['fcr']:.0f}% target. Lowest: {worst}. Add Tier 1 runbooks and KB coverage there."})
        else:
            out.append({"level": "good", "text": f"First-contact resolution is {k['fcr']:.1f}% (target {TARGETS['fcr']:.0f}%). Lowest categories to coach on: {worst}."})
    if k["reassign"] is not None:
        level = "good" if k["reassign"] <= TARGETS["reassign"] else "watch"
        out.append({"level": level, "text": f"{k['reassign']:.1f}% of incidents were reassigned two or more times (target ≤ {TARGETS['reassign']:.0f}%)."
                    + (" Routing is healthy." if level == "good" else " Review categorization and assignment rules.")})
    if k["backlog"]:
        level = "good" if (k["agedPct"] or 0) <= TARGETS["aged"] else "watch"
        out.append({"level": level, "text": f"{k['aged']} of {k['backlog']} open tickets are older than 14 days ({fmt_pct(k['agedPct'])})."
                    + (" Review on-hold reasons and vendor ETAs weekly." if level == "watch" else "")})
    if k["kb"] is not None:
        level = "good" if k["kb"] >= TARGETS["kb"] else "watch"
        out.append({"level": level, "text": f"KB link rate is {k['kb']:.1f}% (target {TARGETS['kb']:.0f}%)."
                    + (" Link the article you used on every resolution." if level == "watch" else "")})
    if k["csat"] is not None:
        met = [t["csat"] for t in w if t["csat"] and t["sla_met"]]
        miss = [t["csat"] for t in w if t["csat"] and t["sla_met"] is False]
        detail = ""
        if met and miss:
            detail = f" Tickets that missed SLA average {statistics.mean(miss):.1f} versus {statistics.mean(met):.1f} when SLA was met."
        level = "good" if k["csat"] >= TARGETS["csat"] else "watch"
        out.append({"level": level, "text": f"CSAT averages {k['csat']:.2f} from {k['csatN']} responses (target {TARGETS['csat']}).{detail}"})
    return out


# ----------------------------------------------------------------------------------------------- outputs
def write_markdown(bundle: dict, path: Path) -> None:
    w = bundle["windows"][bundle["defaultWindow"]]
    k = w["kpis"]
    lines = [
        "# Service Desk Metrics Summary", "",
        f"*{bundle['meta']['note']}* - {k['tickets']} tickets ({k['incidents']} incidents, {k['requests']} requests), "
        f"{w['start']} to {w['end']}. Generated by `scripts/python/ticket_metrics.py`.", "",
        "## Headline KPIs", "", "| KPI | Value | Target | Status |", "|---|---|---|---|",
    ]
    status = lambda ok: "n/a" if ok is None else ("Meets target" if ok else "Misses target")  # noqa: E731
    lines.append(f"| {w['hero']['label']} | {w['hero']['display']} | {w['hero']['target'].replace('Target ', '')} | {status(w['hero']['ok'])} |")
    for t in w["tiles"]:
        target = re.split(r"[Tt]arget ", t["sub"])[-1] if "arget" in t["sub"] else "-"
        lines.append(f"| {t['label']} | {t['display']} | {target} | {status(t['ok'])} |")
    lines += ["", "## Resolution SLA by priority", "", "| Priority | Resolved | Met | Attainment | Target | Median | SLA |", "|---|---:|---:|---:|---:|---:|---:|"]
    for s in w["slaByPriority"]:
        lines.append(f"| {s['priority']} | {s['n']} | {s['met']} | {fmt_pct(s['attainment'])} | {s['target']:.0f}% | {fmt_h(s['medianH'])} | {s['targetH']} h |")
    lines += ["", "## Recurring issues and problem candidates", "", "| Issue | Category | Tickets | Peak in 7 days | Users | Window | Suggested action |", "|---|---|---:|---:|---:|---|---|"]
    for r in w["recurring"]:
        lines.append(f"| {r['issue']} | {r['category']} | {r['count']} | {r['peak7']} (from {r['peakStart']}) | {r['users']} | {r['first']} - {r['last']} | {r['action']} |")
    level_word = {"action": "Act", "watch": "Watch", "good": "On track"}
    lines += ["", "## Insights", ""]
    lines += [f"- **{level_word[i['level']]}:** {i['text']}" for i in w["insights"]]
    lines += ["", "## Resolver groups", "", "| Group | Incidents | Median resolve | Resolution SLA | Reassigned 2+ |", "|---|---:|---:|---:|---:|"]
    for g in w["groups"]:
        lines.append(f"| {g['name']} | {g['count']} | {fmt_h(g['medianH'])} | {fmt_pct(g['sla'])} | {fmt_pct(g['reassign'])} |")
    lines += ["", "Definitions: SLA clocks run in calendar hours from opened to resolved (no pause states); FCR = resolved by the",
              "Service Desk on first contact without reassignment; backlog is a snapshot as of the end date.", ""]
    path.write_text("\n".join(lines), encoding="utf-8")


def write_html(bundle: dict, path: Path) -> None:
    payload = json.dumps(bundle, ensure_ascii=True).replace("</", "<\\/")
    path.write_text(HTML_TEMPLATE.replace("__DATA__", payload), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Service desk KPI analysis and dashboard")
    ap.add_argument("--input", default=str(REPO / "data" / "tickets.csv"))
    ap.add_argument("--outdir", default=str(REPO / "reports"))
    ap.add_argument("--as-of", help="end date YYYY-MM-DD (default: last opened date in the data)")
    ap.add_argument("--windows", default="30,60,90", help="comma-separated window lengths in days")
    ap.add_argument("--title", default="Contoso Financial - IT Service Desk")
    ap.add_argument("--note", default="Simulated data (generate_tickets.py, seed 42)")
    args = ap.parse_args()

    tickets = load_tickets(Path(args.input))
    last_day = datetime.strptime(args.as_of, "%Y-%m-%d").date() if args.as_of else max(t["opened"] for t in tickets).date()
    as_of = datetime.combine(last_day, time(23, 59, 59))
    windows, order = {}, []
    for d in sorted({int(x) for x in args.windows.split(",") if x.strip()}):
        start = datetime.combine(last_day - timedelta(days=d - 1), time(0, 0))
        windows[str(d)] = compute_window(tickets, start, as_of, d, f"Last {d} days")
        order.append(str(d))
    first = min(t["opened"] for t in tickets)
    span = (last_day - first.date()).days + 1
    if span > max(int(x) for x in order):
        windows["all"] = compute_window(tickets, datetime.combine(first.date(), time(0, 0)), as_of, span, "All data")
        order.append("all")

    bundle = {
        "meta": {"title": args.title, "note": args.note, "source": Path(args.input).name, "rows": len(tickets),
                 "asOf": last_day.isoformat(), "generatedAt": datetime.now().strftime("%Y-%m-%d %H:%M")},
        "targets": TARGETS, "windowOrder": order, "defaultWindow": order[-1] if order[-1] != "all" else order[-2],
        "windows": windows,
    }
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "ticket-metrics.json").write_text(json.dumps(bundle, indent=2), encoding="utf-8")
    write_markdown(bundle, outdir / "ticket-metrics-summary.md")
    write_html(bundle, outdir / "ticket-metrics-dashboard.html")

    print(f"Loaded {len(tickets)} tickets from {Path(args.input).name}; as of {last_day}")
    print(f"{'Window':<14}{'Tickets':>8}{'SLA':>8}{'Resp':>8}{'FCR':>8}{'MTTR':>8}{'Reopen':>8}{'CSAT':>6}")
    for key in order:
        k = windows[key]["kpis"]
        print(f"{windows[key]['label']:<14}{k['tickets']:>8}{fmt_pct(k['sla']):>8}{fmt_pct(k['response']):>8}"
              f"{fmt_pct(k['fcr']):>8}{fmt_h(k['mttrMedianH']):>8}{fmt_pct(k['reopen']):>8}{(k['csat'] or 0):>6.2f}")
    cand = [r for r in windows[bundle["defaultWindow"]]["recurring"] if r["action"].startswith("Problem candidate")]
    print(f"Problem candidates ({windows[bundle['defaultWindow']]['label']}): " + ("; ".join(f"{r['issue']} x{r['count']}" for r in cand) or "none"))
    print(f"Wrote {outdir / 'ticket-metrics-dashboard.html'}")
    print(f"Wrote {outdir / 'ticket-metrics-summary.md'}")
    return 0


HTML_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Service Desk Metrics</title>
<style>
:root {
  color-scheme: light;
  --page: #f9f9f7; --surface-1: #fcfcfb; --hover-bg: #f1f0ec;
  --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #898781;
  --gridline: #e1e0d9; --axis: #c3c2b7; --border: rgba(11,11,11,0.10);
  --series-1: #2a78d6; --series-2: #eb6834; --series-3: #1baf7a; --series-4: #eda100; --series-5: #e87ba4; --series-6: #008300;
  --on-fill: #ffffff; --on-fill-4: #0b0b0b;
  --good: #0ca30c; --warning: #fab219; --serious: #ec835a; --critical: #d03b3b;
  --shadow: 0 6px 20px rgba(11,11,11,0.10);
}
@media (prefers-color-scheme: dark) {
  :root:where(:not([data-theme="light"])) {
    color-scheme: dark;
    --page: #0d0d0d; --surface-1: #1a1a19; --hover-bg: #242423;
    --text-primary: #f0efec; --text-secondary: #c3c2b7; --text-muted: #898781;
    --gridline: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10);
    --series-1: #3987e5; --series-2: #d95926; --series-3: #199e70; --series-4: #c98500; --series-5: #d55181; --series-6: #008300;
    --on-fill-4: #ffffff; --shadow: 0 6px 20px rgba(0,0,0,0.45);
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --page: #0d0d0d; --surface-1: #1a1a19; --hover-bg: #242423;
  --text-primary: #f0efec; --text-secondary: #c3c2b7; --text-muted: #898781;
  --gridline: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10);
  --series-1: #3987e5; --series-2: #d95926; --series-3: #199e70; --series-4: #c98500; --series-5: #d55181; --series-6: #008300;
  --on-fill-4: #ffffff; --shadow: 0 6px 20px rgba(0,0,0,0.45);
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--text-primary); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
.wrap { max-width: 1180px; margin: 0 auto; padding: 28px 16px 48px; }
.eyebrow { margin: 0; color: var(--text-secondary); font-size: 13px; }
h1 { margin: 2px 0 4px; font-size: 24px; font-weight: 650; letter-spacing: -0.01em; }
.sub { margin: 0; color: var(--text-secondary); font-size: 13px; }
.filters { display: flex; flex-wrap: wrap; gap: 6px; margin: 18px 0 16px; }
.filters button { font: inherit; font-size: 13px; display: inline-flex; align-items: center; gap: 6px; padding: 6px 12px; border-radius: 8px;
  border: 1px solid var(--border); background: var(--surface-1); color: var(--text-primary); cursor: pointer; }
.filters button:hover { background: var(--hover-bg); }
.filters button[aria-pressed="true"] { font-weight: 650; border-color: var(--text-secondary); }
.filters .check { width: 16px; height: 16px; display: none; }
.filters button[aria-pressed="true"] .check { display: inline-block; }
.top { display: grid; grid-template-columns: minmax(250px, 320px) minmax(0, 1fr); gap: 16px; }
.card { background: var(--surface-1); border: 1px solid var(--border); border-radius: 12px; padding: 16px 18px; min-width: 0; }
.hero-label { color: var(--text-secondary); font-size: 13px; }
.hero-value { font-size: 56px; font-weight: 650; line-height: 1.05; margin: 10px 0 8px; letter-spacing: -0.02em; }
.hero-sub { color: var(--text-secondary); font-size: 13px; margin-bottom: 10px; }
.tiles { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.hero { display: flex; flex-direction: column; }
.spark { margin-top: auto; padding-top: 14px; }
.spark-line { stroke: var(--text-muted); }
.tile { background: var(--surface-1); border: 1px solid var(--border); border-radius: 12px; padding: 12px 14px; min-width: 0; }
.tile-label { color: var(--text-secondary); font-size: 13px; }
.tile-value { font-size: 24px; font-weight: 600; margin: 2px 0 2px; }
.tile-sub { color: var(--text-secondary); font-size: 12px; margin-bottom: 4px; }
.status { display: inline-flex; align-items: center; gap: 5px; font-size: 12px; color: var(--text-secondary); }
.st-good { fill: var(--good); } .st-crit { fill: var(--critical); } .st-serious { fill: var(--serious); } .st-warn { fill: var(--warning); }
.st-glyph { stroke: #ffffff; stroke-width: 1.7; fill: none; stroke-linecap: round; stroke-linejoin: round; }
.st-glyph.dark { stroke: #0b0b0b; } .st-dot { fill: #ffffff; } .st-dot.dark { fill: #0b0b0b; }
.grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; margin-top: 16px; }
.card.wide { grid-column: 1 / -1; }
h2 { margin: 0; font-size: 15px; font-weight: 600; }
.card-sub { margin: 2px 0 10px; color: var(--text-secondary); font-size: 13px; }
.legend { display: flex; flex-wrap: wrap; gap: 14px; margin: 4px 0 8px; font-size: 12px; color: var(--text-secondary); }
.lg-item { display: inline-flex; align-items: center; gap: 6px; }
.lg-swatch { width: 10px; height: 10px; border-radius: 2px; display: inline-block; }
.lg-line { width: 14px; height: 2px; border-radius: 1px; display: inline-block; }
.chart { width: 100%; min-height: 40px; }
.chart svg { display: block; overflow: visible; }
svg text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
.tick { fill: var(--text-muted); font-size: 11px; font-variant-numeric: tabular-nums; }
.cat { fill: var(--text-secondary); font-size: 12px; }
.val { fill: var(--text-primary); font-size: 12px; font-weight: 600; font-variant-numeric: tabular-nums; }
.direct { fill: var(--text-secondary); font-size: 12px; }
.gridline { stroke: var(--gridline); stroke-width: 1; shape-rendering: crispEdges; }
.axis { stroke: var(--axis); stroke-width: 1; shape-rendering: crispEdges; }
.series-line { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
.dot { stroke: var(--surface-1); stroke-width: 2; }
.crosshair { stroke: var(--axis); stroke-width: 1; }
.target { stroke: var(--text-primary); stroke-width: 2; stroke-linecap: round; }
.mark { outline: none; }
.mark:hover .bar, .mark:focus .bar, .mark:hover .seg, .mark:focus .seg { filter: brightness(1.12); }
.mark:focus-visible .bar, .mark:focus-visible .seg { stroke: var(--text-primary); stroke-width: 1.5; }
.overlay:focus-visible { outline: 2px solid var(--text-secondary); outline-offset: 2px; }
.seg-label { font-size: 12px; font-weight: 600; }
details { margin-top: 10px; }
summary { cursor: pointer; color: var(--text-secondary); font-size: 13px; }
.table-scroll { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 8px; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--gridline); vertical-align: top; }
th { color: var(--text-secondary); font-weight: 600; }
th.num, td.num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
.insights { list-style: none; margin: 4px 0 0; padding: 0; display: grid; gap: 10px; }
.insights li { display: grid; grid-template-columns: 84px minmax(0, 1fr); gap: 10px; align-items: start; }
.badge { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 600; color: var(--text-secondary); padding-top: 1px; }
.tooltip { position: fixed; z-index: 20; pointer-events: none; min-width: 150px; max-width: 280px; padding: 8px 10px; border-radius: 8px;
  background: var(--surface-1); color: var(--text-primary); border: 1px solid var(--border); box-shadow: var(--shadow); font-size: 12px; }
.tt-title { color: var(--text-secondary); margin-bottom: 4px; }
.tt-row { display: flex; align-items: center; gap: 8px; margin-top: 2px; }
.tt-value { font-weight: 650; font-variant-numeric: tabular-nums; }
.tt-label { color: var(--text-secondary); }
.tt-key { display: inline-block; flex: none; }
.tt-key.line { width: 12px; height: 2px; border-radius: 1px; }
.tt-key.rect { width: 8px; height: 8px; border-radius: 2px; }
footer { margin-top: 24px; color: var(--text-secondary); font-size: 12px; }
footer dl { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 4px 14px; margin: 8px 0 0; }
footer dt { font-weight: 600; }
footer dd { margin: 0; }
@media (max-width: 760px) {
  .top, .grid { grid-template-columns: minmax(0, 1fr); }
  .hero-value { font-size: 48px; }
  .insights li { grid-template-columns: minmax(0, 1fr); gap: 2px; }
}
@media (max-width: 560px) {
  .tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  footer dl { grid-template-columns: minmax(0, 1fr); }
}
</style>
</head>
<body>
<main class="wrap">
  <header>
    <p class="eyebrow" id="eyebrow"></p>
    <h1>Service desk performance</h1>
    <p class="sub" id="subtitle"></p>
  </header>
  <div class="filters" id="filters" role="group" aria-label="Date range"></div>
  <section class="top">
    <div class="card hero" id="hero"></div>
    <div class="tiles" id="tiles"></div>
  </section>
  <section class="grid">
    <article class="card wide">
      <h2>Weekly ticket volume</h2>
      <p class="card-sub">Incidents and service requests opened per week (complete weeks in the selected range)</p>
      <div class="legend" id="lg-weekly"></div>
      <div class="chart" id="ch-weekly"></div>
      <details><summary>Table view</summary><div class="table-scroll" id="tb-weekly"></div></details>
    </article>
    <article class="card">
      <h2>Incidents by category</h2>
      <p class="card-sub">Where the support demand comes from</p>
      <div class="chart" id="ch-category"></div>
      <details><summary>Table view</summary><div class="table-scroll" id="tb-category"></div></details>
    </article>
    <article class="card">
      <h2>Resolution SLA by priority</h2>
      <p class="card-sub">Share of resolved incidents within target; the tick on each bar marks its attainment target</p>
      <div class="chart" id="ch-sla"></div>
      <details><summary>Table view</summary><div class="table-scroll" id="tb-sla"></div></details>
    </article>
    <article class="card">
      <h2>Open backlog by age</h2>
      <p class="card-sub" id="sub-aging"></p>
      <div class="chart" id="ch-aging"></div>
      <details><summary>Table view</summary><div class="table-scroll" id="tb-aging"></div></details>
    </article>
    <article class="card">
      <h2>How tickets arrive</h2>
      <p class="card-sub">Contact channel, share of all tickets</p>
      <div class="chart" id="ch-channel"></div>
      <div class="legend" id="lg-channel"></div>
      <h2 style="margin-top:18px">Incidents by platform</h2>
      <p class="card-sub">Windows, Mac and mobile support mix</p>
      <div class="chart" id="ch-platform"></div>
      <div class="legend" id="lg-platform"></div>
      <details><summary>Table view</summary><div class="table-scroll" id="tb-mix"></div></details>
    </article>
    <article class="card wide">
      <h2>Recurring issues and problem candidates</h2>
      <p class="card-sub">Review trigger: 3 or more incidents with the same symptom within 7 days. Problem candidate: 5 or more in 7 days at 3x the normal rate, which suggests a common root cause</p>
      <div class="table-scroll" id="tb-recurring"></div>
    </article>
    <article class="card wide">
      <h2>Insights and recommended actions</h2>
      <ul class="insights" id="insights"></ul>
    </article>
    <article class="card wide">
      <h2>Resolver group performance</h2>
      <div class="table-scroll" id="tb-groups"></div>
    </article>
  </section>
  <footer>
    <div id="footnote"></div>
    <dl>
      <dt>Resolution SLA</dt><dd>Resolved within the priority target (P1 4 h, P2 8 h, P3 24 h, P4 72 h, P5 120 h), calendar hours, no pause states.</dd>
      <dt>Response SLA</dt><dd>Acknowledged within P1 15 min, P2 30 min, P3 2 h, P4 8 h, P5 24 h.</dd>
      <dt>First-contact resolution</dt><dd>Incident resolved by the Service Desk on the first contact without reassignment.</dd>
      <dt>Problem candidate</dt><dd>Same symptom 5+ times within 7 days and at least 3x its normal weekly rate. Any symptom seen 3+ times in 7 days meets the review trigger.</dd>
      <dt>Aged backlog</dt><dd>Open tickets older than 14 days, as of the end date (a snapshot that does not change with the range).</dd>
    </dl>
  </footer>
</main>
<div class="tooltip" id="tooltip" role="status" aria-live="polite" hidden></div>
<script id="dashboard-data" type="application/json">__DATA__</script>
<script>
(function () {
  'use strict';
  var DATA = JSON.parse(document.getElementById('dashboard-data').textContent);
  var SVGNS = 'http://www.w3.org/2000/svg';
  var SERIES = ['--series-1', '--series-2', '--series-3', '--series-4', '--series-5', '--series-6'];
  var ON_FILL = ['--on-fill', '--on-fill', '--on-fill', '--on-fill-4', '--on-fill', '--on-fill'];
  var nf0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
  var nf1 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  function byId(id) { return document.getElementById(id); }
  function pct(v) { return v === null || v === undefined ? 'n/a' : nf1.format(v) + '%'; }
  function hrs(v) { return v === null || v === undefined ? 'n/a' : (v < 10 ? nf1.format(v) : nf0.format(v)) + ' h'; }
  function svgEl(tag, attrs, parent) {
    var n = document.createElementNS(SVGNS, tag);
    if (attrs) { Object.keys(attrs).forEach(function (k) { n.setAttribute(k, attrs[k]); }); }
    if (parent) { parent.appendChild(n); }
    return n;
  }
  function htmlEl(tag, cls, text, parent) {
    var n = document.createElement(tag);
    if (cls) { n.className = cls; }
    if (text !== undefined && text !== null) { n.textContent = text; }
    if (parent) { parent.appendChild(n); }
    return n;
  }
  function svgText(parent, x, y, text, cls, anchor) {
    var t = svgEl('text', { x: x, y: y, 'class': cls }, parent);
    if (anchor) { t.setAttribute('text-anchor', anchor); }
    t.textContent = text;
    return t;
  }
  var ctx = document.createElement('canvas').getContext('2d');
  function textWidth(t, size, weight) {
    ctx.font = (weight || 400) + ' ' + (size || 12) + 'px system-ui, -apple-system, "Segoe UI", sans-serif';
    return ctx.measureText(String(t)).width;
  }
  function weekLabel(iso) {
    var d = new Date(iso + 'T00:00:00');
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  }
  function niceScale(max, count) {
    count = count || 4;
    if (!(max > 0)) { return { top: 4, step: 1 }; }
    var raw = max / count, mag = Math.pow(10, Math.floor(Math.log10(raw))), norm = raw / mag;
    var step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * mag;
    step = Math.max(1, Math.round(step));
    return { top: Math.ceil(max / step) * step, step: step };
  }

  /* ---------- tooltip ---------- */
  var tip = byId('tooltip');
  function tipShow(t, x, y) {
    tip.replaceChildren();
    if (t.title) { htmlEl('div', 'tt-title', t.title, tip); }
    t.rows.forEach(function (r) {
      var row = htmlEl('div', 'tt-row', null, tip);
      if (r.color) { var k = htmlEl('span', 'tt-key ' + (r.key || 'rect'), null, row); k.style.background = 'var(' + r.color + ')'; }
      htmlEl('span', 'tt-value', r.value, row);
      if (r.label) { htmlEl('span', 'tt-label', r.label, row); }
    });
    tip.hidden = false;
    var pad = 14, w = tip.offsetWidth, h = tip.offsetHeight;
    var left = x + pad, top = y + pad;
    if (left + w > window.innerWidth - 8) { left = x - w - pad; }
    if (top + h > window.innerHeight - 8) { top = y - h - pad; }
    tip.style.left = Math.max(8, left) + 'px';
    tip.style.top = Math.max(8, top) + 'px';
  }
  function tipHide() { tip.hidden = true; }
  function bindMark(node, getTip) {
    node.setAttribute('tabindex', '0');
    node.addEventListener('pointermove', function (e) { tipShow(getTip(), e.clientX, e.clientY); });
    node.addEventListener('pointerleave', tipHide);
    node.addEventListener('focus', function () { var b = node.getBoundingClientRect(); tipShow(getTip(), b.left + b.width / 2, b.top); });
    node.addEventListener('blur', tipHide);
  }

  /* ---------- chart primitives ---------- */
  function hBarPath(x0, y, x1, h) {
    var w = x1 - x0; if (w <= 0.5) { return ''; }
    var r = Math.min(4, w, h / 2);
    return 'M' + x0 + ',' + y + 'H' + (x1 - r) + 'Q' + x1 + ',' + y + ' ' + x1 + ',' + (y + r) + 'V' + (y + h - r) +
      'Q' + x1 + ',' + (y + h) + ' ' + (x1 - r) + ',' + (y + h) + 'H' + x0 + 'Z';
  }
  function colPath(x, yTop, w, yBase) {
    var h = yBase - yTop; if (h <= 0.5) { return ''; }
    var r = Math.min(4, h, w / 2);
    return 'M' + x + ',' + yBase + 'V' + (yTop + r) + 'Q' + x + ',' + yTop + ' ' + (x + r) + ',' + yTop + 'H' + (x + w - r) +
      'Q' + (x + w) + ',' + yTop + ' ' + (x + w) + ',' + (yTop + r) + 'V' + yBase + 'Z';
  }

  function lineChart(host, rows, series) {
    host.replaceChildren();
    if (!rows.length) { htmlEl('p', 'card-sub', 'No complete weeks in this range.', host); return; }
    var W = Math.max(280, host.clientWidth), H = 250;
    var labelW = Math.max.apply(null, series.map(function (s) { return textWidth(s.label, 12); })) + 16;
    var m = { t: 12, r: labelW + 6, b: 28, l: 36 };
    var iw = W - m.l - m.r, ih = H - m.t - m.b;
    var max = 1;
    rows.forEach(function (r) { series.forEach(function (s) { max = Math.max(max, r[s.key]); }); });
    var sc = niceScale(max);
    function xs(i) { return m.l + (rows.length <= 1 ? iw / 2 : (i * iw) / (rows.length - 1)); }
    function ys(v) { return m.t + ih - (v / sc.top) * ih; }
    var svg = svgEl('svg', { width: W, height: H, viewBox: '0 0 ' + W + ' ' + H, role: 'img',
      'aria-label': series.map(function (s) { return s.label; }).join(' and ') + ' per week over ' + rows.length + ' weeks' }, host);
    for (var v = 0; v <= sc.top + 1e-9; v += sc.step) {
      svgEl('line', { x1: m.l, x2: m.l + iw, y1: ys(v), y2: ys(v), 'class': v === 0 ? 'axis' : 'gridline' }, svg);
      svgText(svg, m.l - 8, ys(v) + 4, nf0.format(v), 'tick', 'end');
    }
    var every = Math.max(1, Math.ceil((rows.length * 50) / iw));
    rows.forEach(function (r, i) { if ((rows.length - 1 - i) % every === 0) { svgText(svg, xs(i), H - 8, weekLabel(r.week), 'tick', 'middle'); } });
    series.forEach(function (s) {
      var d = rows.map(function (r, i) { return (i ? 'L' : 'M') + xs(i).toFixed(1) + ',' + ys(r[s.key]).toFixed(1); }).join('');
      svgEl('path', { d: d, 'class': 'series-line' }, svg).style.stroke = 'var(' + s.color + ')';
    });
    var last = rows.length - 1;
    var ends = series.map(function (s) { return { s: s, y: ys(rows[last][s.key]) }; });
    var collide = false;
    ends.forEach(function (a, i) { ends.forEach(function (b, j) { if (i < j && Math.abs(a.y - b.y) < 14) { collide = true; } }); });
    ends.forEach(function (e) {
      svgEl('circle', { cx: xs(last), cy: e.y, r: 4, 'class': 'dot' }, svg).style.fill = 'var(' + e.s.color + ')';
      if (!collide) { svgText(svg, xs(last) + 10, e.y + 4, e.s.label, 'direct'); }
    });
    var cross = svgEl('line', { y1: m.t, y2: m.t + ih, 'class': 'crosshair', visibility: 'hidden' }, svg);
    var hoverDots = series.map(function (s) {
      var c = svgEl('circle', { r: 4, 'class': 'dot', visibility: 'hidden' }, svg);
      c.style.fill = 'var(' + s.color + ')';
      return c;
    });
    var overlay = svgEl('rect', { x: m.l - 6, y: m.t, width: iw + 12, height: ih, fill: 'transparent', 'class': 'overlay',
      tabindex: '0', role: 'img', 'aria-label': 'Weekly values. Use the left and right arrow keys to move between weeks.' }, svg);
    var idx = last;
    function show(i, cx, cy) {
      idx = Math.max(0, Math.min(last, i));
      var x = xs(idx);
      cross.setAttribute('x1', x); cross.setAttribute('x2', x); cross.setAttribute('visibility', 'visible');
      series.forEach(function (s, si) {
        hoverDots[si].setAttribute('cx', x); hoverDots[si].setAttribute('cy', ys(rows[idx][s.key]));
        hoverDots[si].setAttribute('visibility', 'visible');
      });
      tipShow({ title: 'Week of ' + weekLabel(rows[idx].week), rows: series.map(function (s) {
        return { key: 'line', color: s.color, value: nf0.format(rows[idx][s.key]), label: s.label };
      }) }, cx, cy);
    }
    function hide() {
      cross.setAttribute('visibility', 'hidden');
      hoverDots.forEach(function (d) { d.setAttribute('visibility', 'hidden'); });
      tipHide();
    }
    overlay.addEventListener('pointermove', function (e) {
      var b = svg.getBoundingClientRect();
      show(Math.round(((e.clientX - b.left - m.l) / iw) * last), e.clientX, e.clientY);
    });
    overlay.addEventListener('pointerleave', hide);
    overlay.addEventListener('focus', function () { var b = svg.getBoundingClientRect(); show(idx, b.left + xs(idx), b.top + m.t + 20); });
    overlay.addEventListener('blur', hide);
    overlay.addEventListener('keydown', function (e) {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') { return; }
      e.preventDefault();
      var next = Math.max(0, Math.min(last, idx + (e.key === 'ArrowRight' ? 1 : -1)));
      var b = svg.getBoundingClientRect();
      show(next, b.left + xs(next), b.top + m.t + 20);
    });
  }

  function hBarChart(host, items, opt) {
    host.replaceChildren();
    if (!items.length) { htmlEl('p', 'card-sub', 'No data in this range.', host); return; }
    opt = opt || {};
    var W = Math.max(280, host.clientWidth);
    var barH = 18, gap = 12, rowH = barH + gap;
    var labelW = Math.min(W * 0.42, Math.max.apply(null, items.map(function (it) { return textWidth(it.label, 12); })) + 12);
    var valueW = Math.max.apply(null, items.map(function (it) { return textWidth(it.display, 12, 600); })) + 12;
    var m = { t: 2, r: valueW, b: 2, l: labelW };
    var iw = Math.max(40, W - m.l - m.r);
    var H = m.t + m.b + items.length * rowH;
    var max = opt.max || Math.max.apply(null, items.map(function (it) { return it.value; })) || 1;
    function xs(v) { return m.l + (Math.max(0, v) / max) * iw; }
    var svg = svgEl('svg', { width: W, height: H, viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': opt.aria || 'Bar chart' }, host);
    svgEl('line', { x1: m.l, x2: m.l, y1: m.t, y2: H - m.b, 'class': 'axis' }, svg);
    items.forEach(function (it, i) {
      var y = m.t + i * rowH + gap / 2;
      var g = svgEl('g', { 'class': 'mark', role: 'img', 'aria-label': it.aria }, svg);
      svgEl('rect', { x: 0, y: y - gap / 2, width: W, height: rowH, fill: 'transparent' }, g);
      svgText(g, m.l - 8, y + barH / 2 + 4, it.label, 'cat', 'end');
      var x1 = xs(it.value);
      var path = hBarPath(m.l, y, x1, barH);
      if (path) { svgEl('path', { d: path, 'class': 'bar' }, g).style.fill = 'var(' + (opt.color || '--series-1') + ')'; }
      if (it.target !== undefined && it.target !== null) {
        var tx = xs(it.target);
        svgEl('line', { x1: tx, x2: tx, y1: y - 3, y2: y + barH + 3, 'class': 'target' }, g);
      }
      if (opt.valueColumn) { svgText(g, W - 2, y + barH / 2 + 4, it.display, 'val', 'end'); }
      else { svgText(g, x1 + 6, y + barH / 2 + 4, it.display, 'val'); }
      bindMark(g, function () { return it.tip; });
    });
  }

  function columnChart(host, items, opt) {
    host.replaceChildren();
    opt = opt || {};
    var W = Math.max(260, host.clientWidth), H = 200;
    var m = { t: 22, r: 8, b: 28, l: 8 };
    var iw = W - m.l - m.r, ih = H - m.t - m.b;
    var max = Math.max(1, Math.max.apply(null, items.map(function (it) { return it.value; })));
    var slot = iw / items.length, bw = Math.min(24, slot * 0.5);
    var svg = svgEl('svg', { width: W, height: H, viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': opt.aria || 'Column chart' }, host);
    var base = m.t + ih;
    svgEl('line', { x1: m.l, x2: m.l + iw, y1: base, y2: base, 'class': 'axis' }, svg);
    items.forEach(function (it, i) {
      var cx = m.l + slot * i + slot / 2;
      var yTop = base - (it.value / max) * ih;
      var g = svgEl('g', { 'class': 'mark', role: 'img', 'aria-label': it.aria }, svg);
      svgEl('rect', { x: cx - slot / 2 + 2, y: m.t - 20, width: slot - 4, height: ih + 20, fill: 'transparent' }, g);
      var path = colPath(cx - bw / 2, yTop, bw, base);
      if (path) { svgEl('path', { d: path, 'class': 'bar' }, g).style.fill = 'var(' + (opt.color || '--series-1') + ')'; }
      svgText(g, cx, Math.min(yTop, base) - 6, it.display, 'val', 'middle');
      svgText(g, cx, H - 8, it.label, 'tick', 'middle');
      bindMark(g, function () { return it.tip; });
    });
  }

  function segmentedBar(host, legendHost, items, noun) {
    host.replaceChildren(); legendHost.replaceChildren();
    var parts = items.filter(function (it) { return it.count > 0; });
    var total = parts.reduce(function (a, b) { return a + b.count; }, 0);
    if (!total) { htmlEl('p', 'card-sub', 'No data in this range.', host); return; }
    var W = Math.max(260, host.clientWidth), H = 28, gapPx = 2;
    var avail = W - gapPx * (parts.length - 1);
    var svg = svgEl('svg', { width: W, height: H, viewBox: '0 0 ' + W + ' ' + H, role: 'img',
      'aria-label': parts.map(function (p) { return p.name + ' ' + Math.round((100 * p.count) / total) + '%'; }).join(', ') }, host);
    var x = 0;
    parts.forEach(function (p) {
      var w = (p.count / total) * avail;
      var share = Math.round((100 * p.count) / total) + '%';
      var g = svgEl('g', { 'class': 'mark', role: 'img', 'aria-label': p.name + ': ' + nf0.format(p.count) + ' (' + share + ')' }, svg);
      var r = svgEl('rect', { x: x, y: 0, width: Math.max(1, w), height: H, rx: Math.min(4, w / 2), 'class': 'seg' }, g);
      r.style.fill = 'var(' + SERIES[p.slot] + ')';
      if (textWidth(share, 12, 600) + 14 <= w) {
        svgText(g, x + 7, H / 2 + 4, share, 'seg-label').style.fill = 'var(' + ON_FILL[p.slot] + ')';
      }
      bindMark(g, function () { return { title: p.name, rows: [{ key: 'rect', color: SERIES[p.slot], value: nf0.format(p.count), label: share + ' of ' + noun }] }; });
      x += w + gapPx;
    });
    parts.forEach(function (p) {
      var li = htmlEl('span', 'lg-item', null, legendHost);
      htmlEl('span', 'lg-swatch', null, li).style.background = 'var(' + SERIES[p.slot] + ')';
      htmlEl('span', null, p.name, li);
    });
  }

  function table(host, headers, rows, numeric) {
    host.replaceChildren();
    numeric = numeric || [];
    var t = htmlEl('table', null, null, host);
    var tr = htmlEl('tr', null, null, htmlEl('thead', null, null, t));
    headers.forEach(function (hd, i) { var th = htmlEl('th', numeric.indexOf(i) >= 0 ? 'num' : null, hd, tr); th.scope = 'col'; });
    var tb = htmlEl('tbody', null, null, t);
    rows.forEach(function (r) {
      var row = htmlEl('tr', null, null, tb);
      r.forEach(function (c, i) { htmlEl('td', numeric.indexOf(i) >= 0 ? 'num' : null, c, row); });
    });
  }

  function statusIcon(parent, kind) {
    var svg = svgEl('svg', { width: 14, height: 14, viewBox: '0 0 14 14', 'aria-hidden': 'true' }, parent);
    var cls = { good: 'st-good', bad: 'st-crit', action: 'st-serious', watch: 'st-warn' }[kind];
    svgEl('circle', { cx: 7, cy: 7, r: 7, 'class': cls }, svg);
    var dark = kind === 'watch' ? ' dark' : '';
    if (kind === 'good') { svgEl('path', { d: 'M4 7.3l2 2 4-4.5', 'class': 'st-glyph' }, svg); }
    else { svgEl('path', { d: 'M7 3.6v4.3', 'class': 'st-glyph' + dark }, svg); svgEl('circle', { cx: 7, cy: 10.3, r: 1, 'class': 'st-dot' + dark }, svg); }
  }
  function statusBadge(parent, ok) {
    if (ok === null || ok === undefined) { return; }
    var b = htmlEl('span', 'status', null, parent);
    statusIcon(b, ok ? 'good' : 'bad');
    htmlEl('span', null, ok ? 'Meets target' : 'Misses target', b);
  }

  function sparkline(host, rows, target) {
    host.replaceChildren();
    var pts = rows.filter(function (r) { return r.sla !== null && r.sla !== undefined; }).slice(-12);
    if (pts.length < 2) { return; }
    var W = Math.max(160, host.clientWidth), H = 56, m = { t: 6, r: 8, b: 6, l: 4 };
    var iw = W - m.l - m.r, ih = H - m.t - m.b;
    var lo = Math.min(target, Math.min.apply(null, pts.map(function (p) { return p.sla; }))) - 5;
    lo = Math.max(0, Math.floor(lo / 5) * 5);
    function xs(i) { return m.l + (i * iw) / (pts.length - 1); }
    function ys(v) { return m.t + ih - ((v - lo) / (100 - lo)) * ih; }
    var svg = svgEl('svg', { width: W, height: H, viewBox: '0 0 ' + W + ' ' + H, role: 'img',
      'aria-label': 'Weekly resolution SLA attainment for the last ' + pts.length + ' weeks' }, host);
    svgEl('line', { x1: m.l, x2: m.l + iw, y1: ys(target), y2: ys(target), 'class': 'gridline' }, svg);
    var d = pts.map(function (p, i) { return (i ? 'L' : 'M') + xs(i).toFixed(1) + ',' + ys(p.sla).toFixed(1); }).join('');
    svgEl('path', { d: d, 'class': 'series-line spark-line' }, svg);
    var lastI = pts.length - 1;
    svgEl('circle', { cx: xs(lastI), cy: ys(pts[lastI].sla), r: 4, 'class': 'dot' }, svg).style.fill = 'var(--series-1)';
    var hover = svgEl('circle', { r: 4, 'class': 'dot', visibility: 'hidden' }, svg);
    hover.style.fill = 'var(--text-muted)';
    var ov = svgEl('rect', { x: 0, y: 0, width: W, height: H, fill: 'transparent', 'class': 'overlay', tabindex: '0', role: 'img',
      'aria-label': 'Weekly SLA values. Use the left and right arrow keys.' }, svg);
    var idx = lastI;
    function show(i, cx, cy) {
      idx = Math.max(0, Math.min(lastI, i));
      hover.setAttribute('cx', xs(idx)); hover.setAttribute('cy', ys(pts[idx].sla)); hover.setAttribute('visibility', 'visible');
      tipShow({ title: 'Week of ' + weekLabel(pts[idx].week), rows: [{ key: 'line', color: '--text-muted', value: pct(pts[idx].sla), label: 'resolved within SLA' }] }, cx, cy);
    }
    function hide() { hover.setAttribute('visibility', 'hidden'); tipHide(); }
    ov.addEventListener('pointermove', function (e) { var b = svg.getBoundingClientRect(); show(Math.round(((e.clientX - b.left - m.l) / iw) * lastI), e.clientX, e.clientY); });
    ov.addEventListener('pointerleave', hide);
    ov.addEventListener('focus', function () { var b = svg.getBoundingClientRect(); show(idx, b.left + xs(idx), b.top); });
    ov.addEventListener('blur', hide);
    ov.addEventListener('keydown', function (e) {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') { return; }
      e.preventDefault();
      var next = Math.max(0, Math.min(lastI, idx + (e.key === 'ArrowRight' ? 1 : -1)));
      var b = svg.getBoundingClientRect(); show(next, b.left + xs(next), b.top);
    });
  }

  /* ---------- page ---------- */
  var order = DATA.windowOrder, current = DATA.defaultWindow;
  try { var saved = window.localStorage.getItem('sdm-window'); if (saved && DATA.windows[saved]) { current = saved; } } catch (e) { /* storage unavailable */ }

  function renderFilters() {
    var host = byId('filters');
    host.replaceChildren();
    order.forEach(function (key) {
      var b = htmlEl('button', null, null, host);
      b.type = 'button';
      b.setAttribute('aria-pressed', key === current ? 'true' : 'false');
      var chk = svgEl('svg', { 'class': 'check', viewBox: '0 0 16 16', 'aria-hidden': 'true' }, b);
      svgEl('path', { d: 'M3.5 8.5l3 3 6-7', fill: 'none', stroke: 'currentColor', 'stroke-width': '2.2', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, chk);
      htmlEl('span', null, DATA.windows[key].label, b);
      b.addEventListener('click', function () {
        current = key;
        try { window.localStorage.setItem('sdm-window', key); } catch (e) { /* ignore */ }
        renderFilters(); renderAll();
      });
    });
  }

  function renderStatic(w) {
    byId('eyebrow').textContent = DATA.meta.title;
    byId('subtitle').textContent = DATA.meta.note + ' · ' + w.start + ' to ' + w.end + ' · ' + nf0.format(DATA.meta.rows) + ' tickets in ' + DATA.meta.source;
    byId('footnote').textContent = 'Generated ' + DATA.meta.generatedAt + ' by scripts/python/ticket_metrics.py. Hover or focus any mark for details; every chart has a table view.';
    var hero = byId('hero'); hero.replaceChildren();
    htmlEl('div', 'hero-label', w.hero.label, hero);
    htmlEl('div', 'hero-value', w.hero.display, hero);
    htmlEl('div', 'hero-sub', w.hero.sub, hero);
    var row = htmlEl('div', 'tile-sub', w.hero.target + '  ', hero);
    statusBadge(row, w.hero.ok);
    var spark = htmlEl('div', 'spark', null, hero);
    htmlEl('div', 'tile-sub', 'Weekly attainment; the hairline marks the target', spark);
    htmlEl('div', null, null, spark).id = 'hero-spark';
    var tiles = byId('tiles'); tiles.replaceChildren();
    w.tiles.forEach(function (t) {
      var c = htmlEl('div', 'tile', null, tiles);
      htmlEl('div', 'tile-label', t.label, c);
      htmlEl('div', 'tile-value', t.display, c);
      htmlEl('div', 'tile-sub', t.sub, c);
      statusBadge(c, t.ok);
    });
    var ins = byId('insights'); ins.replaceChildren();
    w.insights.forEach(function (i) {
      var li = htmlEl('li', null, null, ins);
      var badge = htmlEl('span', 'badge', null, li);
      statusIcon(badge, i.level === 'good' ? 'good' : i.level);
      htmlEl('span', null, { action: 'Act', watch: 'Watch', good: 'On track' }[i.level], badge);
      htmlEl('span', null, i.text, li);
    });
    byId('sub-aging').textContent = 'Open tickets by age as of ' + w.end + ' (snapshot)';
    table(byId('tb-weekly'), ['Week of', 'Incidents', 'Requests'], w.weekly.map(function (r) { return [weekLabel(r.week), nf0.format(r.incidents), nf0.format(r.requests)]; }), [1, 2]);
    table(byId('tb-category'), ['Category', 'Incidents', 'Share'], w.byCategory.map(function (c) { return [c.name, nf0.format(c.count), pct(c.share)]; }), [1, 2]);
    table(byId('tb-sla'), ['Priority', 'Resolved', 'Met', 'Attainment', 'Target', 'Median', 'SLA'],
      w.slaByPriority.map(function (s) { return [s.priority, nf0.format(s.n), nf0.format(s.met), pct(s.attainment), nf0.format(s.target) + '%', hrs(s.medianH), s.targetH + ' h']; }), [1, 2, 3, 4, 5, 6]);
    table(byId('tb-aging'), ['Age', 'Open tickets'], w.aging.map(function (a) { return [a.bucket, nf0.format(a.count)]; }), [1]);
    var chTotal = w.channels.reduce(function (a, b) { return a + b.count; }, 0);
    var plTotal = w.platforms.reduce(function (a, b) { return a + b.count; }, 0);
    table(byId('tb-mix'), ['Breakdown', 'Value', 'Tickets', 'Share'],
      w.channels.map(function (c) { return ['Channel', c.name, nf0.format(c.count), pct(chTotal ? (100 * c.count) / chTotal : null)]; })
        .concat(w.platforms.map(function (p) { return ['Platform (incidents)', p.name, nf0.format(p.count), pct(plTotal ? (100 * p.count) / plTotal : null)]; })), [2, 3]);
    table(byId('tb-recurring'), ['Issue', 'Category', 'Incidents', 'Peak in 7 days', 'Users', 'Seen', 'Suggested action'],
      w.recurring.map(function (r) { return [r.issue, r.category, nf0.format(r.count), r.peak7 + ' from ' + r.peakStart, nf0.format(r.users), r.first + ' to ' + r.last, r.action]; }), [2, 3, 4]);
    table(byId('tb-groups'), ['Group', 'Incidents', 'Resolved', 'Median resolve', 'Resolution SLA', 'Reassigned 2+'],
      w.groups.map(function (g) { return [g.name, nf0.format(g.count), nf0.format(g.resolved), hrs(g.medianH), pct(g.sla), pct(g.reassign)]; }), [1, 2, 3, 4, 5]);
  }

  function renderCharts(w) {
    var series = [{ key: 'incidents', label: 'Incidents', color: '--series-1' }, { key: 'requests', label: 'Requests', color: '--series-2' }];
    var lg = byId('lg-weekly'); lg.replaceChildren();
    series.forEach(function (s) { var li = htmlEl('span', 'lg-item', null, lg); htmlEl('span', 'lg-line', null, li).style.background = 'var(' + s.color + ')'; htmlEl('span', null, s.label, li); });
    lineChart(byId('ch-weekly'), w.weekly, series);
    var incTotal = w.kpis.incidents || 1;
    hBarChart(byId('ch-category'), w.byCategory.map(function (c) {
      return { label: c.name, value: c.count, display: nf0.format(c.count), aria: c.name + ': ' + c.count + ' incidents',
        tip: { title: c.name, rows: [{ key: 'rect', color: '--series-1', value: nf0.format(c.count), label: 'incidents (' + pct((100 * c.count) / incTotal) + ')' }] } };
    }), { aria: 'Incidents by category' });
    hBarChart(byId('ch-sla'), w.slaByPriority.map(function (s) {
      var shown = s.n ? pct(s.attainment) : 'none';
      return { label: s.priority, value: s.attainment || 0, target: s.n ? s.target : null, display: shown,
        aria: s.priority + ': ' + shown + ' within ' + s.targetH + ' hours, target ' + s.target + ' percent',
        tip: { title: s.priority + ' · target ' + s.target + '% within ' + s.targetH + ' h', rows: [
          { key: 'rect', color: '--series-1', value: shown, label: s.met + ' of ' + s.n + ' resolved in time' },
          { value: hrs(s.medianH), label: 'median time to resolve' }] } };
    }), { max: 100, valueColumn: true, aria: 'Resolution SLA attainment by priority' });
    columnChart(byId('ch-aging'), w.aging.map(function (a) {
      return { label: a.bucket, value: a.count, display: nf0.format(a.count), aria: a.bucket + ': ' + a.count + ' open',
        tip: { title: a.bucket, rows: [{ key: 'rect', color: '--series-1', value: nf0.format(a.count), label: 'open tickets' }] } };
    }), { aria: 'Open backlog by age' });
    segmentedBar(byId('ch-channel'), byId('lg-channel'), w.channels, 'tickets');
    segmentedBar(byId('ch-platform'), byId('lg-platform'), w.platforms, 'incidents');
    sparkline(byId('hero-spark'), w.weekly, w.hero.targetValue);
  }

  function renderAll() { var w = DATA.windows[current]; renderStatic(w); renderCharts(w); }

  renderFilters();
  renderAll();
  var lastWidth = document.querySelector('main').clientWidth, timer = null;
  if (window.ResizeObserver) {
    new ResizeObserver(function () {
      var wNow = document.querySelector('main').clientWidth;
      if (Math.abs(wNow - lastWidth) < 4) { return; }
      lastWidth = wNow;
      clearTimeout(timer);
      timer = setTimeout(function () { renderCharts(DATA.windows[current]); }, 120);
    }).observe(document.querySelector('main'));
  }
})();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    raise SystemExit(main())
