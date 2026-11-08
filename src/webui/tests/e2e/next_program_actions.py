#!/usr/bin/env python3
"""Browser test of editing the actions of a program (Logic dialog -> Edit actions).

    python3 next_program_actions.py --base http://127.0.0.1:18080 --user Admin --password Admin

The model, GET /programs (logic, targets) and PUT /programs are mocked: saving rewrites a program on the CCU, which a test
must not do on a CCU (the route is proven by the Tcl tests and against the restored real data). Login, profile and the page
are real. Checks: the rows of the program's actions with their delay and a percentage as 0..100; Save waits for a change; the
exact PUT body; a bad value is told and blocks Save; add, remove and reorder; the warning for an active program; an action the
editor cannot show; a refusal stays in the dialog; German.
"""
import argparse, json, sys
from playwright.sync_api import sync_playwright

NOISE = ("Synchronous XMLHttpRequest", "Synchrone XMLHttpRequest", "file:///", "favicon", "Failed to load resource")
PROFILE = {"userId": "1004", "userName": "Admin", "firstName": "Admin", "hasPassword": True, "isNoExpert": True, "language": "", "level": "ADMIN"}


def prog(id, name, **kw):
    d = {"id": id, "name": name, "description": "", "lastExecuteTime": "2026-11-01 10:00:00", "isActive": False, "isInternal": False, "isOperable": True, "isCopy": False, "isVisible": True}
    d.update(kw)
    return d


def act(param, vt, value, dp="", dpn="", unit="", delay="", ch="Rollo:1", dt=""):
    return {"param": param, "valueType": vt, "delayType": 28 if delay else 0, "value": value, "delay": delay, "channelId": "1", "datapointId": dp, "channelName": ch, "datapointName": dpn, "datapointType": dt, "datapointUnit": unit}


TARGETS = {
    "datapoints": [
        {"id": "1013", "param": "LEVEL", "channel": "Rollo:1", "device": "Rollo", "valueType": 6, "subType": 0, "min": "0.0", "max": "1.0", "unit": "100%", "valueList": ""},
        {"id": "3943", "param": "MANU_MODE", "channel": "Kinderzimmer:1", "device": "K", "valueType": 4, "subType": 0, "min": "5.0", "max": "30.0", "unit": "°C", "valueList": ""},
        {"id": "3941", "param": "CONTROL_MODE", "channel": "Kinderzimmer:1", "device": "K", "valueType": 16, "subType": 29, "min": "0", "max": "3", "unit": "", "valueList": "AUTO-MODE;MANU-MODE;PARTY-MODE"},
    ],
    "variables": [{"id": "12202", "name": "Rollladenautomatik", "valueType": 2, "subType": 2, "min": "", "max": "", "unit": "", "valueList": "", "valueName0": "aus", "valueName1": "an"}],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True); ap.add_argument("--user", default="Admin"); ap.add_argument("--password", required=True)
    a = ap.parse_args()
    results, console, puts = [], [], []

    def check(name, ok, detail=""):
        results.append(ok); print("%s  %s %s" % ("PASS" if ok else "FAIL", name, detail))

    st = {"refuse": False, "unsupported": False}
    rules = {
        "1": [{"hasCondition": True, "stopDelays": True, "groups": [], "actions": [act(18, 6, "0.500000", "1013", "BidCos-RF.X:1.LEVEL", "100%"), act(19, 2, "true", "12202", "Rollladenautomatik", ch=""), act(20, 20, "WriteLine(\"a\");", delay="2026-11-04 00:03:00", ch="")]},
              {"hasCondition": False, "stopDelays": False, "groups": [], "actions": []}],
        "2": [{"hasCondition": True, "stopDelays": False, "groups": [], "actions": [act(18, 4, "21.000000", "3943", "X.MANU_MODE")]}],
    }
    progs = [prog("1", "Rollo morgens"), prog("2", "Heizung abends", isActive=True)]
    ok = lambda body: dict(status=200, content_type="application/json", body=json.dumps(body))
    logic = lambda p: {"id": p["id"], "name": p["name"], "description": "", "isActive": p["isActive"], "isVisible": True, "isOperable": True, "rules": rules[p["id"]]}

    def on_programs(route):
        req = route.request
        url = req.url.split("/v2/programs")[1]
        if req.method == "GET":
            if url == "?targets=1":
                return route.fulfill(**ok(TARGETS))
            pid = url.split("id=")[1]
            if st["unsupported"] and pid == "1":
                rules["1"][0]["actions"].append(act(18, 4, "1", "99999", "Gone.DP"))
            return route.fulfill(**ok(logic(next(p for p in progs if p["id"] == pid))))
        body = json.loads(req.post_data); puts.append(body)
        if req.method == "POST" and body.get("addElse"):
            rules[body["id"]].append({"hasCondition": False, "stopDelays": True, "groups": [], "actions": []})
            return route.fulfill(**ok(logic(next(p for p in progs if p["id"] == body["id"]))))
        if st["refuse"]:
            return route.fulfill(status=422, content_type="application/json", body=json.dumps({"error": {"code": 403, "message": "invalid argument (actions[0].value)"}}))
        # apply: the actions come back as the logic reads them
        new = []
        for x in body["actions"]:
            sec = x.get("delaySeconds", 0)
            dly = "2026-11-04 %02d:%02d:%02d" % (sec // 3600, (sec % 3600) // 60, sec % 60) if sec else ""
            if x["kind"] == "script": new.append(act(20, 20, x["script"], delay=dly))
            elif x["kind"] == "sysvar": new.append(act(19, 2, x["value"], x["variableId"], "Rollladenautomatik", delay=dly, ch=""))
            else: new.append(act(18, 4, x["value"], x["datapointId"], "X.P", delay=dly))
        rules[body["id"]][body["rule"]]["actions"] = new
        if "stopDelays" in body: rules[body["id"]][body["rule"]]["stopDelays"] = body["stopDelays"]
        route.fulfill(**ok(logic(next(p for p in progs if p["id"] == body["id"]))))

    with sync_playwright() as p:
        browser = p.chromium.launch()
        pg = browser.new_page(viewport={"width": 1200, "height": 900})
        pg.on("console", lambda m: m.type == "error" and not any(n in m.text for n in NOISE) and console.append(m.text[:140]))
        pg.on("pageerror", lambda e: console.append("pageerror: " + str(e)[:140]))
        pg.route("**/v2/model?sections=programs*", lambda r: r.fulfill(**ok({"programs": {"total": 2, "offset": 0, "limit": 500, "items": progs}})))
        pg.route("**/v2/programs*", on_programs)
        pg.route("**/v2/profile", lambda r: r.fulfill(**ok(PROFILE)))
        try:
            pg.goto(a.base + "/webui/next/"); pg.wait_for_selector("#user")
            pg.fill("#user", a.user); pg.fill("#password", a.password); pg.keyboard.press("Enter")
            pg.get_by_role("link", name="Programs", exact=True).click(); pg.wait_for_selector("tbody tr")

            def open_editor(prog_name, part="Then"):
                pg.get_by_role("button", name="Manage: " + prog_name, exact=True).click(); pg.get_by_role("menuitem", name="Logic", exact=True).click()
                pg.get_by_role("dialog").first.get_by_role("button", name="Edit actions: " + part).wait_for()
                pg.get_by_role("dialog").first.get_by_role("button", name="Edit actions: " + part).click()
                ed = pg.get_by_role("dialog").last
                ed.get_by_role("button", name="Add action").wait_for(timeout=10000)
                return ed

            ed = open_editor("Rollo morgens")
            rows = ed.get_by_role("listitem")
            check("the editor shows a row per action", rows.count() == 3)
            check("a scaling value is shown as a percentage", rows.nth(0).get_by_label("Action 1: Value").input_value() == "50" and rows.nth(0).get_by_text("%", exact=True).is_visible())
            check("a logic value of a variable uses its names", rows.nth(1).get_by_label("Action 2: Value").evaluate("e => e.options[e.selectedIndex].text") == "an")
            check("a script is a text area with its delay", "WriteLine" in rows.nth(2).get_by_label("Action 3: Script").input_value() and rows.nth(2).get_by_label("Action 3: Delay", exact=True).input_value() == "3" and rows.nth(2).get_by_label("Action 3: Delay unit").input_value() == "min")
            check("Save waits for a change", ed.get_by_role("button", name="OK").is_disabled())
            check("an inactive program has no re-activation warning", ed.get_by_text("This program is active").count() == 0)

            # a bad value is told and blocks Save
            rows.nth(0).get_by_label("Action 1: Value").fill("101")
            check("a value outside the range is told and blocks Save", ed.get_by_text("Outside the allowed range (0 to 100)").is_visible() and ed.get_by_role("button", name="OK").is_disabled())
            rows.nth(0).get_by_label("Action 1: Value").fill("75")
            check("a valid value allows Save", ed.get_by_role("button", name="OK").is_enabled())

            # reorder, remove, add
            rows.nth(1).get_by_role("button", name="Action 2: Move up").click()
            rows.nth(2).get_by_role("button", name="Action 3: Remove").click()
            ed.get_by_role("button", name="Add action").click()
            new = ed.get_by_role("listitem").nth(2)
            new.get_by_label("Action 3: Target").click()
            ed.get_by_label("Filter by name").fill("MANU"); ed.get_by_role("button", name="Kinderzimmer:1 · MANU_MODE").click()
            check("a new row starts with a valid value in the target's range", new.get_by_label("Action 3: Value").input_value() == "5")
            new.get_by_label("Action 3: Value").fill("19.5")
            new.get_by_label("Action 3: Delayed").check(); new.get_by_label("Action 3: Delay", exact=True).fill("2"); new.get_by_label("Action 3: Delay unit").select_option("h")
            ed.get_by_role("button", name="OK").click()
            pg.get_by_text("The actions of Rollo morgens were saved.").wait_for(timeout=10000)
            exp = {"id": "1", "rule": 0, "actions": [{"kind": "sysvar", "variableId": "12202", "value": "true"}, {"kind": "device", "datapointId": "1013", "value": "75"}, {"kind": "device", "datapointId": "3943", "value": "19.5", "delaySeconds": 7200}], "stopDelays": True}
            check("Save sends the whole list in the new order with delays in seconds", puts[-1] == exp, json.dumps(puts[-1])[:300])
            check("the logic view shows the saved actions at once", pg.get_by_role("dialog").first.get_by_text("Set Rollladenautomatik to on").is_visible() and pg.get_by_role("dialog").first.get_by_text("Set Rollo:1 · P to 19.5").is_visible() and pg.get_by_role("dialog").first.get_by_text("after 2 h").is_visible())
            pg.get_by_role("dialog").first.get_by_role("button", name="OK").click()

            # the else part has no actions yet
            ed = open_editor("Rollo morgens", "Else")
            check("the else part opens empty", ed.get_by_text("No actions yet.").is_visible() and ed.get_by_role("button", name="OK").is_disabled())
            ed.get_by_role("button", name="Add action").click()
            ed.get_by_role("listitem").first.get_by_label("Action 1: Kind").select_option("script")
            ed.get_by_role("listitem").first.get_by_label("Action 1: Script").fill("! else")
            ed.get_by_role("button", name="OK").click()
            pg.get_by_text("The actions of Rollo morgens were saved.").wait_for(timeout=10000)
            check("saving the else part names its rule", puts[-1]["rule"] == 1 and puts[-1]["actions"] == [{"kind": "script", "script": "! else"}], json.dumps(puts[-1]))
            pg.get_by_role("dialog").first.get_by_role("button", name="OK").click()

            # an active program warns; a refusal stays in the dialog
            ed = open_editor("Heizung abends")
            check("an active program warns that saving can run it", ed.get_by_text("This program is active").is_visible())
            st["refuse"] = True
            ed.get_by_role("listitem").first.get_by_label("Action 1: Value").fill("20")
            ed.get_by_role("button", name="OK").click()
            ed.get_by_role("alert").filter(has_text="not").or_(ed.get_by_role("alert").filter(has_text="invalid")).first.wait_for(timeout=10000)
            check("a refusal is told in the dialog, which stays open", ed.is_visible() and ed.get_by_role("button", name="OK").is_enabled())
            st["refuse"] = False
            ed.get_by_role("button", name="Cancel").click(); pg.wait_for_function("document.querySelectorAll('[role=dialog]').length === 1")
            pg.get_by_role("dialog").first.get_by_role("button", name="OK").click()

            # the else part: absent when there is one, asks first for an active program, then appears with its own Edit actions
            pg.get_by_role("button", name="Manage: Rollo morgens", exact=True).click(); pg.get_by_role("menuitem", name="Logic", exact=True).click()
            d1 = pg.get_by_role("dialog").first; d1.get_by_role("button", name="Edit actions: Then").wait_for()
            check("a program that has an else part offers no way to add one", d1.get_by_role("button", name="Add an else part").count() == 0)
            d1.get_by_role("button", name="OK").click()
            pg.get_by_role("button", name="Manage: Heizung abends", exact=True).click(); pg.get_by_role("menuitem", name="Logic", exact=True).click()
            d1 = pg.get_by_role("dialog").first; d1.get_by_role("button", name="Add an else part").wait_for()
            check("a program without one has no Else section yet", d1.get_by_text("Else", exact=True).count() == 0 and d1.get_by_role("button", name="Edit actions: Else").count() == 0)
            n0 = len(puts)
            d1.get_by_role("button", name="Add an else part").click()
            cf = pg.get_by_role("dialog").last
            check("an active program asks first and says it can run at once", "Add an else part?" in cf.inner_text() and "can run at once" in cf.inner_text() and len(puts) == n0 and cf.get_by_role("button", name="Cancel").evaluate("e => e === document.activeElement"))
            cf.get_by_role("button", name="Cancel").click(); pg.wait_for_function("document.querySelectorAll('[role=dialog]').length === 1")
            check("Cancel adds nothing", len(puts) == n0)
            d1.get_by_role("button", name="Add an else part").click()
            pg.get_by_role("dialog").last.get_by_role("button", name="Add an else part", exact=True).click()
            pg.get_by_text("The else part of Heizung abends was added.").wait_for(timeout=10000)
            check("adding sends {id, addElse}", puts[-1] == {"id": "2", "addElse": True}, json.dumps(puts[-1]))
            d1 = pg.get_by_role("dialog").first
            check("the else part appears with its own Edit actions, and the button goes", d1.get_by_role("button", name="Edit actions: Else").is_visible() and d1.get_by_role("button", name="Add an else part").count() == 0)
            d1.get_by_role("button", name="Edit actions: Else").click()
            ed = pg.get_by_role("dialog").last; ed.get_by_role("button", name="Add action").wait_for(timeout=10000)
            check("the new else part opens empty in the actions editor", ed.get_by_text("No actions yet.").is_visible())
            ed.get_by_role("button", name="Cancel").click(); pg.wait_for_function("document.querySelectorAll('[role=dialog]').length === 1")
            pg.get_by_role("dialog").first.get_by_role("button", name="OK").click()

            # an action that cannot be shown
            st["unsupported"] = True
            pg.get_by_role("button", name="Manage: Rollo morgens", exact=True).click(); pg.get_by_role("menuitem", name="Logic", exact=True).click()
            pg.get_by_role("dialog").first.get_by_role("button", name="Edit actions: Then").click()
            ed = pg.get_by_role("dialog").last
            ed.get_by_text("cannot be shown here yet").wait_for(timeout=10000)
            check("an action the editor cannot show is told and nothing can be saved", ed.get_by_role("button", name="OK").is_disabled() and ed.get_by_role("listitem").count() == 0)
            ed.get_by_role("button", name="Cancel").click(); pg.wait_for_function("document.querySelectorAll('[role=dialog]').length === 1"); pg.get_by_role("dialog").first.get_by_role("button", name="OK").click()
            st["unsupported"] = False

            # German
            pg.get_by_role("button", name="Account menu").click(); pg.get_by_role("menuitemradio", name="Deutsch").click()
            pg.get_by_role("button", name="Verwalten: Heizung abends", exact=True).click(); pg.get_by_role("menuitem", name="Logik", exact=True).click()
            pg.get_by_role("dialog").first.get_by_role("button", name="Aktionen bearbeiten: Dann").click()
            ed = pg.get_by_role("dialog").last; ed.get_by_role("button", name="Aktion hinzufügen").wait_for(timeout=10000)
            check("German texts", ed.get_by_text("Dieses Programm ist aktiv").is_visible() and ed.get_by_role("button", name="Aktion hinzufügen").is_visible() and ed.get_by_label("Aktion 1: Verzögert").count() == 1)
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
