# OpenCCU nextGen WebUI

React 19, TypeScript, Vite and Tailwind, with shadcn/ui-style components (Radix primitives) that live in
`src/components/ui` and are maintained here. It runs **next to** the classic UI, which stays untouched.
Decisions: `.migration/plan/decisions-ui.md` (D1 to D5).

Status: login, an app shell (app bar, sidebar or drawer, user menu, alarm and service indicators) and read-only
pages: Overview (the landing page), Devices (filter, channels per device), Rooms, Programs (status **and control**), System variables
(status **and control**), the System log (read, export and **clear**) and the two message lists. It signs in with `Session.login` on the v2 API, keeps the session
id in `sessionStorage`, and links to the classic UI with the same session, so both can be used at once. The pages
read the v2 bulk model (`GET /model`); routes are hash based (`#/devices`, `#/rooms`, `#/sysvars`), so no server
route is needed and a reload keeps the page. An expired session returns to the form.

## Shell and navigation

The classic header mixes identity, a breadcrumb, alarm and service counters, logout, a save button and a two-level
menu. Here each has its own place: the slim app bar holds the name and the **user menu** (name, level, simple or
expert mode as information, language, the classic UI, sign out); the **navigation** is a sidebar on wide screens and
a drawer on narrow ones; a page has a title instead of a breadcrumb. There is no global "Save changes" button: dialogs that save have their own buttons.

**Logical Default Order & Custom Navigation:**
The navigation follows a logical, smart-home daily-use hierarchy:
1. Overview (Dashboard)
2. Favourites (Starred controls)
3. Rooms (Location-based navigation)
4. Devices (Hardware management)
5. Heating Groups (Room climate zones)
6. Functions (Trade categories)
7. Programs (Automations)
8. System Variables (States and logic)
9. System Log (Event history)

Users can customize this ordering individually via the **"Customize menu"** button in the sidebar footer, the mobile drawer, or the user profile menu. The `NavCustomizeDialog` enables reordering items (Up / Down) and hiding unneeded items, persisted in `localStorage` (`openccu.next.nav.custom`) with an instant **"Reset to default"** option.

## Alarm and service messages

The app bar shows the two counters of the classic header, each a link to its list (`#/alarms`, `#/services`): a
green dot at 0, red (alarms) or amber (service messages) above 0, shown to users and admins, not to guests. The
data is the `alarms` and `services` sections of `GET /model` (one request, every 10 seconds, paused while the tab
is hidden, last known numbers kept if an update fails; the classic UI asks every 3 seconds). The alarm count is
the alarm system variables that are oncoming and true; the service count is the open service messages, minus the
sticky-unreach ones while the CCU hides them (`CCU.getStickyUnreachState`; a user who may not ask is treated as
"hide", as the classic UI does). Message texts that contain `${key}` references are resolved from the classic
language files.

**Confirming messages.** The Alarm messages and Service messages pages have a **Confirm** button per message and **Confirm
all** (for a user or administrator). The rule is the classic `ReceiptAlarm`: a message can be confirmed if it has no trigger
datapoint or its trigger datapoint can be written; a message that the device reports by itself (a read-only trigger, e.g. an
"unreachable" report) has no button, the page says why instead (`canAcknowledge` in the model). A click calls
`POST /api/v2/messages {"id"}`, and the lists and the header counters are read again at once. A message that the device
raises again (the watchdog alarm "no internet" on a container without internet) comes back in the list: that is the answer
`acknowledged: false` or the next update, not an error. Confirm all tries every message that can be confirmed, and says
"N of M confirmed" if some could not be (a refusal, or a message somebody else confirmed meanwhile).

## Object-Centric Device View & Management

Instead of scattering device controls, configuration parameters, direct links, and diagnostics across four disconnected menus in the classic WebUI ("Status und Bedienung", "Einstellungen -> Geräte", "Einstellungen -> Direktverknüpfungen", "Status -> Funk-Telegramme"), the NextGen WebUI unites them under **one object-centric device view**:

1. **Status & Control (`DeviceDetail.tsx`)**:
   - Channel tiles with real-time feedback (heating, dimmers, shutters, switches, contacts).
   - Technical channel table with raw datapoints and on-the-fly value writing.
2. **Parameters & Configuration (`DeviceConfig.tsx`)**:
   - Reads device and channel MASTER paramsets via `GET /api/v2/links?device=ID`.
   - Categorized parameter editing with client-side range/enum validation and pending state tracking.
   - Saves modified parameters via `POST /api/v2/links/paramset`.
3. **Direct Links (`DeviceDirectLinks.tsx`)**:
   - Lists all inbound and outbound direct peerings for the device channels via `GET /api/v2/links?device=ID`.
   - Shows partner device and channel names, link description, and configuration profile.
   - Interactive creation of new direct links via `DirectLinkDialog` (`POST /api/v2/links`) with automatic link pairing.
   - Link deletion with confirmation prompt (`DELETE /api/v2/links`).
4. **Maintenance & Diagnostics (`DeviceMaintenance.tsx`)**:
   - RF Signal quality metrics: Inbound and outbound RSSI dBm values with signal health ratings (Excellent, Good, Fair, Poor).
   - Communication status: Sticky unreach, active unreach, config pending, low battery.
   - Firmware management: Current firmware version and update availability.

## Heating Groups (Heizungsgruppen)

Heating groups (`pages/HeatingGroups.tsx`, `components/HeatingGroupDialog.tsx`) allow group-wide coordination of wall thermostats, radiator valves, and window sensors:

- **Overview (`#/heating-groups`)**: Lists all virtual heating groups (`HEATING_CLIMATECONTROL_TRANSCEIVER`, `CLIMATECONTROL_RT_TRANSCEIVER`), their assigned room, member count, and live control status (target temp, current temp, humidity, control mode).
- **Group Detail**: Opens the group's dedicated view showing member devices categorized by role (Wall Thermostat, Radiator Thermostat, Window Sensor).
- **Manage Members**: Seamlessly add or remove devices to/from the virtual group via `POST /api/v2/heating` (`action: "add_member" | "remove_member"`), coordinating direct peerings across all group channels automatically.
- **Group Creation & Deletion**: Create new heating groups with room assignment or delete existing virtual groups with proper cleanup.

## Devices: live values and operation

Each row in the Devices list shows the device's **health badges** (*Unreachable*, *Battery low*) next to its name without
having to open the device: the page reads the maintenance health of all listed devices through `GET /api/v2/values?channels=`
(one channel per device, every 10 seconds). Opening a device in the Devices page (the arrow before its name) shows its channels as **tiles**, the same tiles as in
Rooms and Favourites (heating, shutter, switch, window contact, ... see below), with their live values, the controls and the
health of the device; channels that carry nothing (helper channels, week profiles) are counted, not shown. Because the
channels of one device often have the same name, a tile in a device keeps the channel's full name (":2").

**Technical details** (a closed section below the tiles) holds what the page showed before the tiles existed: the channel
table (number, name, channel type) and, below it, the **values** of every datapoint of every channel with the parameter name,
the value (number with unit and decimals, list entry, yes or no) and, for a user or administrator, the control. This is the
complete, technical view and the place for anything a tile does not offer. The list is read again every 10 seconds while the
section is open and the tab visible, and with **Refresh**. A device that never reported a value (the CCU holds the epoch as
the time and a default value) shows a dash, not a made-up 0.

- yes/no datapoints get two buttons, a button datapoint (a key press, a mode switch) gets **Send**, and a number,
  list or text datapoint gets **Change**, which opens a field with its range and an **OK** button (Escape cancels, the
  focus returns to Change). The server checks type and range again.
- The answer to a command says **"command sent. The value changes when the device reports back."**, never "done": a
  device acknowledges later, and the value shown is what the CCU holds. The values are read again after 3 seconds.
- If the CCU's interface does not take the command (the interface daemon is down or refuses), the page says so and
  keeps the field open for a retry (HTTP 502). The classic UI would show nothing.
- A guest has no pages in the new UI at all (as before); the administrator and user levels operate.

The data is the new `GET /api/v2/values?device=ID` (the datapoints of ONE device, with type, value, unit, limits, list,
time and the write flag) and `POST /api/v2/values {"id","value"}` (one datapoint, set with ReGa's `State` as the classic
UI does, only a datapoint of a channel of a device, never any other object; a user who is not an administrator needs the
channel's full access right). A failed send is detected from the `false` that `State` returns (seen on the restored
copy where the interfaces were down); that it returns `true` when it works is **not proven here**: no interface worked
on any test system, so only an explicit `false` is an error.

**Simplified / not yet:** parameters are shown with their technical names (the classic page translates them with the
string tables and shows only the useful ones), and yes/no is used for every logic value (not "on"/"off", "open"/"closed").
Rooms and Functions with live values are the next slice. Internal datapoints and channels are left out, as in the classic UI.

## Favourites, Rooms and Functions: groups of channels, as tiles

Favourites, Rooms and Functions are **one page** (`pages/Collection.tsx`, `components/TileBoard.tsx`): a set of named groups
of channels, picked as buttons, whose members are shown as tiles. Only where the groups come from differs: the user's
favourite lists, `GET /api/v2/model?sections=rooms`, `GET /api/v2/model?sections=functions` (a room or function holds
channels only, sorted by name so that the channels of one device sit together; no variables, no programs, no separators).
The text below says "list" where it applies to all three.

The classic "Favorites" (Status and control): a user's own lists of channels, system variables and programs (and
separators). Every user, an administrator too, sees only the lists assigned to them (the lists under their `_USER<id>`
object in ReGa, without the editing copies), as in the classic page. The lists are buttons; the members of the open list
are **tiles** in list order, a responsive grid (one column on a phone). Each tile is chosen by the channel type
(`lib/widgets.ts`):

| Tile | Channel types | Shows / operates |
|---|---|---|
| Heating | `CLIMATECONTROL_RT_TRANSCEIVER` (HM, also the heating groups), `HEATING_CLIMATECONTROL_TRANSCEIVER` (HmIP), `THERMALCONTROL_TRANSMIT` (a wall thermostat), `CLIMATECONTROL_*_RECEIVER` | target temperature (- / + in steps of 0.5), actual temperature and humidity, mode chips Auto / Manual / Boost, valve opening |
| Shutter | `SHUTTER_VIRTUAL_RECEIVER`, `BLIND_VIRTUAL_RECEIVER` (+ the `*_TRANSMITTER` feedback channel of the same device) | percent open (0 closed, 1 open, 1.01 = unknown shown as open; the position comes from the feedback channel, the commands go to the control channel), Open / Stop / Close |
| Switch | `SWITCH`, `SWITCH_TRANSMITTER`, `SWITCH_VIRTUAL_RECEIVER` (+ `POWERMETER`, `ENERGIE_METER_TRANSMITTER` of the same device) | the channels of one device share ONE tile: the state comes from the feedback channel, the control from the channel whose state can be written (HmIP: the virtual receiver), the power from the meter; a meter alone is a read-only power tile |
| Weather / motion | `WEATHER`, `WEATHER_TRANSMIT`, `MOTION_DETECTOR`, `COND_SWITCH_TRANSMITTER_TEMPERATURE` | temperature, humidity, brightness, motion; read only (a probe that is not connected reports -3276.8, shown as no value) |
| Window / door | `SHUTTER_CONTACT` | open or closed (read only) |
| Light | `DIMMER`, `DIMMER_*`, `VIR-LG-*-DIM-CH` (Hue) | level in percent, a slider (one command 1.2 s after it rests), Off / On; a dimmer with a feedback channel is one tile |
| Button | `KEY`, `VIRTUAL_KEY` | Short press / Long press (sent, nothing to confirm) |
| Variable | a system variable on the list | a logic variable is a switch, others show the value and open the System variables dialog |
| Other | any other channel type, and programs | the channel's values as a table behind "Show values" (as in Devices); a program is only named |

`BLIND_WEEK_PROFILE`, maintenance channels, `KEY_TRANSCEIVER` (the events of a wall key: nothing to press), the thermostats'
`WINDOW_SWITCH_RECEIVER` / `REMOTECONTROL_RECEIVER` and `STATE_RESET_RECEIVER` (no datapoint), and the switch feedback
channel of a heating actuator (the heating tile says it) are not shown; the page says how many were left out and which.
Two tiles whose titles would be the same ("Schalter Kaffeemaschine" twice) keep their full channel names.

**A command is "sent", never "done".** A tile says *Sending... waiting for the device* until the CCU holds the value that
was sent (it reads again every 3 s meanwhile), then *confirmed*; after 30 s it says *No confirmation from the device* and
offers *Try again*; if the CCU's interface refuses (HTTP 502) the tile says so. A button of a device (Boost on a
virtual group, Stop) is only *sent*. Taps on the target temperature are collected: **one** command goes out 1.2 s after
the last tap (like the classic UI there is no confirm step). The tile shows the pending target with a dashed line until
the CCU holds it.

**Health:** an unreachable device and a low battery are marked on the tile (and an unreachable one cannot be operated).
They come from the device's maintenance channel, which `GET /api/v2/values?channels=` adds (UNREACH, LOWBAT, LOW_BAT only).

The data is `GET /api/v2/favourites` (the lists and their members), `GET /api/v2/model?sections=devices` (which type each
channel is and which device it belongs to) and `GET /api/v2/values?channels=1,2,3` (the datapoints of up to 100 channels
in one request; in chunks if a list is longer). Lists are read every 60 s, values every 10 s.

**Editing favourite lists.** A user or administrator gets **New list**, **Edit list** and **Delete list** on the Favourites
page (also when they have no lists yet). New list and Edit list open `FavouriteListDialog` (name, description, the ordered
members with up / down / remove buttons and **Add separator**, and a searchable picker to add channels, system variables or
programs). Saving calls `POST /api/v2/favourites {"id"?,"name","info"?,"items":[{"type","id"?}]}`; the server checks every
channel, variable and program against its ReGa collection before writing, deletes old `OT_OBJECT` separators so they do not
leak, refuses edits to lists shared with another user when the caller is not an administrator (HTTP 403, as in the classic
`favOverview.htm`), and logs one syslog line. Delete list asks first (`ConfirmDialog`, Cancel focused) and calls
`DELETE /api/v2/favourites?id=ID`.

**Not yet / unproven:** the heating modes are taken from the classic control code for the HM groups (`CONTROL_MODE` 0 auto,
1 manual, 2 party, 3 boost; the `AUTO_MODE`, `MANU_MODE`, `BOOST_MODE` datapoints). For HmIP heating the Auto / Manual
chips write `SET_POINT_MODE` 0 and 1 and Boost writes `BOOST_MODE`; that is what the datapoints allow (they are writable)
but **it could not be tried on a real HmIP thermostat** (the classic JS that does it is not in the repository). Nothing
was seen to succeed on real hardware at all: no interface works on any test system. Party mode, comfort / lowering
temperature, the week schedule, heating/cooling and the window-open state are not offered.
No dark mode yet (the colour tokens are in `index.css`). Rooms and functions that hold hundreds of channels are not paged (the largest on the test copy, 52 channels, is one request of 0.3 s and 270 KB); the server reads at most 100 channels per request and the page asks in chunks.

## System log: read, export and clear

The classic "System log" is the history of the logged channels and system variables (a variable or channel is logged when
its archive flag is on): which one changed to which value, and when. The page lists the newest entries first (200 records
per request, **Show older entries** for more), with a filter over time, name and value, and **Refresh** as in the classic
page (the list does not update by itself). The records of one event are one row, as in the classic list. **Export** is a
link to `/HistoryBuffer.csv?sid=@...@`, which ReGa serves itself, as for the classic UI. **Delete all entries** erases the
whole log and cannot be undone: it asks first (Cancel has the focus, Escape cancels), says in the dialog if it fails, and
tells afterwards that the log was cleared. A user or administrator may clear, as in the classic UI.

The data is the new `GET /api/v2/log?limit&offset` and `DELETE /api/v2/log`. Limit and offset count records from the
newest; `total` is the number of records in the log. Values are written like the status of a system variable (value
names, list entries, two decimals with the unit). **Simplified:** for the datapoints of channels the log gives the raw
value and the unit, while the classic page writes them with a page function that uses the WebUI's string tables (for
example "on" for a switch state), which a script cannot call; this could not be checked here, since the test CCU has no
device. Entries that appear while older ones are being loaded can shift the pages: Refresh starts again from the newest.

## Programs: status and control

The classic status list of the programs and its action: name, description, last run and a **Run** button, with a name
filter, refreshed every 10 seconds. It lists what the classic page lists: programs that users may operate, not the copies
of the editor and not the system's own; an inactive program can be run by hand, as in the classic UI. A click runs the
program through `POST /api/v2/programs {id, execute: true}` and shows the result in a status line that a screen reader
announces ("... was started", or why not); the last run in the row is the time ReGa reports. A user or administrator may
run programs, a guest only looks. Not built: the classic "Activity" text (what a program does; it is produced by a ReGa
page function that a script cannot call), activating and deactivating a program, and editing (the classic "Programs and
connections" pages). The server runs only a program of the program collection, refuses an internal program (403), and a
non-admin needs the program's full access right; the v1 `Program.execute` checks none of this.

**Active.** The table has an **Active** column. Administrators get a switch (a user sees yes / no): in the classic UI the
status page only shows the flag, and switching a program on or off belongs to the *Programs and connections* editor, which
is administrator-level, so it is administrators only here too (`POST /api/v2/programs {"id","active":true|false}`; internal
programs are refused). **Activating asks first** ("Activate this program?"): the CCU checks the conditions of a program when
it is activated and the program can run at once (seen on the restored real CCU: activating "Abwesenheit" ran it and the four
programs that depend on it, while deactivating ran nothing), so a click on a switch must not be able to switch lamps by
accident. Deactivating needs no question. Cancel has the focus.

**Managing programs (administrators).** Administrators see all programs but the editor's copies and the system's own (also those
users may not operate) and get **New program**, and **Edit**, **Copy** and **Delete** per row (`POST|PUT|DELETE /api/v2/programs`).
*New* makes an empty program that is switched off; *Edit* changes name, description, "visible" and "users may operate it" (only
the changed fields are sent); *Copy* asks for a new name and makes an inactive copy; *Delete* asks first (Cancel has the focus). A
name must be 1 to 100 characters and not used by any other ReGa object (HTTP 409, told in the dialog). **Not built:** the
conditions and actions of a program; they stay in the classic *Programs and connections* editor (a program made here has none).

**Reading the logic (administrators).** Each row has a **Manage** menu with *Logic*, *Edit*, *Copy* and *Delete*. *Logic* opens a
read-only dialog that shows what a program does in words, read with `GET /api/v2/programs?id=`: the rules (*If*, *Else if*,
*Else*), the condition groups with their *and* / *or*, each single condition (a device datapoint, a system variable or a time
control, with the name of the value, the unit and when it triggers) and the actions (*Set X to Y*, *Run a script* with the script
on request, and the delay). It is the first stage of the program editor: it proves the decoding of ReGa's integer codes against
every program of the restored copy (54 of 54 read, 46 device, 19 system variable and 10 time conditions; the actions are 74
scripts, 23 device values, 1 system variable). Anything the formatter does not know says so and points to the classic interface.

**Editing the actions (administrators).** In the Logic dialog every part (*Then*, *Else*) has an **Edit actions** button. The editor
shows one row per action: a kind (*Device value*, *System variable*, *Script*), a target you pick from a filterable list of what can
be set, a value input that fits the target (a switch, a list, a number with its range and unit, a text, or just *Trigger* for a button),
an optional delay (seconds, minutes or hours), and a script as a text area. Rows can be moved up and down and removed; a new row starts
with a value that is valid. **OK** stays off until something changed and every row is valid, and a percentage is typed as 0 to 100
(ReGa keeps 0 to 1). Saving sends the WHOLE list for that part (`PUT /api/v2/programs {id, rule, actions, stopDelays}`); the server
validates every target and value first (HTTP 422 names the field, e.g. `actions[2].value`), writes the actions on a working copy of the
program and puts the copy back over the original in one step, as the classic editor does, so a failure leaves the program as it was.
The program list of targets comes from `GET /api/v2/programs?targets=1` (about 300 kB on a CCU with 160 devices, read when an editor
opens). **An active program is put back as it was: the CCU checks its conditions again and the program can run at once**, so the
editor says so first. An action the editor cannot show (a target that does not exist any more) makes the part read only here.
Not built yet: the conditions, creating the *Else* part of a program, the weekly programs.

## System variables: status and control

The first page that **writes**. The list is the classic one: name, description, last modified and status, with a name
filter, refreshed every 10 seconds. A user or administrator gets a **Change** button next to every logic, list, number
or string variable; it opens a dialog like the classic "Change system variable value": a choice between the value names
for a logic variable, the entries for a list, a number field with the variable's limits and unit, a text field (at most
1000 characters) for a string. OK stays disabled until the value is valid and different; a refusal of the server is shown
in the dialog, which stays open; Escape and Cancel send nothing; the focus goes back to the Change button. Alarm
variables, the system's own (internal) variables and hidden ones cannot be changed. A guest only looks.

It calls the new `POST /api/v2/sysvars {id, value}` (a boolean for a logic variable, else the text as typed, so a number is
not rounded by a float round trip). The server decides: it looks the id up among the system variables only, validates by
type and limits, needs the variable's full access right for a non-admin, and logs each change. The server's answer (value
and time as ReGa has them) updates the row at once. The classic UI changes a variable with a ReGa page script
(`saveSysVar`) and has no JSON method for a string or a list value (`SysVar.setEnum` redefines the value list), which is
why the route exists. Checked on the test CCU against the v1 API and the classic list.

## Overview

The landing page, as the classic start page is: a **System** card (the time of the CCU, date, sunrise, sunset, the
firmware version), the **duty cycle** card, and a **Favourites** card that points to the classic UI (favourites are
not built). A hint appears if the account has no password. The system values come from the new `GET /api/v2/system`
(any session; time, sunrise and sunset from one ReGa script, the version from `/VERSION`); a value that cannot be read
is shown as a dash. The time is asked again every minute and runs with the browser's clock in between.

The **duty cycle** card shows the load of each radio interface (CCU radio module, HmIP access points, LAN gateways): a
bar for the duty cycle and, where the interface reports it, one for carrier sense, each with the value and a word
(normal, warning, critical), so colour is not the only signal. The thresholds are those of the classic start page: duty
cycle warning from 70 % and critical from 90 %, carrier sense from 11 % and 20 %. An interface is named as there: "CCU",
"HAP (name)" or "LGW (name)", or by address if it has no name; -1 is shown as not available.

The duty cycle data is `Interface.getDutyCycle`, which reads `/tmp/dutycycle.json`, written by OpenCCU's
`updateDCVars.tcl`. **Both the method and the classic display are an OpenCCU addition (rootfs patch 0057), not part of
this repository's API**: on a system without the method the card says that the duty cycle is not available. It
refreshes every minute. The classic header's hidden test panel (duty cycle, interfaces, restart ReGa, API tools) is not
carried over. Not carried over from the classic start page either: the user's own start-page system variables, the
rows about available firmware (they need an internet check) and the favourites themselves.

The navigation is **object-centric**: one entry per object (devices, rooms, system variables, ...) where the classic
menu has a status page under "Status and control" and an editor under "Settings". `src/lib/nav.ts` maps every
classic menu entry to an entry here, with the user level it needs. The menu depends on the user level, which comes
from `GET /profile` (`level`: ADMIN, USER, GUEST). Guests and unknown levels get no navigation, as in the classic UI.
Entries that are not built yet stay in the config and are not shown; a link points to the classic UI for them.

`src/lib/nav.test.ts` reads the real `www/webui/js/mainmenu/{admin,user}.js`: every classic entry must be mapped or
deliberately dropped, nothing may be mapped that does not exist, and each entry needs the level the classic menu
gives it. It is the checklist of the migration; it fails when the classic menu changes.

Not changeable here: the expert mode. The CCU has no API for it (the classic UI uses its account dialog), so the
user menu shows it only.

## Languages

English and German. The browser language decides, a DE/EN switch in the header overrides it and is remembered
(`localStorage`). The texts of the app are in `src/lib/messages.ts`; the German catalog must have exactly the
English keys (the compiler checks it, and a test checks the placeholders).

Texts that belong to the CCU itself, namely the `${key}` value names of system variables and the descriptions of
device types, are read from the classic UI's language files (`/webui/js/lang/<lang>/translate.lang.*.js`,
`src/lib/ccu-strings.ts`), so both UIs show the same translations and nothing is translated twice. If a file
cannot be read the app falls back to plain text. A unit test parses the real files of this repository, so a
change of their format is noticed. Dialog texts that the files build by JavaScript concatenation are not
supported (and not needed here).

## Where it runs

- Served by lighttpd under **`/webui/next/`** (a static prefix of the CCU web root; no lighttpd change).
- Talks to **`/api/homematic.cgi/v2/rpc`**. That needs `v2_enabled true` in `/www/api/apiconfig.conf`
  (default `false`). When lighttpd routes `/api/v2` itself, set `VITE_API_BASE=/api/v2` at build time.
- The API client sends `X-Requested-With` and `X-Session-Id`, and shows a message that never contains
  server internals (`src/lib/api.ts`).

## Develop

```sh
npm ci
CCU_URL=http://127.0.0.1:18080 npm run dev    # proxies /api and /pages to a CCU (a test instance!)
npm test                                       # unit tests of the API client
npm run build                                  # type check + production build into dist/
```

## Build into the web root

```sh
cmake --preset x86_64-linux-gnu -DDEPLOY_TO_REPO=OFF -DOPENCCU_BUILD_NEXT_UI=ON
cmake --build --preset x86_64-linux-gnu --target webui-assets
```

`OPENCCU_BUILD_NEXT_UI` is **off by default** (it needs Node.js and npm): without it the web root is exactly
the classic one. `package-lock.json` is committed and `npm ci` installs without running install scripts.
Built output is never committed.

## End-to-end test

Both drive a real browser against a CCU that has the app installed and `v2_enabled true`
(`python3 -I <file> --base http://127.0.0.1:18080 --password ...`, in the Playwright container of `tests/e2e`):

- `src/webui/tests/e2e/next_login.py`: wrong password, login, reload, the same session in the classic UI, sign out.
- `src/webui/tests/e2e/next_pages.py`: rooms and system variables compared with the classic v1 API, tabs, reload,
  umlauts, internal variables hidden, an expired session returns to the form.
- `src/webui/tests/e2e/next_shell.py`: sidebar, user menu, drawer on a narrow screen, user levels (mocked `/profile`:
  user, guest, unknown level, failing and expired), at most two logins.
- `src/webui/tests/e2e/next_messages.py`: the indicators against the classic header (real), the alarm page against
  the indicator, and mocked service messages (the test CCU has none): sticky handling, German, live update, a failing
  update, an expired session, guest and user.
- `src/webui/tests/e2e/next_values.py`: the values and the operation of a device with the device list, `/values` and the
  answers to a command **mocked** (no device and no working interface on a test CCU, so a command can only be mocked);
  login and the page are real. Nothing on the CCU is changed.
- `src/webui/tests/e2e/next_rooms.py`: the Rooms and Functions pages with the device model, the rooms, the functions, the values and
  the answers to a command **mocked**: window contacts, a wall thermostat, a shutter with its feedback channel, a dimmer,
  a motion sensor, keys, a socket with its meter, hidden channels, the same-title rule, German, expired session.
- `src/webui/tests/e2e/next_favourites.py`: the Favourites tiles with `/favourites`, the device model, the channels' values,
  the system variables and the answers to a command **mocked** (the test CCU has no device and no list); the mocked device
  confirms a command a moment after it was sent, one command is never confirmed (the browser clock is fast-forwarded to see
  the 30 s rule); login and the page are real. `--shots DIR` takes screenshots.
- `src/webui/tests/e2e/next_realdata.py`: READ-ONLY pass over the restored data of a real CCU (`isolated-ccu.sh`).
- `src/webui/tests/e2e/next_log.py`: **real changes on the test CCU, it CLEARS THE LOG: run it on a test CCU only.** History is
  generated by logging two system variables and changing them, compared with the classic log page, the export is fetched,
  and the log is cleared through the page (cancel and Escape first); mocks cover paging of a log of 450 records, a failing
  clear, a log that is not empty afterwards, an expired session and German. It ends with an empty log and the archive flags
  off again.
- `src/webui/tests/e2e/next_programs.py`: **real runs on the test CCU, run it on a test CCU only.** A bare test program is
  created by a ReGa script and always deleted; it is compared with the classic list, run through the page and checked
  through the v1 API (its last run moves); mocks cover programs the classic list leaves out, the server's refusals, an
  expired session, German and the user level.
- `src/webui/tests/e2e/next_sysvars.py`: **real changes on the test CCU, run it on a test CCU only.** The list against
  the classic list; Anwesenheit flipped and put back (checked through the v1 API); a temporary number with limits and a
  temporary list created and always deleted; a string and the server's refusals (422, 403, 404, 500), an expired
  session, German and the user level with mocked answers; cancel, Escape, focus, filter and a change made elsewhere.
- `src/webui/tests/e2e/next_overview.py`: the real date, sunrise, sunset and firmware version against the classic start
  page (the time within a minute), a ticking clock (the browser clock is controlled), an unreadable time, a failing
  call (the other cards stay), the password hint, German and the narrow layout.
- `src/webui/tests/e2e/next_dutycycle.py` (`--data mock|real|empty`): the card with mocked answers (severity colours and
  words, -1, carrier sense, live update, unknown method, failure, German, narrow, expired session), through the real API
  path with a hand-written `/tmp/dutycycle.json` in OpenCCU's format (`real`), and the real empty answer (`empty`). The
  test CCU has no radio hardware.
- `src/webui/tests/e2e/next_i18n_devices.py`: German by browser language, the language switch, `${key}` value names
  resolved from the classic strings, and the Devices page. The test CCU has no devices, so the real answer is the
  empty state; the rest uses a mocked model answer with realistic devices (shape of `v2/model.tcl`).

- `src/webui/tests/e2e/test_device_config.py`: tests the object-centric device tabs (Status/Control, Parameters, Direct Links, Maintenance/RSSI diagnostics).
- `src/webui/tests/e2e/test_heating_groups.py`: tests virtual heating groups overview, group creation, member assignment, and detail view.
- `src/webui/tests/e2e/capture_screenshots.py`: automated Playwright script capturing all 9 high-DPI screenshots of the NextGen WebUI into `docs/screenshots/`.

## Standalone CCU Addon Packaging

The NextGen WebUI can be packaged and distributed as an independent CCU Add-on (`.tar.gz` archive):

```sh
# Run from repository root
./scripts/package_addon.sh v0.1.0-beta.2
```

This builds the production Vite bundle, packages the add-on update scripts (`update_script`), install hooks, CCU control panel registration (`/etc/config/addons/www/nextgen`), and Lighttpd routing configurations into `dist-addon/openccu-nextgen-addon-<version>.tar.gz`.

## Login limit

The v2 API limits logins to 10 per minute and IP (and requests per session), always on. A test or script that signs
in more often gets "Too many attempts". The classic API (v1) is not limited unless `rate_limit` is set.

## Licences

Only OSI-approved open-source dependencies. The 50 shipped packages are MIT (48), Apache-2.0 (1) and 0BSD (1);
re-check with every dependency change.
