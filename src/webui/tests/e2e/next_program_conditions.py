#!/usr/bin/env python3
"""Browser test of editing the conditions of a program (Logic dialog -> Edit conditions).

    python3 next_program_conditions.py --base http://127.0.0.1:18080 --user Admin --password Admin

The model, GET /programs (logic, targets) and PUT /programs are mocked: saving rewrites a program on the CCU, which a test must
not do on a CCU (the route is proven by the Tcl tests and against the restored real data). Login, profile and the page are real.
Checks: the rows of the conditions with the joiners and a time control; Save waits for a change; the exact PUT body (positions of
the kept conditions, new ones without one, the joiners); a time control can change its trigger, and removing it (or its group)
asks first because its timer is deleted; between and a percentage; a text variable the editor cannot show; the warning for an
active program; a refusal stays in the dialog; German.
"""
import argparse, json, sys
from playwright.sync_api import sync_playwright

NOISE = ("Synchronous XMLHttpRequest", "Synchrone XMLHttpRequest", "file:///", "favicon", "Failed to load resource")
PROFILE = {"userId": "1004", "userName": "Admin", "firstName": "Admin", "hasPassword": True, "isNoExpert": True, "language": "", "level": "ADMIN"}


def prog(id, name, **kw):
    d = {"id": id, "name": name, "description": "", "lastExecuteTime": "2026-11-01 10:00:00", "isActive": False, "isInternal": False, "isOperable": True, "isCopy": False, "isVisible": True}
    d.update(kw)
    return d


def cond(kind, oid, name, ch, vt, test, right, trig=4, rt=4, op="and", unit="", vl="", v0="", v1="", right2="0", **kw):
    d = {"op": op, "kind": kind, "objectId": oid, "channelId": "1", "objectName": name, "channelName": ch, "valueType": vt, "unit": unit, "valueName0": v0, "valueName1": v1, "valueList": vl,
         "right": right, "right2": right2, "test": test, "trigger": trig, "rightType": rt, "right2Type": rt}
    d.update(kw)
    return d


TIME = cond("time", "", "", "", "", 3, "555", trig=13, rt=18, time={"timerType": 9, "sunOffset": 0, "seconds": 0, "duration": 0, "time": "1970-01-01 07:30:00", "begin": "2025-10-04 00:00:00", "end": "1970-01-01 01:00:00", "repetitions": 0})
TEMP = cond("device", "3937", "X.ACTUAL_TEMPERATURE", "Kinderzimmer:1", "4/0", 8, "20.000000", trig=13, unit="°C")
MODE = cond("device", "3941", "X.CONTROL_MODE", "Kinderzimmer:1", "16/29", 1, "1", trig=4, rt=16, vl="AUTO-MODE;MANU-MODE;PARTY-MODE")
ANWE = cond("sysvar", "950", "Anwesenheit", "", "2/2", 1, "true", trig=4, rt=2, v0="nicht anwesend", v1="anwesend")
LEVEL = cond("device", "1013", "X.LEVEL", "Rollo:1", "6/0", 6, "0.250000", right2="0.750000", trig=13, unit="100%")
TEXTV = cond("sysvar", "12", "Text", "", "20/11", 1, "x", rt=20)

TARGETS = {
    "datapoints": [
        {"id": "3937", "param": "ACTUAL_TEMPERATURE", "channel": "Kinderzimmer:1", "device": "K", "valueType": 4, "subType": 0, "min": "-40.0", "max": "80.0", "unit": "°C", "valueList": ""},
        {"id": "3941", "param": "CONTROL_MODE", "channel": "Kinderzimmer:1", "device": "K", "valueType": 16, "subType": 29, "min": "0", "max": "3", "unit": "", "valueList": "AUTO-MODE;MANU-MODE;PARTY-MODE"},
        {"id": "1013", "param": "LEVEL", "channel": "Rollo:1", "device": "R", "valueType": 6, "subType": 0, "min": "0.0", "max": "1.0", "unit": "100%", "valueList": ""},
    ],
    "variables": [
        {"id": "950", "name": "Anwesenheit", "valueType": 2, "subType": 2, "min": "", "max": "", "unit": "", "valueList": "", "valueName0": "nicht anwesend", "valueName1": "anwesend"},
        {"id": "12", "name": "Text", "valueType": 20, "subType": 11, "min": "", "max": "", "unit": "", "valueList": "", "valueName0": "", "valueName1": ""},
    ],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True); ap.add_argument("--user", default="Admin"); ap.add_argument("--password", required=True)
    a = ap.parse_args()
    results, console, puts = [], [], []

    def check(name, ok, detail=""):
        results.append(ok); print("%s  %s %s" % ("PASS" if ok else "FAIL", name, detail))

    st = {"refuse": False}
    rules = {
        "1": [{"hasCondition": True, "stopDelays": True, "groups": [{"op": "or", "conditions": [TEMP, TIME, dict(MODE, op="and")]}, {"op": "or", "conditions": [dict(ANWE)]}], "actions": []}],
        "2": [{"hasCondition": True, "stopDelays": False, "groups": [{"op": "and", "conditions": [LEVEL]}], "actions": []}],
        "3": [{"hasCondition": True, "stopDelays": False, "groups": [{"op": "and", "conditions": [TEXTV]}], "actions": []}],
    }
    progs = [prog("1", "Heizung"), prog("2", "Rollo", isActive=True), prog("3", "Textprogramm")]
    ok = lambda body: dict(status=200, content_type="application/json", body=json.dumps(body))
    logic = lambda p: {"id": p["id"], "name": p["name"], "description": "", "isActive": p["isActive"], "isVisible": True, "isOperable": True, "rules": rules[p["id"]]}

    def on_programs(route):
        req = route.request
        url = req.url.split("/v2/programs")[1]
        if req.method == "GET":
            if url == "?targets=conditions":
                return route.fulfill(**ok(TARGETS))
            return route.fulfill(**ok(logic(next(p for p in progs if p["id"] == url.split("id=")[1]))))
        body = json.loads(req.post_data); puts.append(body)
        if st["refuse"]:
            return route.fulfill(status=422, content_type="application/json", body=json.dumps({"error": {"code": 403, "message": "invalid argument (conditions)"}}))
        route.fulfill(**ok(logic(next(p for p in progs if p["id"] == body["id"]))))

    with sync_playwright() as p:
        browser = p.chromium.launch()
        pg = browser.new_page(viewport={"width": 1200, "height": 1000})
        pg.on("console", lambda m: m.type == "error" and not any(n in m.text for n in NOISE) and console.append(m.text[:140]))
        pg.on("pageerror", lambda e: console.append("pageerror: " + str(e)[:140]))
        pg.route("**/v2/model?sections=programs*", lambda r: r.fulfill(**ok({"programs": {"total": 3, "offset": 0, "limit": 500, "items": progs}})))
        pg.route("**/v2/programs*", on_programs)
        pg.route("**/v2/profile", lambda r: r.fulfill(**ok(PROFILE)))
        try:
            pg.goto(a.base + "/webui/next/"); pg.wait_for_selector("#user")
            pg.fill("#user", a.user); pg.fill("#password", a.password); pg.keyboard.press("Enter")
            pg.get_by_role("link", name="Programs", exact=True).click(); pg.wait_for_selector("tbody tr")

            def open_editor(prog_name, loaded=True):
                pg.get_by_role("button", name="Manage: " + prog_name, exact=True).click(); pg.get_by_role("menuitem", name="Logic", exact=True).click()
                pg.get_by_role("dialog").first.get_by_role("button", name="Edit conditions: If").wait_for()
                pg.get_by_role("dialog").first.get_by_role("button", name="Edit conditions: If").click()
                ed = pg.get_by_role("dialog").last
                ed.get_by_role("button", name="Add group" if loaded else "Cancel").wait_for(timeout=10000)
                return ed

            def close_editor(ed):
                ed.get_by_role("button", name="Cancel").click()
                pg.wait_for_function("document.querySelectorAll('[role=dialog]').length === 1")
                pg.get_by_role("dialog").first.get_by_role("button", name="OK").click()

            ed = open_editor("Heizung")
            row = lambda g, c: ed.get_by_role("listitem", name="Group %d, Action %d" % (g, c), exact=True)
            check("a group per group of the program, with the joiners of the program", ed.get_by_label("The groups are joined by").input_value() == "or" and ed.get_by_label("Group 1: The conditions of this group are joined by").input_value() == "and")
            check("the device condition shows its comparison, value, unit and trigger", row(1, 1).get_by_label("Group 1, Action 1: Comparison").evaluate("e => e.options[e.selectedIndex].text") == "greater" or row(1, 1).get_by_label("Group 1, Action 1: Comparison").evaluate("e => e.options[e.selectedIndex].text") == ">")
            check("the value and the trigger are those of the program", row(1, 1).get_by_label("Group 1, Action 1: Value").input_value() == "20" and row(1, 1).get_by_label("Group 1, Action 1: Triggers").evaluate("e => e.options[e.selectedIndex].text") == "on update")
            check("a time control is shown in words, with a trigger choice and no kind or target", "Time control: daily all day" in row(1, 2).inner_text() and row(1, 2).get_by_label("Group 1, Action 2: Triggers").is_visible() and row(1, 2).get_by_label("Group 1, Action 2: Kind").count() == 0, repr(row(1, 2).inner_text()[:80]))
            check("a list value shows its entry; a logic variable its names", row(1, 3).get_by_label("Group 1, Action 3: Value").evaluate("e => e.options[e.selectedIndex].text") == "MANU-MODE" and row(2, 1).get_by_label("Group 2, Action 1: Value").evaluate("e => e.options[e.selectedIndex].text") == "anwesend")
            check("Save waits for a change", ed.get_by_role("button", name="OK").is_disabled())
            check("an inactive program has no re-activation warning", ed.get_by_text("This program is active").count() == 0)

            # edit: value, time trigger, a new condition in group 2, a new group
            row(1, 1).get_by_label("Group 1, Action 1: Value").fill("22.5")
            row(1, 2).get_by_label("Group 1, Action 2: Triggers").select_option("15")
            ed.get_by_role("listitem", name="Group 2", exact=True).get_by_role("button", name="Add condition").click()
            new = row(2, 2)
            new.get_by_label("Group 2, Action 2: Target").click()
            ed.get_by_label("Filter by name").fill("ACTUAL"); ed.get_by_role("button", name="Kinderzimmer:1 · ACTUAL_TEMPERATURE", exact=True).click()
            new.get_by_label("Group 2, Action 2: Comparison").select_option("10")
            new.get_by_label("Group 2, Action 2: Value").fill("18")
            ed.get_by_role("button", name="Add group").click()
            g3 = row(3, 1)
            g3.get_by_label("Group 3, Action 1: Target").click()
            ed.get_by_label("Filter by name").fill("CONTROL"); ed.get_by_role("button", name="Kinderzimmer:1 · CONTROL_MODE", exact=True).click()
            g3.get_by_label("Group 3, Action 1: Value").select_option("2")
            ed.get_by_role("button", name="OK").click()
            pg.get_by_text("The conditions of Heizung were saved.").wait_for(timeout=10000)
            exp = {"id": "1", "rule": 0, "conditions": {"op": "or", "groups": [
                {"from": 0, "op": "and", "conditions": [
                    {"from": 0, "kind": "device", "datapointId": "3937", "test": 8, "value": "22.5", "trigger": 13},
                    {"from": 1, "kind": "time", "trigger": 15},
                    {"from": 2, "kind": "device", "datapointId": "3941", "test": 1, "value": "1", "trigger": 4}]},
                {"from": 1, "op": "and", "conditions": [
                    {"from": 0, "kind": "sysvar", "variableId": "950", "test": 1, "value": "true", "trigger": 4},
                    {"kind": "device", "datapointId": "3937", "test": 10, "value": "18", "trigger": 4}]},
                {"op": "and", "conditions": [{"kind": "device", "datapointId": "3941", "test": 1, "value": "2", "trigger": 4}]}]}}
            check("Save sends kept conditions with their positions and new ones without", puts[-1] == exp, json.dumps(puts[-1])[:600])
            pg.get_by_role("dialog").first.get_by_role("button", name="OK").click()

            # removing a time control (or its group) asks first
            ed = open_editor("Heizung")
            n0 = len(puts)
            ed.get_by_role("button", name="Group 1, Action 2: Remove").click()
            dlg = pg.get_by_role("dialog").last
            check("removing a time control asks first and says the timer is deleted", "Delete this time control?" in dlg.inner_text() and "timer" in dlg.inner_text() and dlg.get_by_role("button", name="Cancel").evaluate("e => e === document.activeElement"))
            dlg.get_by_role("button", name="Cancel").click(); pg.wait_for_function("document.querySelectorAll('[role=dialog]').length === 2")
            check("Cancel keeps the time control", ed.get_by_role("button", name="Group 1, Action 2: Remove").count() == 1)
            ed.get_by_role("button", name="Group 1: Remove group").click()
            pg.get_by_role("dialog").last.get_by_role("button", name="Remove", exact=True).click()
            check("removing a group that holds one asks too, and removes it", ed.get_by_role("listitem", name="Group 2", exact=True).count() == 0 and ed.get_by_role("listitem", name="Group 1", exact=True).count() == 1)
            ed.get_by_role("button", name="Group 1: Remove group").click()
            check("a group without a time control is removed without a question; the last one leaves a rule without conditions", ed.get_by_text("No conditions").is_visible() and pg.evaluate("document.querySelectorAll('[role=dialog]').length") == 2)
            ed.get_by_role("button", name="OK").click()
            pg.get_by_text("The conditions of Heizung were saved.").wait_for(timeout=10000)
            check("saving with no group sends an empty list", puts[-1]["conditions"]["groups"] == [] and len(puts) == n0 + 1, json.dumps(puts[-1])[:200])
            pg.get_by_role("dialog").first.get_by_role("button", name="OK").click()

            # between, a percentage, an active program
            ed = open_editor("Rollo")
            check("a scaling value is shown as a percentage, between with both ends", ed.get_by_label("Group 1, Action 1: Value").input_value() == "25" and ed.get_by_label("Group 1, Action 1: Upper end").input_value() == "75" and ed.get_by_label("Group 1, Action 1: Comparison").evaluate("e => e.options[e.selectedIndex].text") == "between")
            check("an active program warns that saving can run it", ed.get_by_text("This program is active").is_visible())
            ed.get_by_label("Group 1, Action 1: Upper end").fill("10")
            check("an upper end below the lower one is told and blocks Save", ed.get_by_text("The upper end must be a number").is_visible() and ed.get_by_role("button", name="OK").is_disabled())
            ed.get_by_label("Group 1, Action 1: Upper end").fill("80")
            st["refuse"] = True
            ed.get_by_role("button", name="OK").click()
            ed.get_by_role("alert").first.wait_for(timeout=10000)
            check("a refusal is told in the dialog, which stays open", ed.is_visible() and ed.get_by_role("button", name="OK").is_enabled())
            check("the percentage goes out as typed (0..100)", puts[-1]["conditions"]["groups"][0]["conditions"][0] == {"from": 0, "kind": "device", "datapointId": "1013", "test": 6, "value": "25", "value2": "80", "trigger": 13}, json.dumps(puts[-1]["conditions"]["groups"][0]["conditions"][0]))
            st["refuse"] = False
            close_editor(ed)

            # a text variable the editor cannot show
            ed = open_editor("Textprogramm", loaded=False)
            ed.get_by_text("cannot be shown here yet").wait_for(timeout=10000)
            check("a condition the editor cannot show is told and nothing can be saved", ed.get_by_role("button", name="OK").is_disabled() and ed.get_by_role("listitem").count() == 0)
            close_editor(ed)

            # German
            pg.get_by_role("button", name="Account menu").click(); pg.get_by_role("menuitemradio", name="Deutsch").click()
            pg.get_by_role("button", name="Verwalten: Rollo", exact=True).click(); pg.get_by_role("menuitem", name="Logik", exact=True).click()
            pg.get_by_role("dialog").first.get_by_role("button", name="Bedingungen bearbeiten: Wenn").click()
            ed = pg.get_by_role("dialog").last; ed.get_by_role("button", name="Gruppe hinzufügen").wait_for(timeout=10000)
            check("German texts", ed.get_by_text("Dieses Programm ist aktiv").is_visible() and ed.get_by_label("Gruppe 1, Aktion 1: Vergleich").evaluate("e => e.options[e.selectedIndex].text") == "zwischen")
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
