#!/usr/bin/env python3
"""Browser test of managing programs (create, edit, copy, delete) on the Programs page.

    python3 next_program_manage.py --base http://127.0.0.1:18080 --user Admin --password Admin

The model and /programs are mocked: creating and deleting programs changes the CCU, which a test must not do on a CCU (the
routes are proven by the Tcl tests and against the restored real data). Login, profile and the page are real.
Checks: only administrators get the buttons; a not-operable program is listed for them; New program sends {create, name,
description}; Edit sends only what changed and shows the flags; Copy proposes a name and sends {id, copy, name}; a name that is
taken is told in the dialog; Delete asks first (Cancel has the focus) and sends DELETE ?id=; a user sees none of it; German.
"""
import argparse, json, sys
from playwright.sync_api import sync_playwright

NOISE = ("Synchronous XMLHttpRequest", "Synchrone XMLHttpRequest", "file:///", "favicon", "Failed to load resource")
PROFILE = {"userId": "1004", "userName": "Admin", "firstName": "Admin", "hasPassword": True, "isNoExpert": True, "language": "", "level": "ADMIN"}


def prog(id, name, **kw):
    d = {"id": id, "name": name, "description": "", "lastExecuteTime": "2026-11-01 10:00:00", "isActive": False, "isInternal": False, "isOperable": True, "isCopy": False, "isVisible": True}
    d.update(kw)
    return d


LOGIC = [
    {"hasCondition": True, "stopDelays": True, "groups": [{"op": "or", "conditions": [
        {"op": "and", "kind": "sysvar", "objectId": "950", "channelId": "65535", "objectName": "Anwesenheit", "channelName": "", "valueType": "2/2", "unit": "", "valueName0": "nicht anwesend", "valueName1": "anwesend", "valueList": "", "right": "true", "right2": "false", "test": 1, "trigger": 4, "rightType": 2, "right2Type": 2},
        {"op": "and", "kind": "device", "objectId": "3937", "channelId": "3935", "objectName": "VirtualDevices.INT0000006:1.ACTUAL_TEMPERATURE", "channelName": "Kinderzimmer:1", "valueType": "4/0", "unit": "°C", "valueName0": "", "valueName1": "", "valueList": "", "right": "20.000000", "right2": "0", "test": 8, "trigger": 13, "rightType": 4, "right2Type": 4}]}],
     "actions": [{"param": 18, "valueType": 4, "delayType": 28, "value": "21.000000", "delay": "2026-11-04 00:03:00", "channelId": "1", "datapointId": "2", "channelName": "Kinderzimmer:1", "datapointName": "VirtualDevices.INT0000006:1.MANU_MODE", "datapointType": "4/0"},
                {"param": 20, "valueType": 20, "delayType": 0, "value": "WriteLine(\"x\");", "delay": "", "channelId": "65535", "datapointId": "65535", "channelName": "", "datapointName": "", "datapointType": ""}]},
    {"hasCondition": False, "stopDelays": False, "groups": [], "actions": []},
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True); ap.add_argument("--user", default="Admin"); ap.add_argument("--password", required=True)
    a = ap.parse_args()
    results, console, calls, logic = [], [], [], []

    def check(name, ok, detail=""):
        results.append(ok); print("%s  %s %s" % ("PASS" if ok else "FAIL", name, detail))

    st = {"progs": [prog("1", "Licht an", description="Abends"), prog("2", "Heizung", isOperable=False, isVisible=False), prog("3", "System", isInternal=True)], "next": 100, "profile": None, "taken": False}
    ok = lambda body: dict(status=200, content_type="application/json", body=json.dumps(body))
    managed = lambda p: {k: p[k] for k in ("id", "name", "description", "isActive", "isVisible", "isOperable")}

    def on_model(route):
        route.fulfill(**ok({"programs": {"total": len(st["progs"]), "offset": 0, "limit": 500, "items": st["progs"]}}))

    def on_programs(route):
        req = route.request
        if req.method == "GET":
            logic.append(req.url.split("/v2/programs")[1])
            return route.fulfill(**ok({"id": "1", "name": "Licht an", "description": "Abends", "isActive": False, "isVisible": True, "isOperable": True, "rules": LOGIC}))
        calls.append((req.method, req.url.split("/v2/programs")[1], json.loads(req.post_data) if req.post_data else None))
        if st["taken"] and req.method in ("POST", "PUT"):
            return route.fulfill(status=409, content_type="application/json", body=json.dumps({"error": {"code": 404, "message": "name already in use"}}))
        if req.method == "DELETE":
            pid = req.url.split("id=")[1]
            st["progs"] = [p for p in st["progs"] if p["id"] != pid]
            return route.fulfill(**ok({"id": pid, "deleted": True}))
        body = json.loads(req.post_data)
        if req.method == "PUT":
            p = next(x for x in st["progs"] if x["id"] == body["id"])
            for k in ("name", "description", "isVisible", "isOperable"):
                if k in body: p[k] = body[k]
            return route.fulfill(**ok(managed(p)))
        st["next"] += 1
        src = next((x for x in st["progs"] if x["id"] == body.get("id")), None)
        p = prog(str(st["next"]), body["name"], description=(src["description"] if src else body.get("description", "")))
        st["progs"].append(p)
        route.fulfill(**ok(managed(p)))

    with sync_playwright() as p:
        browser = p.chromium.launch()
        pg = browser.new_page(viewport={"width": 1200, "height": 800})
        pg.on("console", lambda m: m.type == "error" and not any(n in m.text for n in NOISE) and console.append(m.text[:140]))
        pg.on("pageerror", lambda e: console.append("pageerror: " + str(e)[:140]))
        pg.route("**/v2/model?sections=programs*", on_model)
        pg.route("**/v2/programs*", on_programs)
        pg.route("**/v2/profile", lambda r: r.fulfill(**ok({**PROFILE, **(st["profile"] or {})})))
        try:
            pg.goto(a.base + "/webui/next/"); pg.wait_for_selector("#user")
            pg.fill("#user", a.user); pg.fill("#password", a.password); pg.keyboard.press("Enter")
            pg.get_by_role("link", name="Programs", exact=True).click(); pg.wait_for_selector("tbody tr")
            btn = lambda label, name: pg.get_by_role("button", name="%s: %s" % (label, name), exact=True)
            def choose(item, name):
                pg.get_by_role("button", name="Manage: " + name, exact=True).click()
                pg.get_by_role("menuitem", name=item, exact=True).click()
            dlg = pg.get_by_role("dialog")

            check("an administrator sees New program and a Manage menu per program with Logic, Edit, Copy and Delete", pg.get_by_role("button", name="New program").is_visible() and btn("Manage", "Licht an").is_visible())
            btn("Manage", "Licht an").click()
            check("the menu offers Logic, Edit, Copy and Delete", [pg.get_by_role("menuitem", name=n, exact=True).count() for n in ("Logic", "Edit", "Copy", "Delete")] == [1, 1, 1, 1])
            pg.keyboard.press("Escape")

            # logic: read only, in words
            choose("Logic", "Licht an"); dlg.wait_for(); dlg.get_by_text("If", exact=True).wait_for()
            txt = dlg.inner_text()
            check("Logic reads the program with GET ?id=", logic == ["?id=1"], repr(logic))
            check("the conditions are in words, with the names of values and the unit", "Anwesenheit = anwesend, when it changes" in txt and "Kinderzimmer:1 · ACTUAL_TEMPERATURE > 20 °C, when it is updated" in txt and "and Kinderzimmer" in txt, txt[:300])
            check("the actions have their delay, the script can be shown, the else part is listed", "Set Kinderzimmer:1 · MANU_MODE to 21" in txt and "after 3 min" in txt and "Run a script" in txt and "Else" in txt and "No actions." in txt)
            dlg.get_by_text("Show the script").click()
            check("the script is shown on request", dlg.get_by_text('WriteLine("x");').is_visible())
            check("it says what can be edited", "Conditions and actions can be edited" in txt)
            dlg.get_by_role("button", name="OK").click(); dlg.wait_for(state="hidden")
            check("a program users may not operate is listed for the administrator, the system's own is not", pg.locator("tbody").get_by_text("Heizung", exact=True).count() == 1 and pg.locator("tbody").get_by_text("System", exact=True).count() == 0)

            # create
            pg.get_by_role("button", name="New program").click(); dlg.wait_for()
            ok_btn = dlg.get_by_role("button", name="OK")
            check("OK waits for a valid name", ok_btn.is_disabled())
            dlg.get_by_label("Name").fill(" bad"); 
            check("a name with a space at the start is refused in the dialog", dlg.get_by_role("alert").count() == 1 and ok_btn.is_disabled())
            dlg.get_by_label("Name").fill("Neues Licht"); dlg.get_by_label("Description").fill("Test")
            ok_btn.click(); pg.get_by_text("Neues Licht was created. It is empty and inactive.").wait_for(timeout=10000)
            check("create sends {create, name, description}", calls[-1] == ("POST", "", {"create": True, "name": "Neues Licht", "description": "Test"}), repr(calls[-1]))
            check("the new program is listed and the dialog is closed", pg.locator("tbody").get_by_text("Neues Licht", exact=True).count() == 1 and dlg.count() == 0)

            # a taken name is told in the dialog
            st["taken"] = True
            pg.get_by_role("button", name="New program").click(); dlg.wait_for()
            dlg.get_by_label("Name").fill("Licht an"); dlg.get_by_role("button", name="OK").click()
            dlg.get_by_text("already used by another object").wait_for(timeout=10000)
            check("a name that is taken is told in the dialog, which stays open", dlg.is_visible())
            dlg.get_by_role("button", name="Cancel").click(); dlg.wait_for(state="hidden"); st["taken"] = False

            # edit: only what changed
            choose("Edit", "Heizung"); dlg.wait_for()
            check("Edit shows name, flags as they are", dlg.get_by_label("Name").input_value() == "Heizung" and not dlg.get_by_label("Visible").is_checked() and not dlg.get_by_label("Users may operate it").is_checked())
            check("OK waits for a change", dlg.get_by_role("button", name="OK").is_disabled())
            dlg.get_by_label("Visible").check(); dlg.get_by_role("button", name="OK").click()
            pg.get_by_text("Heizung was saved.").wait_for(timeout=10000)
            check("edit sends only the changed field", calls[-1] == ("PUT", "", {"id": "2", "isVisible": True}), repr(calls[-1]))

            # copy
            choose("Copy", "Licht an"); dlg.wait_for()
            check("Copy proposes a name and has no description field", dlg.get_by_label("Name").input_value() == "Licht an (copy)" and dlg.get_by_label("Description").count() == 0)
            dlg.get_by_role("button", name="OK").click(); pg.get_by_text("Licht an (copy) was created as a copy. It is inactive.").wait_for(timeout=10000)
            check("copy sends {id, copy, name}", calls[-1] == ("POST", "", {"id": "1", "copy": True, "name": "Licht an (copy)"}), repr(calls[-1]))

            # delete asks first
            before = len(calls)
            choose("Delete", "Neues Licht"); dlg.wait_for()
            check("Delete asks first, Cancel has the focus", "Delete this program?" in dlg.inner_text() and dlg.get_by_role("button", name="Cancel").evaluate("e => e === document.activeElement") and len(calls) == before)
            dlg.get_by_role("button", name="Cancel").click(); dlg.wait_for(state="hidden")
            check("Cancel deletes nothing", len(calls) == before and pg.locator("tbody").get_by_text("Neues Licht", exact=True).count() == 1)
            choose("Delete", "Neues Licht"); dlg.get_by_role("button", name="Delete").click()
            pg.get_by_text("Neues Licht was deleted.").wait_for(timeout=10000)
            check("delete sends DELETE ?id= and the row goes", calls[-1] == ("DELETE", "?id=101", None) and pg.locator("tbody").get_by_text("Neues Licht", exact=True).count() == 0, repr(calls[-1]))

            # a user: nothing to manage, the list is what users operate
            st["profile"] = {"level": "USER"}
            pg.reload(); pg.get_by_role("button", name="Run: Licht an", exact=True).wait_for()
            check("a user sees no management buttons and not the program users may not operate", pg.get_by_role("button", name="New program").count() == 0 and pg.get_by_role("button", name="Manage: Licht an", exact=True).count() == 0 and pg.locator("tbody").get_by_text("Heizung", exact=True).count() == 0)

            # German
            st["profile"] = None
            pg.reload(); pg.get_by_role("button", name="Neues Programm").or_(pg.get_by_role("button", name="New program")).wait_for()
            pg.get_by_role("button", name="Account menu").click(); pg.get_by_role("menuitemradio", name="Deutsch").click()
            pg.get_by_role("button", name="Neues Programm").click(); dlg.wait_for()
            check("German texts", dlg.get_by_text("Neues Programm").count() >= 1 and dlg.get_by_label("Beschreibung").count() == 1)
            dlg.get_by_role("button", name="Abbrechen").click()
            check("no browser errors", not console, "; ".join(console[:3]))
        finally:
            try:
                pg.unroute_all(); pg.reload()
                pg.get_by_role("button", name="Account menu").click(timeout=3000); pg.get_by_role("menuitem", name="Sign out").click(timeout=3000)
            except Exception:
                pass
            browser.close()
    print("%d PASS, %d FAIL" % (sum(results), len(results) - sum(results)))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
