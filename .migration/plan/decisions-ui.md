# UI migration decisions

Decided 2026-10-31 (user). These supersede the "working hypothesis" in `.migration/plan-context.md`
and the strangler-inside-the-shell approach in `webui-shell-build.plan.md` (phases 1-4).

## D1. Charset: staged UTF-8

- Stage 1: the build fails loudly instead of silently dropping non-Latin-1 characters
  (`www_source/utf82ansi.py` uses `errors="ignore"`). Served output stays ISO-8859-1 and
  byte-identical, so the 64 OpenCCU rootfs patches (41 on `webui.js`) keep applying.
- Stage 2 (later, coordinated with OpenCCU): serve UTF-8 in one release; regenerate the patches.

## D2. Architecture: hybrid, classic and nextGen side by side

- The classic UI (shell, `webui.js`, `cp_*`/`ic_*` fragments) stays intact and keeps working at `/`.
- The nextGen UI is a separate app with its own entry point (working name `/next/`), built on
  `/api/v2`, sharing backend and session with the classic UI.
- Pages the nextGen UI does not cover link back to the classic UI.
- Consequence: the shell-build phases 1-4 (theming, Bootstrap, bundler, components) apply to the
  new app, not to the classic bundle. The classic `webui.js` structure and the OpenCCU patches
  stay untouched.
- Consequence: pages that need program or room editing stay classic until the API has endpoints
  for them.

## Process

- No push and no PR for `feature/webui-api-hardening` or `chore/retire-www-copy` until the nextGen
  UI exists and is tested end to end. Everything stays local (origin is a public fork).

## D3. Dependencies: open source only

- Only OSI-approved open-source licences compatible with the project's Apache-2.0 (MIT, BSD, Apache-2.0, ISC).
  No commercial or paid UI libraries (KendoReact is ruled out). Check the licence of each dependency
  and its transitive dependencies before adoption.

## D4. nextGen stack: React + TypeScript + Vite + shadcn/ui (Tailwind)

Decided 2026-10-31 after a spike (scratch build, not in the repo): one screen with form, Radix dialog
and table built clean and ran without console errors; React 19 = 91 KB gzipped JS, Preact via
`preact/compat` = 32 KB and behaved the same (dialog, label and slot only were tested).

- Start on React; the Preact alias in `vite.config.ts` stays an optional later optimisation.
- Components are copied into the repo in the shadcn/ui way (Radix primitives, cva, tailwind-merge);
  we own and maintain that code.
- Licences: shipped dependencies of the spike are MIT, Apache-2.0 and 0BSD; build tools are permissive
  except lightningcss (MPL-2.0, build only, not shipped). Verify shadcn/ui's own licence before
  copying its code; re-scan the real dependency tree when the app skeleton exists.
- Node enters the build as an optional CMake target (`npm ci && npm run build`, pinned lockfile),
  off by default until the sibling OpenCCU build can run it; a build without Node still produces
  the classic UI. Built output is not committed (see the removal of the committed `www/`).

## D5. Routing: Route B now, Route A (sibling lighttpd config) maybe later

lighttpd's config lives in the OpenCCU packaging repository (`overlay/base/etc/lighttpd/conf.d/webui.conf`).
It forwards every URL outside `^/(config/|upnp/|webui/|ise/|api/|tools/|pda|addons|tailscale/)` to ReGa, and
only `*.cgi` goes to Tcl, so neither `/next/` nor `/api/v2/rpc` work without changing that repository.

- Route B (decided 2026-10-31, implemented for the API): nextGen is served under `/webui/next/` (already
  a static prefix); the v2 API answers on `/api/homematic.cgi/v2/...` (PATH_INFO, router change in
  `www/api/v2/router.tcl`, needs `v2_enabled true`). No change outside this repository.
- Route A (later, optional): add `next/` to the allowlist and a rewrite for `/api/v2/*` in the packaging
  repository's `webui.conf` for clean URLs; coordinate with its pin and patch set.
- The nextGen build output must stay in its own subfolder and never touch the classic `webui.js`.

## D6. Shell and navigation (2026-10-31)

Analysis of the classic header (browser, `header.htm`, `mainmenu.js`, `admin.js`, `user.js`): it mixes identity
("Admin (Administrator) | Mode: simple", click opens the account popup), a breadcrumb, alarm and service counters
(live, not for guests), Logout, "Save changes", a hidden diagnostics panel (duty cycle, interfaces, restart ReGa)
and a two-level menu of landing pages. The menu is data (`admin.js` 45 lines, `user.js` 26 lines); guests have none.

Decided by the user: **object-centric navigation** (not the Status/Settings split, six nouns appear twice there);
**no global "Save changes"** (dialogs that save have their own buttons); Teach-in and Help need no prominent place.
Built: app bar with user menu, sidebar and drawer, nav config with a drift test against the real menu files, and the
user level from `GET /profile` (`level`, added in the API branch).

Facts found on the way:
- "Save changes" and the logo both call `saveObjectModel()`, which calls `system.saveObjectModel` (flushes the ReGa
  object model to disk). When editing is built, check whether an edit needs it to persist (the classic dialogs
  may rely on ReGa saving itself); until then the new UI only reads.
- There is no API to change the expert mode (`User.isNoExpert` only reads); the new UI shows it only.
- v2 limits logins to 10 per minute and IP, always on.
- The hidden diagnostics panel of the classic header (duty cycle, interfaces, restart ReGa, API tools) is not
  carried over; the duty cycle became its own page, see below.

### Alarm and service indicators (built)

The classic counters come from the ReGa script `UpdateUI` (system.fn), polled every 3 s, that returns JavaScript;
the JSON API had nothing for them. The v2 model got two sections, `alarms` and `services` (API branch). Rules taken
from UpdateUI: alarms = alarm system variables with AlState oncoming and State true; service messages = oncoming
alarm objects of ID_SERVICES, the sticky-unreach ones left out of the count when `CCU.getStickyUnreachState` says
so; LED green at 0, red (alarms) or yellow (services) above 0; not shown to guests. Verified on a real ReGa: the
new count equals the classic header's. Lesson: HomeMatic script does not short-circuit a chain of `&&`, nest the ifs.
Not verified: service messages with real data (the test CCU has none); acknowledging (`ReceiptAlarm`) is not built.

### Overview and duty cycle (built)

The Overview is the classic start page: system information, the duty cycle and favourites (a pointer to the classic
UI). The classic UI shows the duty cycle there, not in the header; the hidden header panel is a test tool and is not
carried over. The method `Interface.getDutyCycle`, the data file `/tmp/dutycycle.json` (written by OpenCCU's
`updateDCVars.tcl`) and the classic bars are **OpenCCU additions (rootfs patch 0057)**, not Base: the card uses them
where they exist and says "not available on this system" where the method is unknown. Thresholds as the classic start
page (duty cycle 70 / 90 %, carrier sense 11 / 20 %). The system values needed a new route, `GET /api/v2/system`
(time, sunrise, sunset from one ReGa script; the version from `/VERSION`, since `CCU.getVersion` is admin only).
Checked against the live classic start page of the test CCU: date, sunrise, sunset, firmware and time agree.
OpenCCU's start page differs from the Base template (date and time share one field, sunrise and sunset another, and
it has extra rows for available device firmware and add-ons). Not carried over: the user's own start-page system
variables (an extra API section that could not be verified here), the firmware and add-on availability rows (they need
an internet check) and the favourites. The duty cycle was tested with mocks, through the real API path with a
hand-written data file, and the real empty answer; not with a real radio interface (the test CCU has none).

## D7. The new UI writes (2026-10-31)

Decided by the user: the new UI is to replace the classic one later, so **writing is a must**. Data is mostly stored by an
OK button or similar in a dialog, not by a global save. First slice: system variables, status and control.

- Every write is a v2 mutation route with fixed server-side scripts, validation by type, the id restricted to the
  object kind, the level check (USER or ADMIN; a non-admin also needs the object's full access right) and one syslog
  line per change. These routes were planned and blocked for lack of a live ReGa (EG-6); the test CCU unblocks them.
- First route: `POST /api/v2/sysvars {id, value}` (see `www/api/v2/sysvars.tcl`). Alarm, internal and hidden variables
  are not changeable. The model's sysvars got `description` and `lastModified`.
- The classic UI writes a variable through a ReGa page script (`saveSysVar`); the JSON API has no setter for a string and
  `SysVar.setEnum` redefines the value list instead of choosing a value, so the v1 methods are not used.
- hmscript injects a variable as `var name = "<escaped>";` (backslash, quotes, line breaks escaped): the value is data
  in a string literal, which is only safe while that escaping holds. A test checks that an injected string stays one
  well-formed literal.
- A write is verified by reading the value back (the route answers with the value and time as ReGa has them) and, in
  the tests, through an independent path (the v1 API and the classic list).
- Second route: `POST /api/v2/programs {id, execute: true}` (the planned IC010 route, for running; activating is the
  editor's and not built). Same pattern: the id only from the program collection, internal 403, a copy 404, a non-admin
  needs the full access right, one syslog line; the v1 `Program.execute` runs `ProgramExecute()` on any id unchecked. The
  model's programs got `description`, `isOperable` (the classic list's rule) and `isCopy`. The test CCU has no program,
  so a bare one is created by a ReGa script for the tests (and deleted): it can be run and its last run moves; what a
  real program does is not tested.
- ReGa appends a number to a name it has used before ("ZZtestprog 1"), also after a delete: tests use the name that
  creation returns.
- Third and fourth: `GET /api/v2/log?limit&offset` and `DELETE /api/v2/log` (the system log: the history archive,
  `dom.GetHistoryData`; the classic page also pages it by 20 and merges the records of one group). The user said clearing
  is part of it: a destructive write, so the page asks first (Cancel has the focus), the route is USER and up as in the
  classic UI, clearing is one syslog line, the answer says whether the log is empty afterwards. Export is the classic
  link `/HistoryBuffer.csv?sid=@...@` served by ReGa itself. Values of channel datapoints are raw (a limit, see the
  README); the test CCU has no device, so real channel entries are untested. The OpenCCU script that keeps the DutyCycle
  variable current adds entries of its own while that variable is logged, so tests compare "at least" what they caused.
- Fifth: `GET|POST /api/v2/values` (devices: live values and operation; slice 1 of Devices, Rooms and Functions). The
  restored copy of a real CCU (isolated, no radio) was used for the real ReGa: it gave the datapoint metadata (type,
  subtype, unit, min, max, list, operation flags), so the route and the controls are generic, driven by that and not
  by device type. A write goes through ReGa's `State` (the classic way). Found there: `State` returns `false` and ReGa
  only logs the failed XML-RPC setValue when the interface refuses, so the route answers HTTP 502 for an explicit
  `false` (a command that cannot be delivered must not look like success); the `true` of a working interface is
  unproven (no interface worked). The UI says "sent", not "done". Datapoint values on the copy are defaults (a backup
  holds no values), so live values are only seen on a real, connected CCU.
- Sixth: `GET /api/v2/favourites` and `GET /values?channels=` (Favourites). The structure was read from the restored
  copy: a user's lists are the children of the object named `_USER<id>` below ID_FAVORITES (the same id the session
  holds), a list's members are its children (CHANNEL, VARDP, PROGRAM, OBJECT = separator). The copy's test user had no
  lists, so three real lists were assigned to it on the copy (as the classic UI does) for the real-data check. The
  classic viewer (loadFavViewer) is not in the repository, so the generic datapoint controls are used with a short
  "usual parameters" list, not the classic per-channel-type widgets. Programs on a list are not run (Programs page).
- Seventh: the Favourites page became TILES (decided after a static mockup built from the real lists, `~/dev/ccu-mockups/`,
  not in the repository because it holds real names): one tile per channel chosen by channel type, the channels of one
  device sharing a tile (an HmIP socket is a read-only SWITCH_TRANSMITTER, an operable SWITCH_VIRTUAL_RECEIVER and a meter),
  week profiles hidden, a generic table as the fallback. The user wanted no confirm step for a click (as in the classic
  UI): taps on the target temperature are debounced (1.2 s) into one command. Reading the real datapoints of each channel type
  found a bug in the values route that only a socket channel showed (a channel's DPs() can hold a program: the read stopped
  half way through a record and answered HTTP 500, also on the Devices page): fixed, with a test. The maintenance
  channel's UNREACH / LOWBAT are added for the health badges.
- Eighth: Rooms and Functions are the Favourites page with another source of groups (`Collection`, `TileBoard`), so
  the tiles, the command states and the tests are shared. What real rooms hold (survey of the restored copy: 45 window
  contacts, 30 thermostats, switches, weather, wall keys, HmIP shutter feedback channels, 50 virtual keys in the function
  "Zentrale") decided the extra tile kinds (window contact, button, light, motion) and what is hidden (helper channels with
  no datapoint or events only). The old Rooms table (name, description, channel count) is gone: the room's description is
  shown under the buttons. The test copy's channels have no values, so only the structure is seen on real data.
- Ninth: the Devices page's expander shows the device's channels as tiles (TileBoard, the same as Rooms), the old channel
  table and datapoint table moved under "Technical details" (closed by default, loaded when opened). A language change builds
  the page again, so the section closes. Found while updating the tests: the focus returns to the Change button on the next
  tick, not within the key press (the old test was racy).
- Tenth: confirming alarm and service messages (`POST /api/v2/messages`, `canAcknowledge` in the model). The rule was read
  from the classic `functions.fn::ReceiptAlarm` on the running CCU (the repository's copy of that file does not define
  it): `AlReceipt()` if the message has no trigger datapoint or its trigger datapoint is writable. Only an alarm that
  is triggered now can be confirmed (404 otherwise, also for any other id), a user needs the full access right of an
  alarm variable, a refusal happens before anything is written. Real ReGa: five container watchdog alarms, one confirmed
  (5 to 4, syslog line written); the watchdog raises "no internet" again at once, so a message can come back.
- Eleventh: program activation (`POST /api/v2/programs {id, active}`), administrators only. Offered as a small status-and-control
  item, but reading the classic UI showed that the status page only DISPLAYS the Active flag; switching is done in the
  Programs-and-connections editor (administrator level), so it is an admin setting and not a status-and-control one. The
  real CCU showed the consequence: activating a program makes ReGa check its conditions and the program can run at once
  (activating "Abwesenheit" ran it and four dependent programs; deactivating ran nothing), so the page asks before it
  activates (a confirm dialog with a plain warning; deactivation is immediate). A route with no such warning in its
  documentation would invite a one-click switch, so the route's header says it too.
- Twelfth: device health badges directly in the Devices list (`HealthBadges`, `healthChannelIds`). `GET /api/v2/values?channels=` already includes `UNREACH`, `LOWBAT` and `LOW_BAT` from channel `:0` for the device of every requested channel, so passing the first channel of each device (polled every 10 s in chunks of 100; 2 requests / 0.38 s for the 160 devices of the restored copy) shows *Unreachable* and *Battery low* next to the device name in the collapsed list row, sharing `HealthBadges` with `TileShell`.
- Thirteenth: editing favourite lists (`POST /api/v2/favourites` and `DELETE /api/v2/favourites?id=`, `FavouriteListDialog`). Instead of the classic stateful `EnumCopyTo()` session copy objects, the v2 route applies the full list (name, description, ordered `CHANNEL`, `SYSVAR`, `PROGRAM` and `SEPARATOR` items) on OK in one fixed script after validating every member against its ReGa collection (`root.Devices()`, `ID_SYSTEM_VARIABLES`, `ID_PROGRAMS`). Old `OT_OBJECT` separator children are deleted via `dom.DeleteObject()` on update and delete so they do not leak in ReGa. Non-admin users cannot edit or delete lists shared with another user (`_USER<other>`, HTTP 403), matching `favOverview.htm`. New lists are added to `ID_FAVORITES`, `202` (`PC`) and `_USER<uid>`. Verified with Tcl contract tests, mocked UI flows and a live ReGa create/update/delete round-trip on the test CCU.
- Fourteenth: managing programs (`POST {create}`, `POST {id, copy, name}`, `PUT`, `DELETE ?id=` on `/api/v2/programs`, `ProgramDialog`), administrators only, scope "manage + metadata": create an empty program, rename, description, `Visible`, users-may-operate (`UserAccessRights(iulOtherThanAdmin)`), copy, delete. The conditions and actions are NOT editable (decided with the user); they stay in the classic editor. Instead of the classic session-bound `ProgramCopyTo()` working copy and `RestoreProgram`, each change is applied in one fixed script on OK. A name is checked against ALL ReGa objects with `dom.GetObject(name)` (the program itself excepted), not only programs, so a program can never take the name of a device or a variable; `dom.CheckName` was not used because its behaviour for a new object is undocumented. A copy is `ProgramCopyTo()` + `ProgramCopyID(ID_ERROR)` + `ProgramUpdate()` as the classic "save as new" does, but left inactive (a copy of an active program that is switched on can run at once, see the eleventh). Internal programs and `Unerasable()` ones are refused. Verified with 12 Tcl contract tests, mocked UI flows and a live round-trip on the restored copy (create with umlauts and braces in the text, partial change, rename conflict 409, copy, delete, internal program refused 403).
- Fifteenth: reading the logic of a program (`GET /api/v2/programs?id=`, `ProgramLogicDialog`, `program-logic.ts`), stage 1 of the program editor (administrators). The decoding of ReGa's integer codes comes from the classic code (`rule.inc`, `sico.inc`, `side.inc`) and from probing the 54 real programs of the restored copy: left value 18 device datapoint / 19 system variable / 24 time control; test 1 = (logic or list value), 5 =, 6/7 range, 8 >, 9 >=, 10 <, 11 <=, 12 !=, 3 time; second type 4 on change / 13 on update / 15 check only; destination 18 device datapoint / 19 system variable / 20 script; delay type 28. Of 79 actions 74 are SCRIPTS, so a "simple programs" editor has to treat a script as a first-class action (a text area), not as the exception. Three details that were learned on the real ReGa: assigning `RightVal1()` / `DestinationValue()` straight to a `string` variable makes the whole loop body vanish silently (use `"" # value`); a delay comes back as a date-time and the classic editor reads hours, minutes and seconds from fixed places of that string; the end of a time span has to be computed from the local `time` string, `TimeSeconds()` is UTC. Free text (names, scripts) is escaped by the ReGa script (`\\ \o \c \n`) because a script holds braces and line breaks that would break a Tcl list. The per-row buttons became one **Manage** menu: four buttons per row overflowed the card.
- Sixteenth: editing the actions of a program (`PUT /api/v2/programs {id, rule, actions[], stopDelays}`, `GET ?targets=1`, `ProgramActionsDialog`, `program-actions.ts`), stage 2 of the program editor (administrators). The whole list of one rule is replaced, not patched: the server validates every target and value first, then follows the classic editor's own pattern (`ProgramCopyTo()` working copy, edit the copy, `ProgramCopyTo(original)` back, delete the copy, `ProgramUpdate()`, restore the active flag), so a failure at any step deletes the copy and leaves the original untouched; the abort and the commit only ever delete an object that is a COPY (`ProgramCopyID() != ID_ERROR`) and not the program itself. Scripts are first-class actions (74 of the 79 real ones) and go through the same path as a variable (`DestinationValue(text)`), never as part of the ReGa code. Targets: writable `HSSDP` datapoints of non-internal channels and visible, non-internal, NON-ALARM system variables; scaling types (5, 6) are numbers and a `100%` unit is typed as 0..100 and divided by 100 on the server. Learned on the real ReGa: `!` has LOW precedence (`!a.Internal() && b` is `!(a.Internal() && b)`, which let internal alarm variables in): use nested `if`s; a delay is written as the string `HH:MM:SS` in `DestinationValueParam`; the working copy carries the original's name, so uniqueness is not enforced on it. Saving an ACTIVE program re-activates it (`Active(wasActive)`) and ReGa checks its conditions again, so the editor warns first (same reasoning as the eleventh). Tested with 14 more Tcl tests, a mocked browser test, and live on the restored copy (4 action kinds, delays, percent, enum, every refusal, no stray copies).
- Seventeenth: editing the conditions of a program (`PUT /api/v2/programs {id, rule, conditions}`, `GET ?targets=conditions`, `ProgramConditionsDialog`, `program-conditions.ts`), stage 3 of the program editor (administrators). Unlike the actions, the conditions CANNOT be replaced wholesale: a time condition points at a per-program `CALENDARDP` timer, and ReGa EMPTIES that timer when the condition is deleted (the object stays, its type and times are gone), so a rebuilt time condition would be an empty timer. The write is therefore an in-place edit by POSITION: every kept condition and group names its position in the program as `GET` gives it (`from`), what is not named is deleted (groups from the end, then the conditions of the kept groups from the end), kept non-time conditions are updated field by field, new conditions and new groups are appended (ReGa has no insert or move), and the server refuses a kept group that is out of order, a condition taken from another group, a new or retyped time condition (a time one may only be kept and change its trigger 13 / 15). The structure the copy ends up with is counted against the request before it is put back. The classic model, read from `rule.inc` / `programs.fn` / `sico.fn`, has ONE joiner between the groups (`CndOperatorType` of every group) and one inside a group (`OperatorType` of its conditions), copied on every add, so that is what the API and the UI expose, not a joiner per condition. Comparison codes: 1 is (logic, list, button), 5 =, 6 between, 8 >, 9 >=, 10 <, 11 <=, 12 !=; the value type of the right-hand side is set by ReGa itself from the value. A condition is not range-checked against its datapoint (a comparison may lie outside it). The test also found a real bug: the "delete this time control?" confirmation opened BEHIND the editor (lower z-index); `ConfirmDialog` got a `raised` flag. And one more ReGa rule: a script that names a variable that is not defined, even in a branch that never runs, silently does nothing at all, so every call of the shared operation script defines every variable (`programs_condOp`). Verified live on the restored copy (device, list, logic, sysvar and time conditions, groups, operators, every refusal, no stray copies; the time condition survived with its timer).
- Next for "Status und Bedienung": Diagrams, a "real device" test on a CCU with a radio (not available, so mocks plus the copy).
