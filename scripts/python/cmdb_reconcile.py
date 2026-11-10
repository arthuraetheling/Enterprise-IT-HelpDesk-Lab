#!/usr/bin/env python3
"""
cmdb_reconcile.py - CMDB data-quality check: discovered inventory vs. the CMDB (standard library only).

Inputs
  --cmdb       CSV export of the CMDB computer class (ServiceNow list export: name, serial_number,
               install_status, last_discovered, os_version, ram, assigned_to, ...)
  --inventory  folder (or file) of inventory JSON produced by scripts/powershell/endpoint/Get-EndpointInventory.ps1
               or scripts/bash/macos_health_check.sh --json

Findings (control BC-11 "asset/CMDB accuracy")
  UNREGISTERED   device seen by discovery but missing from the CMDB                     High
  RETIRED_ONLINE CMDB says retired/disposed but the device is still reporting            High
  DUPLICATE_CI   two or more CIs share one serial number                                 High
  STALE_CI       active CI not discovered for more than --stale-days                     Medium
  BAD_SERIAL     missing or placeholder serial ("To be filled by O.E.M.")                Medium
  OWNER_DRIFT    CMDB assigned_to differs from the user actually signed in               Medium
  RENAMED        matched on serial, but the hostname changed                             Low
  OS_DRIFT / RAM_DRIFT  attribute out of date in the CMDB                                Low

Outputs: reports/cmdb-reconciliation.md and reports/cmdb-reconciliation.csv
Usage:   python scripts/python/cmdb_reconcile.py [--cmdb data/cmdb_export.csv] [--inventory data/inventory] [--stale-days 30]
"""
from __future__ import annotations

import argparse
import csv
import json
import re
from datetime import datetime, timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PLACEHOLDER_SERIALS = {"", "to be filled by o.e.m.", "default string", "system serial number", "0", "none", "n/a", "123456789"}
ACTIVE_STATES = {"installed", "in use", "1", "pending install", "in maintenance"}
RETIRED_STATES = {"retired", "disposed", "7", "stolen", "lost", "absent"}
COMPUTER_CLASSES = {"cmdb_ci_computer", "cmdb_ci_win_server", "cmdb_ci_linux_server", "cmdb_ci_server", ""}
SEVERITY_ORDER = {"High": 0, "Medium": 1, "Low": 2}


def parse_dt(value: str):
    value = (value or "").strip()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d", "%m/%d/%Y %H:%M:%S"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def norm_serial(value: str) -> str:
    return re.sub(r"\s+", " ", (value or "").strip()).upper()


def is_placeholder(serial: str) -> bool:
    return serial.strip().lower() in PLACEHOLDER_SERIALS


def norm_user(value: str) -> str:
    return (value or "").split("\\")[-1].split("@")[0].strip().lower()


def os_key(value: str) -> str:
    """Comparable OS version: feature release + build, e.g. '25H2 (26200.9711)' -> '25H2 26200'."""
    v = (value or "").upper()
    feature = re.search(r"\b\d{2}H\d\b", v)
    build = re.search(r"\b(\d{5})(?:\.\d+)?\b", v)
    mac = re.search(r"\b(1[0-9]|2[0-9])\.\d+(?:\.\d+)?\b", v)
    parts = [m.group(0) if m is feature else m.group(1) for m in (feature, build) if m]
    if not parts and mac:
        parts = [mac.group(0)]
    return " ".join(parts) or v.strip()


def load_cmdb(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig", newline="") as fh:
        rows = [{k.strip().lower(): (v or "").strip() for k, v in r.items()} for r in csv.DictReader(fh)]
    for r in rows:
        r["_serial"] = norm_serial(r.get("serial_number", ""))
        r["_name"] = r.get("name", "").upper()
        r["_state"] = r.get("install_status", "").lower()
        r["_last"] = parse_dt(r.get("last_discovered", ""))
    return rows


def load_inventory(path: Path) -> list[dict]:
    files = sorted(path.glob("*.json")) if path.is_dir() else [path]
    out = []
    for f in files:
        data = json.loads(f.read_text(encoding="utf-8-sig"))
        os_info = data.get("OS") or {}
        ram_gb = data.get("MemoryGB")
        if ram_gb is None and data.get("MemoryMB"):
            ram_gb = round(float(data["MemoryMB"]) / 1024)
        out.append({
            "file": f.name,
            "name": str(data.get("ComputerName") or data.get("hostname") or f.stem).upper(),
            "serial": norm_serial(str(data.get("SerialNumber") or data.get("serial_number") or "")),
            "model": data.get("Model") or "",
            "os": f"{os_info.get('Name', '')} {os_info.get('DisplayVersion', '')} {os_info.get('Build', '')}".strip(),
            "ram_gb": ram_gb,
            "user": norm_user(data.get("LoggedOnUser") or data.get("ConsoleUser") or ""),
            "collected": parse_dt(str(data.get("CollectedAt") or "").replace("Z", "")[:19].replace("T", " ")),
        })
    return out


def reconcile(cmdb: list[dict], inventory: list[dict], as_of: datetime, stale_days: int) -> tuple[list[dict], dict]:
    findings = []

    def add(severity, code, ci, detail, action):
        findings.append({"Severity": severity, "Finding": code, "CI": ci, "Detail": detail, "Action": action})

    by_serial: dict[str, list[dict]] = {}
    for r in cmdb:
        if r["_serial"] and not is_placeholder(r["_serial"]):
            by_serial.setdefault(r["_serial"], []).append(r)
    by_name = {r["_name"]: r for r in cmdb}

    for serial, rows in by_serial.items():
        if len(rows) > 1:
            names = ", ".join(r["name"] for r in rows)
            add("High", "DUPLICATE_CI", names, f"{len(rows)} CIs share serial {serial}", "Merge into one CI; retire the duplicate record")
    for r in cmdb:
        if is_placeholder(r["_serial"]) and r.get("sys_class_name", "") in COMPUTER_CLASSES:
            add("Medium", "BAD_SERIAL", r["name"], f"CMDB serial '{r.get('serial_number', '')}' is missing or a placeholder",
                "Record the real serial from the device / BIOS")

    matched = set()
    for inv in inventory:
        ci, how = None, ""
        if inv["serial"] and not is_placeholder(inv["serial"]) and inv["serial"] in by_serial:
            candidates = by_serial[inv["serial"]]
            ci = next((c for c in candidates if c["_name"] == inv["name"]), candidates[0])
            how = "serial"
        elif inv["name"] in by_name:
            ci, how = by_name[inv["name"]], "name"
        if is_placeholder(inv["serial"]):
            add("Medium", "BAD_SERIAL", inv["name"], f"Device reports placeholder serial '{inv['serial']}'", "Fix the SMBIOS serial (OEM tool) or record the chassis serial")
        if not ci:
            add("High", "UNREGISTERED", inv["name"], f"Seen by discovery ({inv['file']}, {inv['model']}, user {inv['user'] or 'n/a'}) but not in the CMDB",
                "Create the CI (Sync-InventoryToCmdb.ps1) and confirm the device is company-owned")
            continue
        matched.add(id(ci))
        if ci["_state"] in RETIRED_STATES:
            add("High", "RETIRED_ONLINE", ci["name"], f"CMDB status '{ci.get('install_status')}' but the device reported on {inv['collected']:%Y-%m-%d}",
                "Security review: locate the device, disable its computer account, reconcile the asset record")
        if how == "serial" and ci["_name"] != inv["name"]:
            add("Low", "RENAMED", ci["name"], f"Same serial now reports hostname {inv['name']}", "Update the CI name (check naming standard)")
        if how == "name" and ci["_serial"] and not is_placeholder(ci["_serial"]) and inv["serial"] and ci["_serial"] != inv["serial"]:
            add("Medium", "SERIAL_MISMATCH", ci["name"], f"CMDB serial {ci['_serial']} vs device {inv['serial']}", "Hardware swap? Verify and update the CI")
        if how == "name" and is_placeholder(ci["_serial"]) and inv["serial"] and not is_placeholder(inv["serial"]):
            add("Low", "SERIAL_MISMATCH", ci["name"], f"Device reports serial {inv['serial']}", "Write the discovered serial into the CI")
        cmdb_user, inv_user = norm_user(ci.get("assigned_to", "")), inv["user"]
        if cmdb_user and inv_user and cmdb_user != inv_user:
            add("Medium", "OWNER_DRIFT", ci["name"], f"CMDB assigned_to {cmdb_user}, signed-in user {inv_user}",
                "Confirm the owner with the manager; update assigned_to (or recover the device)")
        if ci.get("os_version") and inv["os"] and os_key(ci["os_version"]) != os_key(inv["os"]):
            add("Low", "OS_DRIFT", ci["name"], f"CMDB '{ci.get('os_version')}' vs device '{inv['os']}'", "Refresh the CI from discovery")
        try:
            cmdb_ram_gb = round(float(ci.get("ram") or 0) / 1024)
        except ValueError:
            cmdb_ram_gb = 0
        if cmdb_ram_gb and inv["ram_gb"] and abs(cmdb_ram_gb - float(inv["ram_gb"])) / cmdb_ram_gb > 0.10:
            add("Low", "RAM_DRIFT", ci["name"], f"CMDB {cmdb_ram_gb} GB vs device {inv['ram_gb']} GB", "Refresh the CI from discovery")

    cutoff = as_of - timedelta(days=stale_days)
    for r in cmdb:
        if id(r) in matched or r["_state"] not in ACTIVE_STATES:
            continue
        if r.get("sys_class_name", "") not in COMPUTER_CLASSES:
            continue  # e.g. mobile devices are discovered by MDM, not by this inventory
        if r["_last"] is None or r["_last"] < cutoff:
            last = r["_last"].strftime("%Y-%m-%d") if r["_last"] else "never"
            add("Medium", "STALE_CI", r["name"], f"Last discovered {last} (> {stale_days} days) and not in current inventory",
                "Locate the device (user, last logon); mark Absent or Retired after 60 days")

    findings.sort(key=lambda f: (SEVERITY_ORDER[f["Severity"]], f["Finding"], f["CI"]))
    flagged = {name.strip() for f in findings for name in f["CI"].split(",")}
    computer_cis = [r for r in cmdb if r.get("sys_class_name", "") in COMPUTER_CLASSES]
    clean = [r for r in computer_cis if r["name"] not in flagged]
    stats = {"cmdb_records": len(cmdb), "computer_cis": len(computer_cis), "inventory_devices": len(inventory),
             "findings": len(findings), "clean_cis": len(clean),
             "accuracy": round(100.0 * len(clean) / len(computer_cis), 1) if computer_cis else None}
    return findings, stats


def main() -> int:
    ap = argparse.ArgumentParser(description="Reconcile discovered inventory against a CMDB export")
    ap.add_argument("--cmdb", default=str(REPO / "data" / "cmdb_export.csv"))
    ap.add_argument("--inventory", default=str(REPO / "data" / "inventory"))
    ap.add_argument("--outdir", default=str(REPO / "reports"))
    ap.add_argument("--stale-days", type=int, default=30)
    ap.add_argument("--as-of", help="YYYY-MM-DD (default: newest inventory collection date)")
    args = ap.parse_args()

    cmdb = load_cmdb(Path(args.cmdb))
    inventory = load_inventory(Path(args.inventory))
    if args.as_of:
        as_of = datetime.strptime(args.as_of, "%Y-%m-%d")
    else:
        dates = [i["collected"] for i in inventory if i["collected"]]
        as_of = max(dates) if dates else datetime.now()
    findings, stats = reconcile(cmdb, inventory, as_of, args.stale_days)

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    with (outdir / "cmdb-reconciliation.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=["Severity", "Finding", "CI", "Detail", "Action"])
        writer.writeheader()
        writer.writerows(findings)

    counts = {}
    for f in findings:
        counts[f["Finding"]] = counts.get(f["Finding"], 0) + 1
    md = ["# CMDB Reconciliation Report", "",
          f"As of {as_of:%Y-%m-%d} - {stats['computer_cis']} computer CIs in `{Path(args.cmdb).name}` vs "
          f"{stats['inventory_devices']} devices in `{Path(args.inventory).name}` (stale threshold {args.stale_days} days).", "",
          f"**CI accuracy: {stats['accuracy']}%** ({stats['clean_cis']} of {stats['computer_cis']} computer CIs have no findings) - "
          f"{stats['findings']} findings.", "", "| Finding | Count |", "|---|---:|"]
    md += [f"| {k} | {v} |" for k, v in sorted(counts.items(), key=lambda kv: -kv[1])]
    md += ["", "| Severity | Finding | CI | Detail | Action |", "|---|---|---|---|---|"]
    md += [f"| {f['Severity']} | {f['Finding']} | {f['CI']} | {f['Detail']} | {f['Action']} |" for f in findings]
    md += ["", "Generated by `scripts/python/cmdb_reconcile.py` (control BC-11). Synthetic sample data.", ""]
    (outdir / "cmdb-reconciliation.md").write_text("\n".join(md), encoding="utf-8")

    print(f"CMDB reconciliation as of {as_of:%Y-%m-%d}: {stats['computer_cis']} computer CIs, {stats['inventory_devices']} devices discovered")
    print(f"CI accuracy {stats['accuracy']}% - {stats['findings']} findings")
    for f in findings:
        print(f"  [{f['Severity']:<6}] {f['Finding']:<15} {f['CI']:<26} {f['Detail']}")
    print(f"Wrote {outdir / 'cmdb-reconciliation.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
