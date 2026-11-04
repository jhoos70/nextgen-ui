#!/usr/bin/env python3
"""Browser test of the programs page of the nextGen UI: status and control (the list and the run).

    python3 next_programs.py --base http://127.0.0.1:18080 --user Admin --password Admin

REAL runs on the test CCU: a bare test program is created with a ReGa script (the test CCU has none), listed, run through
the page and deleted again in every case; each run is checked through the v1 API and the classic list. Mocked answers cover
what a bare program cannot show: programs the classic list leaves out (not operable, copies, internal), the server's
refusals, an expired session, German and the user level. Two logins (the v2 login is rate limited). TEST CCU only.
"""
import argparse, json, re, sys
from datetime import datetime
from playwright.sync_api import sync_playwright

NOISE = ("Synchronous XMLHttpRequest", "Synchrone XMLHttpRequest", "file:///", "favicon")
V1 = """async ([method, sid, params]) => {
  const r = await fetch('/api/homematic.cgi', {method: 'POST', body: JSON.stringify({version: '1.1', method, params: {_session_id_: sid, ...params}})});
  return (await r.json()).result;
}"""
PROFILE = {"userId": "1004", "userName": "Admin", "firstName": "Admin", "hasPassword": True, "isNoExpert": True, "language": "", "level": "ADMIN"}


def prog(id, name, **kw):
    d = {"id": id, "name": name, "description": kw.pop("description", ""), "lastExecuteTime": "2026-10-31 10:00:00", "isActive": True, "isInternal": False, "isOperable": True, "isCopy": False}
    d.update(kw)
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--user", default="Admin")
    ap.add_argument("--password", required=True)
    a = ap.parse_args()
    results, console, sids, posts = [], [], [], []

    def check(name, ok, detail=""):
        results.append(ok)
        print("%s  %s %s" % ("PASS" if ok else "FAIL", name, detail))

    state = {"model": None, "post": None, "profile": None}

    def on_model(route):
        if state["model"] is None:
            return route.continue_()
        route.fulfill(status=200, content_type="application/json", body=json.dumps({"programs": {"total": len(state["model"]), "offset": 0, "limit": 500, "items": state["model"]}}))

    def on_post(route):
        if route.request.method != "POST":
            return route.continue_()
        posts.append(route.request.post_data)
        if state["post"] is None:
            return route.continue_()
        status, body = state["post"]
        route.fulfill(status=status, content_type="application/json", body=json.dumps(body))

    def on_profile(route):
        if state["profile"] is None:
            return route.continue_()
        route.fulfill(status=200, content_type="application/json", body=json.dumps({**PROFILE, **state["profile"]}))

    with sync_playwright() as p:
        browser = p.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1100, "height": 900})
        pg = ctx.new_page()

        def on_response(r):
            try:
                if r.request.method == "POST" and '"Session.login"' in (r.request.post_data or "") and r.ok:
                    sid = r.json().get("result")
                    if isinstance(sid, str):
                        sids.append(sid)
            except Exception:
                pass

        pg.on("response", on_response)
        pg.on("console", lambda m: m.type == "error" and not any(n in m.text for n in NOISE) and console.append(m.text[:140]))
        pg.route("**/v2/model?sections=programs*", on_model)
        pg.route("**/v2/programs", on_post)
        pg.route("**/v2/profile", on_profile)
        sid, name = None, "ZZtestprog"

        def v1(method, **params):
            return pg.evaluate(V1, [method, sid, params])

        def row(n):
            return pg.locator("tbody tr", has=pg.get_by_text(n, exact=True))

        try:
            pg.goto(a.base + "/webui/next/"); pg.wait_for_selector("#user")
            pg.fill("#user", a.user); pg.fill("#password", a.password); pg.keyboard.press("Enter")
            pg.wait_for_selector("aside nav a")
            sid = pg.evaluate("JSON.parse(sessionStorage.getItem('openccu.next.session')).sid")
            pg.get_by_role("link", name="Programs").click(); pg.get_by_role("heading", name="Programs").wait_for()
            pg.get_by_text("No programs available.").wait_for()
            check("a CCU without programs says so (real answer)", True)

            # ---- a real test program (a bare one, made by script)
            # ReGa may append a number to a name it has used before: the name that comes back is the one used from here on
            out = v1("ReGa.runScript", script='object p = dom.CreateObject(OT_PROGRAM); p.Name("ZZtestprog"); dom.GetObject(ID_PROGRAMS).Add(p.ID()); p.PrgInfo("ein Testprogramm"); p.Active(true); Write(p.ID() # "|" # p.Name());')
            pid, name = str(out).strip().split("|", 1)
            check("a test program was created", pid.isdigit(), "%s %r" % (pid, name))
            pg.evaluate("document.dispatchEvent(new Event('visibilitychange'))")
            pg.get_by_text(name, exact=True).wait_for()
            heads = [h.strip() for h in pg.locator("thead th").all_inner_texts()]
            check("the columns are those of the classic list, plus Active", heads == ["Name", "Description", "Last run", "Active", "Action"], str(heads))
            check("the description is shown", "ein Testprogramm" in row(name).inner_text())

            # the classic list is the reference
            classic = browser.new_page()
            classic.goto(a.base + "/login.htm"); classic.fill("#UserNameShow", a.user); classic.fill("#Password", a.password); classic.keyboard.press("Enter")
            classic.wait_for_load_state("networkidle"); classic.wait_for_timeout(2500)
            classic.evaluate("() => document.getElementById('menuControlPage_TITLE').click()"); classic.wait_for_timeout(400)
            classic.evaluate("() => document.querySelector('#menuControlPage_SUBMENU #submenuPrograms').click()"); classic.wait_for_timeout(2500)
            crow = [re.sub(r"\s+", " ", t.replace("\xa0", " ")).strip() for t in classic.locator("tr[id^=pr]").first.locator("td").all_inner_texts()]
            classic.evaluate("() => { const e=[...document.querySelectorAll('div')].find(d=>d.innerText.trim()==='Logout' && d.children.length===0); e && e.click(); }"); classic.wait_for_timeout(500); classic.close()
            check("the classic list shows the same program with the same description", crow[0] == name and crow[1] == "ein Testprogramm", str(crow))
            ui_last = [t.strip() for t in row(name).locator("td").all_inner_texts()][2]
            ui_dt = datetime.strptime(ui_last, "%b %d, %Y, %I:%M:%S %p").strftime("%d.%m.%Y %H:%M:%S")
            check("the last run is the classic one", ui_dt in " ".join(crow), "%s / %s" % (ui_dt, crow))

            # ---- run it
            import time
            before = v1("Program.getAll")[0]["lastExecuteTime"]; time.sleep(1.3)
            del posts[:]
            pg.get_by_role("button", name="Run: " + name).click()
            pg.get_by_text(name + " was started.").wait_for()
            check("one request: the id and execute", len(posts) == 1 and json.loads(posts[0]) == {"id": pid, "execute": True}, str(posts))
            after = v1("Program.getAll")[0]["lastExecuteTime"]
            check("the CCU ran the program (its last run moved, checked through the v1 API)", after > before, "%s -> %s" % (before, after))
            ui_last2 = [t.strip() for t in row(name).locator("td").all_inner_texts()][2]
            check("the row shows the new last run", datetime.strptime(ui_last2, "%b %d, %Y, %I:%M:%S %p").strftime("%Y-%m-%d %H:%M:%S") == after, ui_last2)
            check("the result is announced in a status region", "was started" in pg.locator("[role=status]").last.inner_text())
            pg.get_by_label("Filter").fill("gibtesnicht")
            check("no match says so", pg.get_by_text("No program matches the filter.").is_visible())
            pg.get_by_label("Filter").fill("testpro")
            check("the filter finds it by name", pg.locator("tbody tr").count() == 1)
            pg.get_by_label("Filter").fill("")

            # ---- an inactive program can be run by hand, as in the classic UI
            v1("ReGa.runScript", script='dom.GetObject(%s).Active(false);' % pid)
            time.sleep(1.3); pg.get_by_role("button", name="Run: " + name).click(); pg.get_by_text(name + " was started.").wait_for()
            check("an inactive program runs too", v1("Program.getAll")[0]["lastExecuteTime"] > after)

            # ---- mocked: what the classic list leaves out, refusals, German, levels
            state["model"] = [prog("1", "Licht 10", description="Abends"), prog("2", "Licht 2"), prog("3", "Nur Admin", isOperable=False), prog("4", "Kopie", isCopy=True), prog("5", "System", isInternal=True), prog("6", "Nie", lastExecuteTime="1970-01-01 01:00:00")]
            pg.reload(); pg.get_by_text("Licht 2", exact=True).wait_for()
            names = [t.split("\t")[0].strip() for t in pg.locator("tbody tr").all_inner_texts()]
            check("copies and internal programs are left out, names sort naturally; an administrator also sees what users may not operate", names == ["Licht 2", "Licht 10", "Nie", "Nur Admin"], str(names))
            check("a program that never ran shows a dash", "—" in row("Nie").inner_text())
            for status, body, words, label in ((403, {"error": {"code": 400, "message": "access denied"}}, "not allowed", "no right (403)"),
                                              (404, {"error": {"code": 501, "message": "program not found"}}, "does not exist", "a program that is gone (404)"),
                                              (500, {"error": {"code": 200, "message": "internal secret"}}, "refused", "a server error (500)")):
                state["post"] = (status, body)
                pg.get_by_role("button", name="Run: Licht 2").click(); pg.get_by_text("could not be started").wait_for()
                msg = pg.locator("[role=status]").last.inner_text()
                check("%s: a message naming the program, the page stays usable" % label, "Licht 2" in msg and words in msg and "secret" not in msg and pg.get_by_role("button", name="Run: Licht 2").is_enabled(), msg)
            state["post"] = (200, {"id": "2", "executed": False, "lastExecuteTime": "2026-10-31 22:00:00"})
            pg.get_by_role("button", name="Run: Licht 2").click(); pg.get_by_text("Licht 2 did not start.").wait_for()
            check("executed false is told as such", True)
            del console[:]  # the browser logs the deliberate 4xx/5xx as errors
            state["post"] = None

            pg.get_by_role("button", name="Account menu").click(); pg.get_by_role("menuitemradio", name="Deutsch").click()
            pg.get_by_role("heading", name="Programme").wait_for()
            body = pg.inner_text("main")
            check("the page is German", "Status und Bedienung" in body and "Letzte Ausführung" in body and "Aktion" in body and pg.get_by_role("button", name="Ausführen: Licht 2").is_visible())
            state["post"] = (200, {"id": "2", "executed": True, "lastExecuteTime": "2026-10-31 22:00:00"})
            pg.get_by_role("button", name="Ausführen: Licht 2").click(); pg.get_by_text("Licht 2 wurde gestartet.").wait_for()
            check("the message is German", True)
            pg.get_by_role("button", name="Benutzermenü").click(); pg.get_by_role("menuitemradio", name="English").click()

            state["profile"] = {"level": "USER"}
            pg.reload(); pg.get_by_text("Licht 2", exact=True).wait_for()
            check("a user may run programs (as in the classic UI)", pg.get_by_role("button", name="Run: Licht 2").is_visible())
            check("no console errors", not console, str(console))
            state["post"] = (401, {"error": {"code": 400, "message": "access denied (session level 0)"}})  # the browser logs the deliberate 401
            pg.get_by_role("button", name="Run: Licht 2").click(); pg.wait_for_selector("#user", timeout=10000)
            check("an expired session while running returns to the sign-in form", pg.evaluate("sessionStorage.length") == 0)
        finally:
            state["model"] = None; state["post"] = None; state["profile"] = None
            try:
                if sid:
                    v1("Program.deleteProgramByName", name=name)
            except Exception as e:
                print("cleanup problem:", e)
            for s in sids:
                try:
                    pg.request.post(a.base + "/api/homematic.cgi/v2/rpc", headers={"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest", "X-Session-Id": s},
                                    data=json.dumps({"version": "1.1", "method": "Session.logout", "params": {}, "id": 1}))
                except Exception:
                    pass
            browser.close()
    print("\n%d PASS, %d FAIL" % (results.count(True), results.count(False)))
    return 1 if False in results else 0


if __name__ == "__main__":
    sys.exit(main())
