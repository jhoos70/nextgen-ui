# Trying the webui-api changes on a test CCU

**Test systems only.** The code has been tested against mocks (1,247 tests), never on a real
ReGaHss, `rfd`, `hs485d` or lighttpd. Do not install this on a CCU you rely on.

What you get: `out/webui-api-bundle.tar.gz` (the 106 files that differ from upstream; the upstream revision is pinned in `src/webui/tests/api/LEGACY_REV`, currently `87e39a10`) and
`smoke.py` (a read-only test you run from your computer). Rebuild the bundle after changes with
`.migration/webui-api/deploy/make-bundle.sh` **from the repository root**.

## Why not just copy the files

On an OpenCCU image the API files are patched by OpenCCU (13 rootfs patches touch `www/api` and
`www/tcl`, six of them `methods.conf`). Overwriting a patched file with the upstream-based version
silently drops OpenCCU's changes. `install.sh` compares every file with its upstream checksum:

| Device file | What the installer does |
|---|---|
| equals upstream | replaces it |
| equals the new version | leaves it |
| differs (patched on the device) | skips it and says so; with `--patch` applies only our difference as a patch, if it applies cleanly |
| new file | adds it |
| equals a version this installer wrote earlier (new or old bundle) | **upgrades** it: replaces it by the new version (the backup keeps the old one) |
| was PATCHED by an earlier run onto an OpenCCU-modified file | not touched, and said so: replacing it would drop the OpenCCU changes it was patched onto. If it came from this very bundle it is just "already installed"; to move to a newer bundle, `restore` the older backups (newest first), then install |

Expect, on an OpenCCU image: 74 replaced, 19 added, 2 patched (`methods.conf`, `getpositiondata.tcl`)
and 4 skipped (`downloadFirmware.tcl`, `{restart,start,stop}hmipserver.tcl`; the known conflicts
with OpenCCU patches 0001 and 0164, see `src/webui/tests/api/PATCH-CONFLICTS.md`).

### Upgrading

After every install the installer records the md5 of each file it wrote in `/usr/local/webui-api-installed.txt` (history is
kept, nothing is removed), so a **newer bundle can be installed over an older one**: the files the installer wrote whole are
recognised as its own and replaced. A device installed by an older installer (before this file existed) is recorded by the
first run of the new installer for every file that already equals the bundle; files that were patched then stay "skipped" as
before. `sh .migration/webui-api/deploy/install-test.sh` tests the rules on a fake device (a miniature bundle in two
versions: install, upgrade, a patched file, a hand-edited file, restore); it needs no CCU.

**Merging upstream.** `LEGACY_REV` is the upstream revision the bundle and the tests measure "ours" against; advance it to the upstream
commit that was merged (`git merge upstream/main`, then `git rev-parse upstream/main > src/webui/tests/api/LEGACY_REV`) and build the
bundle AFTER the merge commit (it reads git history). `PATCH_BASE_REV` stays at the base the sibling OpenCCU patches were written for until
the sibling bumps its pin. A device that runs an OLDER firmware than `LEGACY_REV` has other bytes than the bundle's base for the files that
upstream changed (for example `methods.conf`, the `*hmipserver.tcl` methods, `getpositiondata.tcl`): the installer then skips them or
tries `--patch`; update the device image first, or expect those files to be reported as skipped. The nextGen UI and the v2 routes do not
depend on them.

## Steps

```sh
# 1. copy and look (changes nothing)
scp out/webui-api-bundle.tar.gz root@CCU:/tmp/
ssh root@CCU 'cd /tmp && tar xzf webui-api-bundle.tar.gz && cd webui-api-bundle && ./install.sh check --patch'

# 2. install (backs up every touched file first; refuses if /www is read-only)
ssh root@CCU 'cd /tmp/webui-api-bundle && ./install.sh install --patch'

# 3. smoke test from your computer (logs in, reads, probes; changes nothing)
CCU_PASS='...' python3 -I smoke.py --host http://CCU --user Admin

# 4. click through the classic UI: login, device list, programs, system variables, rooms,
#    the settings pages, the security hint / install wizard dialogs

# 5. undo (the exact command is printed by the installer)
ssh root@CCU '/tmp/webui-api-bundle/install.sh restore /usr/local/webui-api-backup-YYYYMMDD-HHMMSS.tar'
```

If `/www` is read-only the installer stops before changing anything. Use a container or VM, or make
the file system writable yourself; the installer never remounts anything.

## What the smoke test tells you

`PASS` is the hardened behaviour, `FAIL` the legacy behaviour (or a break), `INFO` a fact. Run it
before and after the install: before, the probes should FAIL (arbitrary file read through
`textfile.cgi`, `CCU.existsFile` answering for `/etc/passwd`, Tcl stack traces in errors); after,
they should PASS. The `INFO session key format` line answers EG-8: whether the session id is the
10-character inner id or the `@`-wrapped 12-character form. Send me that line.

Optional checks:

- `--strict`: first set `strict_mode true` in `/www/api/apiconfig.conf` on the CCU (Tcl syntax,
  inside the `array set API_CONFIG {...}` block). Requests without `X-Requested-With` must then be refused.
- `--v2`: checks both `/api/v2/*` and `/api/homematic.cgi/v2/*`. The first needs a lighttpd route that does not exist yet (INFO). The second reaches the CGI through PATH_INFO and needs only `v2_enabled true` in `apiconfig.conf` (PASS when the v2 router answers, INFO when the v1 dispatcher does).

## Not covered

No UI exists for v2; program/room editing and datapoint-change push events are not implemented
(they need a live CCU); lighttpd is not changed.

## Trying it on the data of a real CCU, without touching it: `isolated-ccu.sh`

A restored backup of your real CCU in a Docker container that cannot reach the internet, your LAN or the real CCU. It
shows the real devices, rooms, programs, system variables and history in the new UI; it has no radio, so nothing is
switched. `isolated-ccu.sh up | check | install | restore FILE.sbk | down` (the header of the script explains the isolation).

- Create the backup on the real CCU (Settings, Control panel, Security: create a backup; the exact tab name varies by
  version) and keep the `.sbk` **outside the repository**. It contains passwords and keys.
- `restore` validates the file (`restoreBackup.sh -c`), applies it, restarts the container and checks the isolation again.
- The instance is at `http://127.0.0.1:18090` on this host only (use an SSH tunnel from another machine). Log in with the
  user names and passwords of the **real** CCU.
- Never attach a radio module to it while the real CCU runs: both would claim the same devices.
- `down` removes the containers, the network and the volume with the restored data.
- `src/webui/tests/e2e/next_realdata.py` is the read-only pass for this instance (`--base http://127.0.0.1:18090`, your login):
  it compares every finished page with the classic API, times it and takes screenshots.
- Do not run the write tests of `src/webui/tests/e2e` against restored data (they create temporary objects and
  `next_log.py` clears the log); a read-only comparison with the classic UI is the test for real data.

## Reaching the test CCUs over Tailscale: `tailnet-proxy.sh`

The test containers publish their web UI on `127.0.0.1` only (hence the SSH tunnel). `tailnet-proxy.sh up` starts one nginx
container on the host network that listens **only on this host's Tailscale address** (`100.64.0.2`) on the ports 18080 (the
empty test CCU) and 18090 (the restored copy) and forwards to the loopback ports; `down` removes it, `status` shows what listens
and whether it answers. The CCU containers are not touched or recreated, so their isolation stays as it is. It does not listen on
the LAN address or `0.0.0.0` (checked), it only accepts the Tailscale range `100.64.0.0/10`, the stock A/B container (18081) is not
exposed, and it does not come back after a reboot by itself.

Then, from any machine on the tailnet: `http://100.64.0.2:18090/webui/next/` (restored copy) and `http://100.64.0.2:18080/webui/next/`.

**Mind who is on the tailnet:** whoever the Tailscale ACLs let reach this host can open these pages, and the restored copy holds
the data of a real CCU (names, rooms, programs, the accounts of the backup) with a test account (`AdminTest`) that has a weak
password. Use it on a tailnet you trust, give that account a strong password, or take the proxy down when you are done.
