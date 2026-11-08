# Architecture discussion: nextGen UI vs a MUI-style Go backend

Seven diagrams (standalone SVG, 16:9) and the evidence behind them. Regenerate with `python3 make-diagrams.py`.

| File | Shows |
|---|---|
| `01-today-nextgen-in-ccu-stack.svg` | The current design: static React app + Tcl CGI routes inside lighttpd |
| `02-mui-go-backend.svg` | MUI: a persistent Go daemon with its own WebSocket protocol, sessions and system services |
| `03-candidate-cgi-plus-push-relay.svg` | Candidate: keep the CGI, add an optional, read-only push relay |
| `04-options-compared.svg` | A current, B A + relay, C full Go backend, D adopt or fork MUI, over eight criteria |
| `05-modernizer-drivers-rechecked.svg` | The six drivers of the October decision, re-checked against today's evidence |
| `06-polling-vs-push.svg` | What polling and push cost the CCU for the same screen |
| `07-coupling-to-upstream.svg` | What merging upstream cost, the three kinds of coupling, and how MUI relates to upstream differently |

## What the modernizer decided (`.migration/webui-api/architect/`)

Style: **refactor in place** (lighttpd CGI + Tcl executors), React SPA same-origin, v2 routes acting as the BFF. Rejected: microservices,
serverless, rebuild as a modular monolith, a React-specific BFF, a full rewrite in a new runtime, "gateway now". An optional persistent
gateway (SSE and caching) was left to a **measurement gate** after phases 0 to 2.

## Measured on the test CCU (Raspberry Pi 4, 2026-11-08), read-only

- board: 4 cores, 3.8 GB RAM, load 0.16, uptime 32 days
- MUI's Go server: 146 h running, 20 MB resident, 12 threads, 4047 s CPU = **0.77 % of one core** on average, 10 MB static ARM binary
- one request through our CGI path (no ReGa script): median **80 ms** (min 80, max 121); a static file: median **5 ms** (12 samples each)

Not measured: other boards (older CCU3 hardware, small VMs), load with several tabs, an authenticated ReGa-heavy request on the CCU3.

## Reading of the evidence (opinion, for discussion)

1. The gap is **push**, not request speed. A CGI cannot hold connections or receive XML-RPC callbacks.
2. A full Go backend (C) would be a third stack and would have to redo the 183 Tcl methods behind the v1 contract (71 ReGa-based, 51
   XML-RPC-based) or leave them behind, and rebuild authentication, privilege levels and tests. MUI shows it is possible, not free.
3. The narrow option (B) keeps what is tested, adds nothing that can write, and is optional. It matches the modernizer's own "optional,
   gated gateway", narrowed to push.
4. Adopting or forking MUI (D) is a different product: AGPL-3.0, its own protocol and auth. Copying its code into this Apache-2.0 tree is
   not possible; its ideas are free to use.

## Coupling to upstream (slide 7, and a row on slide 4)

The merge of 103 upstream commits on 2026-11-08 gave no conflict in the 114 files of the nextGen app. The cost came from the 103 API files this
branch keeps inside upstream's `www/api` tree (5 changed on both sides) and from the tests that pin upstream's behaviour (about 30 edits).
MUI does not have merge conflicts (separate add-on, build-time data import), but re-implements classic behaviour, so it drifts silently.
Reducing it for option A: apply our `methods.conf` entries one by one, offer the hardening upstream, derive test counts from the registry,
merge upstream weekly.

## Questions for the discussion

- Is live update (push, notifications) a requirement, or is 10 s polling good enough for the users?
- Which boards must be supported? The numbers above are from a Pi 4.
- Is a second on-device process acceptable to the OpenCCU maintainers? If yes, in which language (Go static binary, or C++ / Tcl that is
  already in the build)?
- Should nextGen stay Apache-2.0 inside OpenCCU-Base, or move out under its own licence?
- Who owns the install path: the installer with a remount, or an add-on package?

## Caveats

- MUI facts come from inspecting the installed add-on (files, rc.d script, sockets, text inside the binary), not from its source code.
- The relay in slide 3 is a proposal. The ticket step and the XML-RPC callback registration are untested ideas.
- Licence remarks are not legal advice.
