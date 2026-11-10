#!/usr/bin/env python3
"""
mock_servicenow.py - offline mock of the ServiceNow Table API for testing the lab integrations.

Implements enough of /api/now/table/{table} to exercise scripts/powershell/integration:
  GET    /api/now/table/{table}?sysparm_query=...&sysparm_fields=...&sysparm_limit=...
  GET    /api/now/table/{table}/{sys_id}
  POST   /api/now/table/{table}
  PATCH  /api/now/table/{table}/{sys_id}       (PUT is accepted as an alias)
  GET    /mock/state                            dump of every record (debugging)
  POST   /mock/reset                            restore the seed data

Encoded-query operators supported: =, !=, STARTSWITH, ENDSWITH, LIKE, ISEMPTY, ISNOTEMPTY joined by ^.
Querying cmdb_ci also searches child classes (cmdb_ci_computer, cmdb_ci_win_server, ...), like the real CMDB.
Incidents get INC009xxxx numbers, priority = impact + urgency - 1 (the default ServiceNow matrix),
active=false once state is 6/7/8, and resolving (state 6) without close_code returns a data-policy error.

Any basic-auth credential is accepted except the password "wrong" (to test 401 handling).
Standard library only.  Usage:  python tests/mock_servicenow.py [--port 8765] [--db mock-db.json]
"""
from __future__ import annotations

import argparse
import base64
import copy
import json
import re
import sys
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

GROUPS = ["Contoso Service Desk", "Contoso Desktop Support", "Contoso Identity & Access",
          "Contoso Network Operations", "Contoso Infrastructure Ops"]
USERS = ["svc.helpdesk.automation", "emma.carter", "olivia.bennett", "marcus.reed", "priya.shah", "daniel.kim"]
COMPANIES = ["Microsoft Corporation", "VMware, Inc.", "LENOVO", "Dell Inc.", "HP", "Apple Inc."]
CIS = [("cmdb_ci_win_server", "DC01"), ("cmdb_ci_linux_server", "MON01"), ("cmdb_ci_computer", "LT-WIN-001")]
CLOSED_STATES = {"6", "7", "8"}
QUERY_RE = re.compile(r"^([a-z0-9_.]+?)(STARTSWITH|ENDSWITH|NOT LIKE|LIKE|ISNOTEMPTY|ISEMPTY|!=|=)(.*)$")

LOCK = threading.Lock()
DB: dict[str, dict[str, dict]] = {}
COUNTERS = {"incident": 90000}
DB_PATH: str | None = None


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def new_id() -> str:
    return uuid.uuid4().hex


def insert(table: str, record: dict) -> dict:
    rec = {k: "" if v is None else str(v) for k, v in record.items()}
    rec.setdefault("sys_id", new_id())
    rec["sys_class_name"] = table
    rec["sys_created_on"] = rec["sys_updated_on"] = now_utc()
    DB.setdefault(table, {})[rec["sys_id"]] = rec
    return rec


def seed() -> None:
    DB.clear()
    COUNTERS["incident"] = 90000
    for g in GROUPS:
        insert("sys_user_group", {"name": g, "active": "true"})
    for u in USERS:
        insert("sys_user", {"user_name": u, "name": u.replace(".", " ").title(), "active": "true"})
    for c in COMPANIES:
        insert("core_company", {"name": c, "manufacturer": "true"})
    for table, name in CIS:
        insert(table, {"name": name, "install_status": "1", "operational_status": "1"})


def persist() -> None:
    if DB_PATH:
        with open(DB_PATH, "w", encoding="utf-8") as fh:
            json.dump(DB, fh, indent=2)


def tables_for(table: str) -> list[str]:
    """cmdb_ci (and task) behave like base classes: include child tables."""
    if table == "cmdb_ci":
        return [t for t in DB if t.startswith("cmdb_ci")]
    return [table]


def matches(rec: dict, query: str) -> bool:
    for term in [t for t in query.split("^") if t and not t.startswith("ORDERBY")]:
        m = QUERY_RE.match(term)
        if not m:
            continue  # unknown operators are ignored, like a permissive mock should
        field, op, value = m.groups()
        actual = rec.get(field, "")
        if field == "active" and "active" not in rec and rec.get("sys_class_name") == "incident":
            actual = "false" if rec.get("state") in CLOSED_STATES else "true"
        if op == "=" and actual != value:
            return False
        if op == "!=" and actual == value:
            return False
        if op == "STARTSWITH" and not actual.startswith(value):
            return False
        if op == "ENDSWITH" and not actual.endswith(value):
            return False
        if op == "LIKE" and value.lower() not in actual.lower():
            return False
        if op == "NOT LIKE" and value.lower() in actual.lower():
            return False
        if op == "ISEMPTY" and actual:
            return False
        if op == "ISNOTEMPTY" and not actual:
            return False
    return True


def project(rec: dict, fields: str | None) -> dict:
    public = {k: v for k, v in rec.items() if not k.startswith("_")}
    if not fields:
        return public
    wanted = [f.strip() for f in fields.split(",") if f.strip()]
    return {f: public.get(f, "") for f in wanted}


def apply_incident_rules(rec: dict, is_new: bool) -> tuple[bool, str]:
    if is_new:
        COUNTERS["incident"] += 1
        rec["number"] = f"INC{COUNTERS['incident']:07d}"
        rec.setdefault("state", "1")
        rec["opened_at"] = now_utc()
    impact, urgency = int(rec.get("impact") or 3), int(rec.get("urgency") or 3)
    rec["priority"] = str(min(5, max(1, impact + urgency - 1)))
    if rec.get("state") == "6":
        if not rec.get("close_code"):
            return False, "Data Policy Exception: Resolution code is mandatory"
        rec.setdefault("resolved_at", now_utc())
    rec["active"] = "false" if rec.get("state") in CLOSED_STATES else "true"
    return True, ""


class Handler(BaseHTTPRequestHandler):
    server_version = "MockServiceNow/1.0"

    # ---- helpers ---------------------------------------------------------------------------
    def log_message(self, fmt, *args):  # silence default logging; we print our own lines
        pass

    def send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json;charset=UTF-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def error(self, status: int, message: str, detail: str = "") -> None:
        self.send_json(status, {"error": {"message": message, "detail": detail}, "status": "failure"})

    def authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            self.error(401, "User Not Authenticated", "Required to provide Auth information")
            return False
        try:
            user, _, password = base64.b64decode(header[6:]).decode("utf-8").partition(":")
        except Exception:  # noqa: BLE001
            self.error(401, "User Not Authenticated", "Malformed Authorization header")
            return False
        if password == "wrong":
            self.error(401, "User Not Authenticated", f"Invalid credentials for {user}")
            return False
        return True

    def body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def route(self):
        url = urlparse(self.path)
        params = {k: v[0] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
        parts = [p for p in url.path.split("/") if p]
        return url.path, parts, params

    def log(self, method: str, path: str, status: int, note: str = "") -> None:
        print(f"{datetime.now():%H:%M:%S} {method:<5} {path} -> {status} {note}".rstrip(), flush=True)

    # ---- verbs -----------------------------------------------------------------------------
    def do_GET(self):
        path, parts, params = self.route()
        if path == "/mock/state":
            with LOCK:
                return self.send_json(200, {"result": DB})
        if not self.authorized():
            return
        if len(parts) < 4 or parts[:3] != ["api", "now", "table"]:
            return self.error(400, "Invalid table API path")
        table = parts[3]
        with LOCK:
            if len(parts) == 5:
                for t in tables_for(table):
                    rec = DB.get(t, {}).get(parts[4])
                    if rec:
                        self.log("GET", path, 200)
                        return self.send_json(200, {"result": project(rec, params.get("sysparm_fields"))})
                self.log("GET", path, 404)
                return self.error(404, "No Record found")
            limit = int(params.get("sysparm_limit") or 10000)
            query = params.get("sysparm_query", "")
            rows = [r for t in tables_for(table) for r in DB.get(t, {}).values() if matches(r, query)]
            result = [project(r, params.get("sysparm_fields")) for r in rows[:limit]]
        self.log("GET", f"{path}?{query}", 200, f"{len(result)} row(s)")
        self.send_json(200, {"result": result})

    def do_POST(self):
        path, parts, params = self.route()
        if path == "/mock/reset":
            with LOCK:
                seed()
                persist()
            self.log("POST", path, 200, "seed data restored")
            return self.send_json(200, {"result": "reset"})
        if not self.authorized():
            return
        if len(parts) != 4 or parts[:3] != ["api", "now", "table"]:
            return self.error(400, "Invalid table API path")
        table = parts[3]
        data = self.body()
        with LOCK:
            rec = {k: "" if v is None else str(v) for k, v in data.items() if k != "work_notes"}
            note = data.get("work_notes")
            if table == "incident":
                ok, msg = apply_incident_rules(rec, is_new=True)
                if not ok:
                    self.log("POST", path, 403, msg)
                    return self.error(403, "Operation Failed", msg)
            rec = insert(table, rec)
            if note:
                rec["_journal"] = json.dumps([{"at": now_utc(), "type": "work_notes", "value": note}])
            persist()
            out = project(rec, params.get("sysparm_fields"))
        label = rec.get("number") or rec.get("name", "")
        extra = f"P{rec['priority']} " if table == "incident" else ""
        self.log("POST", path, 201, f"{label} {extra}{rec.get('short_description', '')}".strip())
        self.send_json(201, {"result": out})

    def do_PATCH(self):
        path, parts, params = self.route()
        if not self.authorized():
            return
        if len(parts) != 5 or parts[:3] != ["api", "now", "table"]:
            return self.error(400, "Invalid table API path")
        table, sys_id = parts[3], parts[4]
        data = self.body()
        with LOCK:
            target = None
            for t in tables_for(table):
                if sys_id in DB.get(t, {}):
                    target = DB[t][sys_id]
            if target is None:
                self.log("PATCH", path, 404)
                return self.error(404, "No Record found")
            candidate = copy.deepcopy(target)
            for k, v in data.items():
                if k != "work_notes":
                    candidate[k] = "" if v is None else str(v)
            if candidate.get("sys_class_name") == "incident":
                ok, msg = apply_incident_rules(candidate, is_new=False)
                if not ok:
                    self.log("PATCH", path, 403, msg)
                    return self.error(403, "Operation Failed", msg)
            if data.get("work_notes"):
                journal = json.loads(candidate.get("_journal") or "[]")
                journal.append({"at": now_utc(), "type": "work_notes", "value": data["work_notes"]})
                candidate["_journal"] = json.dumps(journal)
            candidate["sys_updated_on"] = now_utc()
            target.clear()
            target.update(candidate)
            persist()
            out = project(target, params.get("sysparm_fields"))
        changed = ", ".join(sorted(data.keys()))
        self.log("PATCH", path, 200, f"{target.get('number') or target.get('name', '')} [{changed}]")
        self.send_json(200, {"result": out})

    do_PUT = do_PATCH


def main() -> int:
    global DB_PATH
    parser = argparse.ArgumentParser(description="Offline mock of the ServiceNow Table API")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--db", help="optional JSON file to persist records to")
    args = parser.parse_args()
    DB_PATH = args.db
    seed()
    persist()
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Mock ServiceNow listening on http://{args.host}:{args.port}  (Ctrl+C to stop)", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
