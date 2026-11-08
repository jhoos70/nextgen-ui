#!/usr/bin/env python3
"""Generates the architecture diagrams of the nextGen UI discussion as standalone SVG files (1600x900, 16:9).

    python3 make-diagrams.py            # writes 0N-*.svg next to this script

Everything on the diagrams is either read from this repository (.migration/ plans, the code) or MEASURED on the test
CCU (Raspberry Pi 4, firmware 3.89.11, 2026-11-08); each diagram says which. Edit the data below, not the SVG.
"""
import html, os, textwrap

W, H = 1600, 900
FONT = 'Inter, "Segoe UI", Helvetica, Arial, sans-serif'
INK, MUTED, LINE = "#1f2937", "#5b6472", "#c9d1dc"
# role colours: (fill, stroke)
C = {
    "ui": ("#dbeafe", "#2563eb"),      # browser side
    "web": ("#e5e7eb", "#6b7280"),     # web server
    "tcl": ("#fef3c7", "#d97706"),     # request-bound Tcl/CGI
    "go": ("#dcfce7", "#16a34a"),      # persistent daemon
    "closed": ("#f1f5f9", "#475569"),  # closed source / native
    "warn": ("#fee2e2", "#dc2626"),
    "plain": ("#ffffff", "#9aa5b5"),
}


def esc(s):
    return html.escape(s, quote=False)


class Svg:
    def __init__(self, title, subtitle):
        self.parts = []
        self.title, self.subtitle = title, subtitle

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=15, weight=400, fill=INK, anchor="start", italic=False):
        style = ' font-style="italic"' if italic else ""
        self.add(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}"{style}>{esc(s)}</text>')

    def lines(self, x, y, lines, size=14, gap=1.35, fill=INK, weight=400, anchor="start"):
        for i, ln in enumerate(lines):
            self.text(x, y + i * size * gap, ln, size, weight, fill, anchor)

    def wrap(self, body, w, size):
        """The body lines of a box as they will be drawn: '- ' starts a bullet, long lines are wrapped."""
        out = []
        for b in body:
            bullet = b.startswith("- ")
            raw = b[2:] if bullet else b
            width = max(10, int((w - 28 - (14 if bullet else 0)) / (size * 0.56)))
            parts = textwrap.wrap(raw, width) or [""]
            for i, p in enumerate(parts):
                out.append(("\u2022 " + p) if bullet and i == 0 else (("   " + p) if bullet else p))
        return out

    def height(self, w, body, size=15, tsize=17, title=True):
        return int(12 + (tsize + 8 if title else 0) + size * 1.2 + size * 1.35 * len(self.wrap(body, w, size)) + 14)

    def box(self, x, y, w, h, role="plain", title="", body=(), dash=False, size=15, tsize=17, rx=10, title_fill=None):
        """Draws a box; h=None sizes it to its text. Returns the height."""
        if h is None:
            h = self.height(w, body, size, tsize, bool(title))
        fill, stroke = C[role]
        d = ' stroke-dasharray="7 5"' if dash else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="2"{d}/>')
        ty = y + 12 + tsize
        if title:
            self.text(x + 14, ty, title, tsize, 700, title_fill or INK)
            ty += 8
        self.lines(x + 14, ty + size * 1.2, self.wrap(body, w, size), size, fill=INK)
        return h

    def arrow(self, x1, y1, x2, y2, label="", dash=False, color="#374151", both=False, lx=None, ly=None, anchor="middle", lsize=13):
        d = ' stroke-dasharray="8 6"' if dash else ""
        start = ' marker-start="url(#a)"' if both else ""
        self.add(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="2.4"{d} marker-end="url(#a)"{start}/>')
        if label:
            lx = (x1 + x2) / 2 if lx is None else lx
            ly = (y1 + y2) / 2 - 8 if ly is None else ly
            for i, ln in enumerate(label.split("\n")):
                self.text(lx, ly + i * lsize * 1.3, ln, lsize, 600, color, anchor)

    def legend(self, items, x=40, y=H - 84):
        for role, label, dash in items:
            fill, stroke = C[role]
            d = ' stroke-dasharray="6 4"' if dash else ""
            self.add(f'<rect x="{x}" y="{y}" width="26" height="18" rx="4" fill="{fill}" stroke="{stroke}" stroke-width="2"{d}/>')
            self.text(x + 34, y + 14, label, 13, 500, MUTED)
            x += 34 + len(label) * 7.2 + 26

    def footer(self, s):
        lines = textwrap.wrap(s, 200)
        for i, ln in enumerate(lines):
            self.text(40, H - 14 - 17 * (len(lines) - 1 - i), ln, 12.5, 400, MUTED)

    def write(self, path):
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family=\'{FONT}\'>'
                '<defs><marker id="a" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
                '<path d="M0,0 L10,5 L0,10 z" fill="#374151"/></marker></defs>'
                f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
        title = (f'<text x="40" y="52" font-size="30" font-weight="700" fill="{INK}">{esc(self.title)}</text>'
                 f'<text x="40" y="82" font-size="16" fill="{MUTED}">{esc(self.subtitle)}</text>')
        open(path, "w", encoding="utf-8").write(head + title + "".join(self.parts) + "</svg>\n")


here = os.path.dirname(os.path.abspath(__file__))


# ------------------------------------------------------------------------------------------------------------------
def d1():
    s = Svg("1  Today: the nextGen UI inside the CCU's own stack", "Refactor in place: static React app + Tcl CGI routes (/api/homematic.cgi/v2) + the existing bridges. No extra process.")
    top = 120
    h1 = s.box(40, top, 300, None, "ui", "Classic WebUI", ["served at /", "webui.js, ReGa pages (.htm / .esp)", "unchanged, stays long-term"])
    h2 = s.box(40, top + h1 + 24, 300, None, "ui", "nextGen UI (this repo)", [
        "- React 19, Vite, Tailwind 4, shadcn / Radix",
        "- one 718 kB bundle (203 kB gzipped)",
        "- at /webui/next/, EN / DE",
        "- session id in X-Session-Id header",
        "- data by polling, 10 s per list",
        "- no service worker, no push",
    ])
    hl = s.box(410, top, 330, None, "web", "lighttpd 1.4.84", [
        "mod_cgi, mod_proxy, mod_authn_rega",
        "- /webui/next/*  static files, about 5 ms per request (measured)",
        "- /api/homematic.cgi  v1 JSON-RPC, frozen contract, 180 methods",
        "- /api/homematic.cgi/v2/*  nextGen routes: model, values, programs (incl. editor), sysvars, favourites, messages, log, profile, system, events",
    ])
    ht = s.box(830, top, 380, None, "tcl", "One tclsh process PER REQUEST", [
        "about 80 ms for the cheapest request (measured: process start + session check)",
        "- dispatcher with privilege levels 0 / 1 / 2 / 8",
        "- v1: 183 method scripts in 19 namespaces",
        "- v2: JSON handlers, strict validation",
        "- ReGa scripts are FIXED text; values are bound as variables, never code",
        "- structure changes run on a working copy that is put back in one step",
        "- event queue: files in /tmp/event, filled only by API code; the long-poll route /events exists, the UI does not use it",
    ])
    s.box(1290, top, 270, None, "closed", "ReGaHss (closed source)", ["script engine, object model", "programs, rooms, system variables", "session store"])
    s.box(1290, top + 215, 270, None, "closed", "Interface processes", ["rfd (BidCos-RF), HmIPServer, hs485d", "XML-RPC", "devices, radio modules"])
    mid = top + 110
    s.arrow(340, mid + 120, 410, mid + 120, "HTTP\nJSON", both=True, lx=375, ly=mid + 84)
    s.arrow(740, mid, 830, mid, "CGI spawn", lx=785, ly=mid - 14)
    s.arrow(1210, top + 70, 1290, top + 70, "tclrega.so", lx=1250, ly=top + 48)
    s.arrow(1210, top + 290, 1290, top + 290, "tclrpc.so", lx=1250, ly=top + 268)
    s.arrow(1425, top + 215, 1425, top + 175, "", dash=True, color="#dc2626")
    s.text(1412, top + 192, "device events reach ReGa,", 12.5, 600, "#dc2626", anchor="end")
    s.text(1412, top + 208, "not the browser", 12.5, 600, "#dc2626", anchor="end")
    y = top + max(ht, hl, h1 + h2 + 24) + 40
    s.box(410, y, 1150, None, "warn", "What this stack cannot do on its own", [
        "- push: datapoint changes reach ReGa, but nothing sends them to the browser; the UI polls every 10 s (each poll = one process start + one ReGa script)",
        "- a persistent process (cache, held session, XML-RPC callbacks, WebSocket) does not fit a CGI; the modernizer left it as an optional, gated gateway",
    ])
    s.legend([("ui", "browser", False), ("web", "web server", False), ("tcl", "per-request Tcl", False), ("closed", "closed source / native", False), ("warn", "limit", False)])
    s.footer("Sources: .migration/webui-api/architect/target-architecture.md; code in src/webui/www/api/v2. Measured on the test CCU (Raspberry Pi 4, 4 cores, 3.8 GB, load 0.16): 12 requests each, medians 80 ms (CGI path, no ReGa script) and 5 ms (static).")
    s.write(os.path.join(here, "01-today-nextgen-in-ccu-stack.svg"))


def d2():
    s = Svg("2  MUI: a persistent Go backend", "Own daemon beside the web server: one WebSocket per browser, its own protocol, sessions and system services.")
    top = 120
    s.box(40, top, 300, None, "ui", "MUI front end (React PWA)", [
        "- installable, service worker (workbox)",
        "- 259 lazily loaded assets (248 gzipped)",
        "- German first",
        "- talks ONLY to the Go daemon, by WebSocket",
        "- Web Push notifications",
    ])
    s.box(410, top, 300, None, "web", "lighttpd", [
        "- /addons/mui/*  static files",
        "- /addons/mui/ws  proxied to 127.0.0.1:8088 with Upgrade (mod_proxy)",
        "- config in /usr/local/etc/config/lighttpd/mui.conf (writable, survives updates)",
        "- add-on installed through the CCU's 'Additional software' page",
    ])
    inner = [
        ("WebSocket hub", ["JSON messages: getProgram, saveRule, setDatapoint, subscribePush, getHistory ..."]),
        ("Own sessions and audit", ["mui-sessions.json, mui-auth.key, audit log; AUTH_MODE = ccu or none (none: everyone on the network can control all devices)"]),
        ("Interface clients", ["XML-RPC client + callback server: events are PUSHED in; seen connected: local ports 32001, 32010"]),
        ("ReGa access", ["builds ReGa scripts in Go (string formatting) and runs them: programs, rules, system variables, rooms"]),
        ("System services", ["backups, firmware, certificates, network, reboot, add-on self-update"]),
        ("Web Push (VAPID)", ["sends notifications when the tab is closed"]),
    ]
    gx, gw = 790, 520
    heights = [s.height(gw - 36, body, 14, 15.5) for _, body in inner]
    total = 44 + sum(heights) + 8 * len(heights) + 6
    s.box(gx, top, gw, total, "go", "ccu-addon-mui-server (Go, static ARM, 10 MB)", [])
    y = top + 44
    for name, body in inner:
        y += s.box(gx + 18, y, gw - 36, None, "plain", name, body, size=14, tsize=15.5, rx=8) + 8
    s.box(1390, top, 170, None, "closed", "ReGaHss", ["closed source", "programs, sysvars"])
    s.box(1390, top + 150, 170, None, "closed", "Interfaces", ["rfd, HmIPServer", "XML-RPC"])
    s.box(1390, top + 300, 170, None, "closed", "Files / OS", ["backup, firmware, certificates"])
    s.arrow(340, top + 100, 410, top + 100, "WSS", both=True, lx=375, ly=top + 78)
    s.arrow(710, top + 100, 790, top + 100, "proxy", both=True, lx=750, ly=top + 78)
    s.arrow(1310, top + 60, 1390, top + 60, "scripts", lx=1350, ly=top + 38)
    s.arrow(1310, top + 200, 1390, top + 200, "XML-RPC\n+ events", both=True, lx=1350, ly=top + 150)
    s.arrow(1310, top + 340, 1390, top + 340, "", lx=1350)
    s.box(40, top + 280, 670, None, "go", "Measured on the test CCU (Pi 4)", [
        "- running for 146 h without a restart",
        "- resident memory 20 MB, 12 threads (virtual size 577 MB is address space only)",
        "- CPU: 4047 s in 146 h = 0.77 % of ONE core on average",
        "- 10 MB binary, cross-compiled per architecture",
        "- AGPL-3.0 (see slide 4)",
    ])
    s.legend([("ui", "browser", False), ("web", "web server", False), ("go", "persistent Go process", False), ("closed", "closed source / native", False)])
    s.footer("Sources: read-only inspection of /usr/local/addons/mui on the test CCU, its rc.d script, process list, open sockets and the text inside the binary (names of messages, environment variables, ports). Source code not reviewed.")
    s.write(os.path.join(here, "02-mui-go-backend.svg"))


def d3():
    s = Svg("3  Candidate: keep the CGI, add an optional push relay", "Commands and reads stay on the tested v2 routes; a small read-only process only PUSHES changes. If it is not installed, the UI polls as today.")
    top = 120
    s.box(40, top, 300, None, "ui", "nextGen UI", [
        "- same SPA as today",
        "- new hook useLive(): tries push first, falls back to polling every 10 s",
        "- commands still go to the v2 routes",
    ])
    hl = s.box(410, top, 300, None, "web", "lighttpd", [
        "- /api/.../v2/*  CGI as today",
        "- /webui/next/live  proxied to the relay (SSE or WebSocket)",
        "- rule in /usr/local/etc/config/lighttpd (no remount)",
    ])
    hc = s.box(790, top, 400, None, "tcl", "v2 CGI routes (unchanged)", [
        "- session check, levels 0 / 1 / 2 / 8",
        "- NEW: live-ticket route: after the normal session check it writes a one-time ticket (file in /tmp) and returns it",
        "- all writes stay here, with their tests",
    ])
    hg = s.box(1290, top, 270, None, "closed", "ReGaHss", ["closed source", "unchanged"])
    ry = top + hc + 70
    hr = s.box(790, ry, 400, None, "go", "Push relay (optional add-on, gated)", [
        "- one process, listens on 127.0.0.1 only",
        "- accepts a connection only with a valid one-time ticket; keeps the user's level",
        "- registers XML-RPC callbacks with the interfaces: device events arrive",
        "- polls ReGa for system variables, alarms and service messages, sends only differences",
        "- READ-ONLY: no commands, no ReGa writes",
    ], dash=True)
    s.box(1290, ry, 270, None, "closed", "Interface processes", ["rfd, HmIPServer, hs485d", "unchanged", "call the relay back with events"])
    s.arrow(340, top + 60, 410, top + 60, "HTTP", both=True, lx=375, ly=top + 38)
    s.arrow(710, top + 60, 790, top + 60, "CGI", lx=750, ly=top + 38)
    s.arrow(1190, top + 60, 1290, top + 60, "tclrega.so", lx=1240, ly=top + 38)
    s.arrow(990, top + hc, 990, ry, "one-time ticket", dash=True, color="#16a34a", lx=1002, ly=top + hc + 36, anchor="start")
    s.arrow(660, top + hl, 790, ry + 60, "SSE / WebSocket + ticket", dash=True, color="#16a34a", lx=560, ly=ry - 24)
    s.arrow(1190, ry + 120, 1290, ry + 120, "events", dash=True, color="#16a34a", lx=1240, ly=ry + 98)
    s.arrow(1190, ry + 30, 1330, top + hg, "poll state", dash=True, color="#16a34a", lx=1236, ly=top + hc + 36, anchor="end")
    s.box(40, ry, 660, None, "plain", "Why this shape", [
        "- keeps the frozen v1 contract and its 1,390 Tcl contract tests: nothing is rewritten",
        "- the relay has no write path, so a bug there cannot change a program or a device",
        "- the CCU's own session and privilege model stays the single source of truth (a ticket, not a second login)",
        "- optional: a CCU without the relay works exactly as today",
        "- written from scratch (Apache-2.0); no code or protocol taken from MUI (AGPL)",
        "- language open: Go (static ARM binary, like MUI) or C++ / Tcl (already in the build, as the modernizer suggested)",
    ])
    s.legend([("ui", "browser", False), ("web", "web server", False), ("tcl", "per-request Tcl", False), ("go", "optional persistent process", True), ("closed", "closed source / native", False)])
    s.footer("This is the 'optional gateway, gated' of the modernizer (.migration/webui-api/architect/target-architecture.adr.md), narrowed to push only. Not built; the ticket step and the XML-RPC callbacks are untested ideas.")
    s.write(os.path.join(here, "03-candidate-cgi-plus-push-relay.svg"))


def d4():
    s = Svg("4  Options compared", "Four ways to carry the nextGen UI. Cells are facts from the repo or measurements where possible; the last row is an opinion for discussion.")
    cols = [
        ("A  Current", "refactor in place", "ui"),
        ("B  A + push relay", "optional add-on", "go"),
        ("C  Full Go backend", "MUI-style, own protocol", "tcl"),
        ("D  Adopt / fork MUI", "its front end and server", "warn"),
    ]
    rows = [
        ("Live updates", ["10 s polling; long-poll route exists, unused", "push for events, polling as fallback", "push, built in", "push, built in"]),
        ("Cost per request (Pi 4)", ["80 ms floor (process per request) + ReGa", "same for commands; one socket for updates", "no process start; daemon 20 MB, 0.8 % CPU (MUI measured)", "same as C"]),
        ("v1 contract, 180 methods", ["kept, hardened, 133 call sites", "kept", "re-implemented (71 ReGa + 51 XML-RPC methods) or dropped", "not applicable: own protocol"]),
        ("Security model", ["CCU session + levels; fixed scripts, tested", "adds ticket auth; relay read-only", "new auth and audit surface to build and test", "own sessions, optional AUTH_MODE=none; scripts built by formatting (not audited)"]),
        ("Install / update", ["installer, needs / remounted rw", "plus one add-on", "add-on, cross-compile per architecture", "add-on, release binary"]),
        ("Tests", ["1,390 Tcl contract tests (10 components), 19 browser suites", "plus relay tests (to write)", "whole new suite (to write)", "upstream's"]),
        ("Licence", ["Apache-2.0 (+ HMSL for eQ-3 parts)", "Apache-2.0", "your choice", "AGPL-3.0: derived work is AGPL"]),
        ("Effort / rollback", ["done, ongoing; restore a backup", "small to medium; remove the add-on", "large rewrite risk; hard to undo", "low to adopt; dependency, little control"]),
    ]
    x0, y0, cw, lw, rh = 40, 108, 330, 220, 72
    # header
    for i, (t, sub, role) in enumerate(cols):
        x = x0 + lw + i * cw
        fill, stroke = C[role]
        s.add(f'<rect x="{x}" y="{y0}" width="{cw - 8}" height="62" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="2"/>')
        s.text(x + 12, y0 + 27, t, 17, 700)
        s.text(x + 12, y0 + 48, sub, 13, 400, MUTED)
    for r, (name, cells) in enumerate(rows):
        y = y0 + 72 + r * rh
        s.add(f'<rect x="{x0}" y="{y}" width="{lw - 8}" height="{rh - 8}" rx="8" fill="#f8fafc" stroke="{LINE}" stroke-width="1.5"/>')
        s.text(x0 + 12, y + 30, name, 15, 700)
        for i, c in enumerate(cells):
            x = x0 + lw + i * cw
            s.add(f'<rect x="{x}" y="{y}" width="{cw - 8}" height="{rh - 8}" rx="8" fill="#ffffff" stroke="{LINE}" stroke-width="1.5"/>')
            s.lines(x + 12, y + 24, textwrap.wrap(c, 41), 13.5, gap=1.3)
    y = y0 + 72 + len(rows) * rh
    s.add(f'<rect x="{x0}" y="{y}" width="{lw - 8}" height="62" rx="8" fill="#fef9c3" stroke="#ca8a04" stroke-width="2"/>')
    s.text(x0 + 12, y + 28, "Read (opinion)", 15, 700)
    verdicts = ["baseline; right while push is not needed", "best next step IF live updates matter", "only if the v1 contract and the classic UI are given up", "not combinable with an Apache tree; a different product"]
    for i, v in enumerate(verdicts):
        x = x0 + lw + i * cw
        s.add(f'<rect x="{x}" y="{y}" width="{cw - 8}" height="62" rx="8" fill="#fef9c3" stroke="#ca8a04" stroke-width="2"/>')
        s.lines(x + 12, y + 25, textwrap.wrap(v, 41), 13.5, gap=1.3)
    s.footer("Sources: modernizer ADR (rejected: full rewrite, gateway now, microservices); MUI measured on the test CCU; licences from LICENSE files. Not legal advice. Pi 4 numbers are not CCU3 hardware: repeat on the target boards before deciding.")
    s.write(os.path.join(here, "04-options-compared.svg"))


# ------------------------------------------------------------------------------------------------------------------
def d5():
    s = Svg("5  The modernizer's drivers, re-checked", "The October decision (refactor in place, gateway only after a measurement gate) rested on six drivers. What do we know now?")
    rows = [
        ("Frozen v1 contract; 133 call sites", "still true", "The nextGen UI uses the ADDITIVE v2 routes. A new backend would only have to replace v1 if the classic UI is replaced too (it is not: long-term coexistence).", "unchanged"),
        ("Small device, tclsh per request", "measured", "Test CCU: Pi 4, 4 cores, 3.8 GB RAM, load 0.16. A persistent Go process (MUI) costs 20 MB and 0.8 % of one core. The process-per-request floor is 80 ms vs 5 ms static. Other boards (older CCU3 hardware, small VMs) are NOT measured.", "weakens 'too heavy'"),
        ("No tests, high regression risk", "changed", "1,390 Tcl contract tests in 10 components (the programs route alone has 60), 19 browser suites and golden fixtures for v1 now exist; 16 older tests fail and are known. A rewrite would throw this away; a relay can add to it.", "favours keeping the code"),
        ("Closed ReGa / XML-RPC only as Tcl extensions", "partly outdated", "MUI shows that a Go program can speak XML-RPC and run ReGa scripts itself. It also rebuilt authentication and the privilege model. Possible, not free.", "no longer a blocker"),
        ("Classic and nextGen must coexist", "still true", "A full Go backend would be a THIRD stack beside Tcl (classic) and the CGI routes. An optional relay is a small second process.", "favours B over C"),
        ("Gateway only after a measurement gate", "gate reached", "What a CGI cannot offer at all is push; per-request cost is moderate (80 ms floor, not measured under load). Polling many lists is where it adds up, which I have NOT measured. That points at the narrow gateway of slide 3 rather than a rewrite, but the load test is still open.", "decision: B or stay on A"),
    ]
    cw = [330, 140, 800, 200]
    xs = [40]
    for w in cw[:-1]:
        xs.append(xs[-1] + w + 8)
    heads = ["Driver (October)", "Status", "Evidence", "Effect"]
    y = 112
    for i, h in enumerate(heads):
        s.add(f'<rect x="{xs[i]}" y="{y}" width="{cw[i]}" height="40" rx="8" fill="#0f172a"/>')
        s.text(xs[i] + 12, y + 26, h, 15, 700, "#ffffff")
    rh = 114
    badge = {"still true": "#dcfce7", "measured": "#dbeafe", "changed": "#fef3c7", "partly outdated": "#fef3c7", "gate reached": "#fee2e2"}
    for r, (drv, st, ev, eff) in enumerate(rows):
        yy = y + 48 + r * rh
        for i, w in enumerate(cw):
            fill = badge[st] if i == 1 else "#ffffff"
            s.add(f'<rect x="{xs[i]}" y="{yy}" width="{w}" height="{rh - 8}" rx="8" fill="{fill}" stroke="{LINE}" stroke-width="1.5"/>')
        s.lines(xs[0] + 12, yy + 26, textwrap.wrap(drv, 34), 15, weight=700, gap=1.3)
        s.text(xs[1] + 12, yy + 28, st, 14, 700)
        s.lines(xs[2] + 12, yy + 24, textwrap.wrap(ev, 100), 14.5, gap=1.32)
        s.lines(xs[3] + 12, yy + 26, textwrap.wrap(eff, 22), 14, weight=600, gap=1.3)
    s.footer("Sources: .migration/webui-api/architect/target-architecture.adr.md and plan/webui-api.plan.md ('Rejected Options', 'Decision gate for gateway'); measurements of 2026-11-08 on the test CCU.")
    s.write(os.path.join(here, "05-modernizer-drivers-rechecked.svg"))


# ------------------------------------------------------------------------------------------------------------------
def d6():
    s = Svg("6  Why live updates are the real gap: polling vs push", "Same screen, same data: what the CCU does for it.")
    s.box(40, 120, 1520, 290, "tcl", "Polling (today): every 10 s, per list and per open tab", [])
    xs = [80, 380, 680, 980, 1280]
    for i, x in enumerate(xs):
        s.box(x, 170, 240, None, "plain", "t = %d s" % (i * 10), ["process start (about 80 ms)", "+ one ReGa script", "= an answer, often unchanged"], size=13, tsize=14.5)
        if i < len(xs) - 1:
            s.arrow(x + 240, 215, xs[i + 1], 215, "+10 s", color="#d97706", lx=x + 270, ly=198, lsize=12.5)
    s.lines(60, 318, [
        "- every poll costs a process start plus a ReGa script, even when nothing changed",
        "- N tabs x M lists = N x M polls per 10 s; the screen is up to 10 s behind",
        "- the page already pauses polling while the tab is hidden (use-polled.ts)",
    ], 14.5, gap=1.5)
    s.box(40, 440, 1520, 330, "go", "Push (candidate relay): one open connection, an event only when something changed", [], dash=True)
    s.box(80, 495, 260, None, "plain", "browser", ["one SSE / WebSocket connection"], size=13, tsize=14.5)
    s.box(560, 495, 300, None, "go", "relay", ["receives XML-RPC events", "diffs ReGa state"], size=13, tsize=14.5)
    s.box(1080, 495, 260, None, "closed", "interfaces / ReGa", ["events, state"], size=13, tsize=14.5)
    s.arrow(340, 530, 560, 530, "open once (ticket)", color="#16a34a", lx=450, ly=510)
    s.arrow(560, 566, 340, 566, "event only on change", dash=True, color="#16a34a", lx=450, ly=590)
    s.arrow(1080, 530, 860, 530, "callbacks", color="#16a34a", lx=970, ly=510)
    s.lines(60, 660, [
        "- no process start per update; the screen follows within about a second",
        "- commands (switch, edit a program) stay on the tested v2 routes",
        "- costs a second process (MUI's equivalent on the Pi 4: 20 MB, 0.8 % of one core), a ticket step and its own tests",
    ], 14.5, gap=1.5)
    s.footer("Numbers: measured on the test CCU (Pi 4) on 2026-11-08. Polling interval and hidden-tab behaviour: src/webui/next/src/lib/use-polled.ts. The relay is a proposal, not built.")
    s.write(os.path.join(here, "06-polling-vs-push.svg"))


for f in (d1, d2, d3, d4, d5, d6):
    f()
print("written:", ", ".join(sorted(x for x in os.listdir(here) if x.endswith(".svg"))))
