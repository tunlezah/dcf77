# txtempus — Web Interface Design

> Proposal for bolting a **lightweight web admin UI** onto txtempus
> (`tunlezah/dcf77` fork). Read [`summary.md`](summary.md) first — this builds
> directly on the architecture, the CLI options in `src/txtempus.cc`, and the
> automation scripts in `build/txtempus-scheduler.sh` /
> `build/txtempus-systemd-setup.sh`.
>
> **Deployment target (drives every decision below):** Raspberry Pi Zero W —
> single-core ARMv6 @ 1 GHz, 512 MB RAM (~200–300 MB free on Raspberry Pi OS
> Lite), headless, on a trusted LAN. The transmit loop runs at **`SCHED_FIFO`
> priority 99 on the only core**, so the web layer must do essentially nothing
> CPU-heavy *during* a transmit window.

---

## 1. Goals & Non-Goals

### Goals
- **Pick the station / region** (DCF77 / WWVB / MSF / JJY40 / JJY60) from a
  browser — the headline feature. Maps to `txtempus -s`.
- **Transmit now** on demand for N minutes (maps to `-r`), and **stop** an
  in-progress transmission.
- **Edit the nightly schedule** (currently hard-coded 01:59 / 02:59 / 03:59 in
  `txtempus-systemd-setup.sh`) without SSH.
- **Show live status**: transmitting now? next scheduled run? last run result?
  system time + NTP sync state? CPU temperature?
- **Preview the modulation** envelope for a station using the existing `-n`
  dry-run (cheap, no root, no GPIO).
- **Replace the hard-coded values** in `txtempus-scheduler.sh`
  (`TXTEMPUS_PATH`, `SIGNAL_TYPE`, `RUN_DURATION`) with a **single config file**
  read by both the scheduler and the web UI.
- Be **tiny**: minimal RAM, near-zero idle CPU, no build pipeline, survives
  power loss (stateless server + persisted config file).

### Non-Goals
- **Not** a multi-user, internet-facing app. No accounts, no TLS, no OAuth
  (LAN-only — see §7).
- **Not** an SPA. No React/Vue/webpack/npm — the build pipeline alone would dwarf
  the device.
- **No heavy runtime**: no Node.js, no Django/FastAPI+uvicorn stack, no Docker,
  no database. Config is a flat file; "DB" is the filesystem + systemd + journal.
- **Not** the real-time transmitter. The web process **never** generates the
  carrier itself and must **not** run concurrent CPU work during transmit. It
  only **writes config and asks systemd to (re)start** the existing binary.
- No live waterfall/oscilloscope of the actual RF — the `-n` ASCII envelope is
  the only "signal view", and it's computed off the hot path.
- No editing of GPIO pin assignments / hardware wiring from the web (rare,
  risky, belongs in a config file edited over SSH).

---

## 2. Feature Set (controls to expose)

| Control | Maps to | Notes |
|---|---|---|
| **Station / region selector** | `-s DCF77\|WWVB\|MSF\|JJY40\|JJY60` | Radio buttons or dropdown. Show carrier freq next to each (77.5 / 60 / 60 / 40 / 60 kHz) — the user thinks in "my watch is European" terms. |
| **Transmit now** (Start) | `-s <station> -r <minutes>` | Fires a one-shot run. Uses the persisted station unless overridden. |
| **Stop** | `SIGTERM` to the running unit | `systemctl stop txtempus-oneshot` / kill PID. The binary already handles `SIGTERM`/`SIGINT` cleanly (`InterruptHandler` in `txtempus.cc`). |
| **Run duration** | `-r <minutes>` | Number field (default 10–20). Bounded 1–120 server-side. |
| **Schedule editor** | writes systemd timer (or cron) | List of `HH:MM` times (default 01:59 / 02:59 / 03:59) + per-run duration + enable/disable toggle. Persisted, then timer regenerated (see §4). |
| **Timezone offset** (`-z`) | `-z <minutes>` | Advanced/debug. For displaying a different zone on the clock (issue #17 use case). |
| **Test time** (`-t`) | `-t 'YYYY-MM-DD HH:MM'` | Advanced/debug only. Send a fixed time instead of "now". |
| **Live status panel** | read-only | Transmitting? (is the unit active) · next run (`systemctl list-timers`) · last result (journal/last-run file) · system time + **NTP synced?** (`timedatectl`) · **CPU temp** (`/sys/class/thermal/thermal_zone0/temp`, already read by the scheduler). |
| **Preview modulation** | `-n -s <station>` | Runs the dry-run (no root, off the GPIO), streams the `_`/`#` ASCII chart for the minute. Pure CPU but trivial and **must be blocked while transmitting** (see §6). |
| **Dry-run toggle** for "Transmit now" | `-n` | Optional: lets the user verify config produces output before keying the antenna. |

**Deliberately hidden / read-only:** GPIO pins, peripheral base, carrier source —
these live in the config file but aren't editable from the web in the MVP.

---

## 3. Architecture Options

Four concrete, Pi-Zero-W-appropriate approaches. All share the same shape:
**a small sidecar HTTP process that reads/writes a config file and shells out to
`txtempus` / `systemctl` — separate from the real-time C++ binary.**

> **Why a separate sidecar, not an HTTP server inside the C++ binary?**
> The transmitter runs as `SCHED_FIFO` priority 99. Embedding an HTTP listener,
> request parsing, and socket handling **in that same process and priority** is
> dangerous: a blocked accept loop, a slow client, or any allocation contending
> with the second-accurate `clock_nanosleep` loop can jitter the carrier
> modulation. It also means the web UI dies whenever transmission isn't running
> (and you can't start a transmission from a server that only exists while
> transmitting). **Keep them separate processes.** The transmitter stays a lean,
> single-purpose real-time program; the web sidecar runs at normal (or `nice`d /
> idle) priority and merely **orchestrates** it via config + systemd.

| Option | Stack | Idle RAM (approx) | Deps to install | Pros | Cons |
|---|---|---|---|---|---|
| **A. Python stdlib `http.server`** | One `.py` file, `ThreadingHTTPServer` + `BaseHTTPRequestHandler`, serves one static HTML page + JSON endpoints | ~12–20 MB RSS | **None** (Python 3 ships with Raspberry Pi OS) | Zero extra packages; full control; trivial to call `subprocess`/`systemctl`; easy JSON; one systemd unit | You hand-write routing/JSON (small); not a "production" server (fine for LAN, low traffic) |
| **B. Python + Bottle** | Single-file `bottle.py` micro-framework (no other deps) on the stdlib WSGI server | ~15–25 MB RSS | `bottle` (one file, vendored — no pip tree) | Clean routing/templating, still tiny; **best memory behaviour of the Python micro-frameworks** under repeated requests | One extra (vendorable) file vs. A; marginally more RAM; another thing to keep updated |
| **C. busybox httpd + CGI shell scripts** | `busybox httpd` (≈ part of a ~2 MB binary, usually already present) serving static HTML + `cgi-bin/*.sh` | ~1–3 MB RSS | busybox (often already installed) | **Smallest footprint by far**; no language runtime; static page is just files | CGI in shell is awkward for JSON/state; per-request `fork`/`exec` cost; error handling and validation in bash get ugly fast; harder to maintain |
| **D. Small Go single binary** | One static Go binary (`net/http`, embedded HTML via `embed`) | ~5–12 MB RSS | None at runtime (static binary), **but** needs a Go cross-compile toolchain at build time | Tiny RSS, fast, single self-contained artifact, no interpreter; great long-term | Adds a **second language + cross-build step** to a C++/bash project; overkill for a config-and-launch UI; more moving parts for a small team |

### Recommendation: **Option A — Python stdlib `http.server`** (sidecar), with **B (Bottle)** as the drop-in upgrade if routing grows.

Rationale:
- **Nothing to install.** Raspberry Pi OS ships Python 3, so the appliance stays
  buildable/flashable with no extra package fetch — important on a slow,
  memory-tight Zero W. (Bottle is a single vendorable file if/when you want
  nicer routing; it also has the best repeated-request memory profile of the
  micro-frameworks, so it's the natural step up — not a rewrite.)
- **Idle cost is dominated by the Python interpreter (~12–20 MB)**, which is
  acceptable against ~200–300 MB free, and the process sits at **0% CPU when
  idle** (blocking on `accept`).
- The job is **orchestration, not serving**: write a config file, call
  `subprocess.run(["systemctl", ...])`, read `/sys`/`timedatectl`/journal. Python
  does this far more cleanly than shell-CGI (Option C), and without dragging in a
  whole second toolchain (Option D).
- Go (D) is genuinely lighter at runtime and a fine choice for a polished v2, but
  the **cross-compile step and second language** aren't worth it for an admin
  panel that mostly shells out. Revisit only if RAM becomes the binding
  constraint.
- busybox-CGI (C) wins on raw bytes but **loses on maintainability** the moment
  you need JSON, validation, or state — which this UI does.

**Control model (all options):** the web process **never transmits**. It:
1. **Writes** `/etc/txtempus.conf`.
2. For *Transmit now*: `systemctl start txtempus-oneshot.service` (an
   `ExecStart` that reads the conf), or a tiny `txtempus-control.sh` wrapper.
3. For *Stop*: `systemctl stop txtempus-oneshot.service` (delivers `SIGTERM`).
4. For *Schedule*: rewrite the timer (drop-in or generated unit) +
   `systemctl daemon-reload` + restart the timer.
5. For *Status/Preview*: read-only reads + a short `txtempus -n` (gated off
   during transmit).

This keeps **all privileged / real-time work inside systemd-managed units**, and
the web process only needs permission to run a **narrow allow-list** of
`systemctl` verbs (see §7), not to be root itself.

---

## 4. Config & Control Design

### 4.1 Config file — `/etc/txtempus.conf`

A single source of truth, read by **both** the scheduler script and the web UI.
This **replaces** the hard-coded `TXTEMPUS_PATH` / `SIGNAL_TYPE` / `RUN_DURATION`
at the top of `build/txtempus-scheduler.sh`.

**Format choice: INI / shell-sourceable `KEY=VALUE`.** It's trivially
`source`-able from the existing bash scheduler (`. /etc/txtempus.conf`),
trivially parsed by Python (`configparser` with a synthetic section, or a 5-line
split), and human-editable over SSH. JSON would force the bash script to grow a
parser; KEY=VALUE costs the scheduler one line.

```ini
# /etc/txtempus.conf — read by the web UI and the scheduler.
# Station: DCF77 | WWVB | MSF | JJY40 | JJY60
STATION=DCF77

# Default transmit duration in minutes (1..120)
RUN_DURATION=10

# Time-zone offset in minutes for the transmitted time (-z). 0 = local.
ZONE_OFFSET=0

# Nightly schedule (comma-separated HH:MM, 24h). Empty disables scheduling.
SCHEDULE_TIMES=01:59,02:59,03:59
SCHEDULE_ENABLED=true

# Path to the installed binary (fixes the hard-coded /home/mark/... path).
TXTEMPUS_PATH=/usr/bin/txtempus

# Thermal guard (°C) — scheduler already warns above this.
TEMP_WARN_C=70

# Optional LAN-only PIN for the web UI ("" = no PIN). See §7.
WEB_PIN=
# Interface/port the web UI binds to.
WEB_BIND=0.0.0.0
WEB_PORT=8080
```

> **Migration note:** update `txtempus-scheduler.sh` to `source` this file and
> use `$STATION` / `$RUN_DURATION` / `$TXTEMPUS_PATH` instead of its current
> hard-coded constants. That single change makes the scheduler and the web UI
> agree, and fixes the wrong (build-tree, user-specific) binary path flagged in
> `summary.md`.

### 4.2 systemd units

Two responsibilities, cleanly split:

**(a) On-demand "Transmit now" — `txtempus-oneshot.service`** (new, conf-driven):

```ini
# /etc/systemd/system/txtempus-oneshot.service
[Unit]
Description=txtempus on-demand transmit
After=time-sync.target

[Service]
Type=simple
EnvironmentFile=/etc/txtempus.conf
# RUN_DURATION/STATION/ZONE_OFFSET come from the conf; web UI may pass overrides
# via `systemctl set-environment` or a small wrapper before `start`.
ExecStart=/usr/bin/txtempus -s ${STATION} -r ${RUN_DURATION} -z ${ZONE_OFFSET}
# Web "Stop" => `systemctl stop` => SIGTERM => clean shutdown (StopClock()).
```

`Type=simple` (not `oneshot`) so `systemctl is-active` reports "transmitting now"
truthfully and `stop` maps to a clean `SIGTERM` while it runs.

**(b) Scheduled nightly runs — reuse the existing
`txtempus-scheduler.service` + `.timer`**, but make the **times editable**.

The schedule editor regenerates the timer's `OnCalendar=` lines. The robust,
auditable way is a **drop-in override** the web UI fully owns:

```ini
# /etc/systemd/system/txtempus-scheduler.timer.d/schedule.conf  (UI-managed)
[Timer]
OnCalendar=          # reset accumulated values first
OnCalendar=*-*-* 01:59:00
OnCalendar=*-*-* 02:59:00
OnCalendar=*-*-* 03:59:00
```

> systemd timers report **`CanReload=no`**, so after writing this drop-in the UI
> must run **`systemctl daemon-reload`** and then **restart the timer** for new
> times to take effect — the control script does both. Toggling
> `SCHEDULE_ENABLED` maps to `systemctl enable --now` / `disable --now` on the
> timer.

### 4.3 Control script — `txtempus-control.sh`

A thin, **allow-listed** shim the web process calls (so the web user needs only
sudo rights to *this one script*, not arbitrary `systemctl`):

```
txtempus-control.sh start            # systemctl start txtempus-oneshot.service
txtempus-control.sh stop             # systemctl stop  txtempus-oneshot.service
txtempus-control.sh apply-schedule   # rewrite drop-in, daemon-reload, restart timer
txtempus-control.sh schedule on|off  # enable/disable the timer
txtempus-control.sh status           # emit JSON: active?, next-run, temp, ntp, time
txtempus-control.sh preview <STATION># /usr/bin/txtempus -n -s <STATION>  (refused if transmitting)
```

This is the **only** privileged surface; the web app itself stays unprivileged.

### 4.4 Minimal HTTP API

Small JSON API + one static page. All mutating calls are `POST` and require the
PIN header if configured (§7).

```
GET  /                       -> index.html (the single admin page)
GET  /api/status             -> live status (polled every few seconds)
GET  /api/config             -> current persisted settings
POST /api/config             -> validate + write /etc/txtempus.conf
POST /api/transmit/start     -> {station?, minutes?, dryrun?}  (overrides for one run)
POST /api/transmit/stop      -> stop the running transmission
GET  /api/schedule           -> {enabled, times:[...], duration}
POST /api/schedule           -> save + regenerate timer (daemon-reload + restart)
GET  /api/preview?station=…  -> dry-run ASCII envelope (text/plain or JSON lines)
```

**`GET /api/status` response:**
```json
{
  "transmitting": true,
  "station": "DCF77",
  "carrier_hz": 77500,
  "run_duration_min": 10,
  "started_at": "2026-06-06T01:59:00+00:00",
  "next_scheduled": "2026-06-07T01:59:00+00:00",
  "schedule_enabled": true,
  "last_run": { "at": "2026-06-05T03:59:00Z", "result": "completed", "exit": 0 },
  "system_time": "2026-06-06T02:03:11+00:00",
  "ntp_synchronized": true,
  "cpu_temp_c": 48.7
}
```
Sources for `status`: `transmitting`/`started_at` from
`systemctl is-active`/`show`; `next_scheduled` from `systemctl list-timers`;
`ntp_synchronized` from `timedatectl show -p NTPSynchronized`; `cpu_temp_c` from
`/sys/class/thermal/thermal_zone0/temp`; `last_run` from a small file the
control script writes (or `journalctl -u … -n1`).

**`POST /api/transmit/start` request:**
```json
{ "station": "WWVB", "minutes": 15, "dryrun": false }
```
(Omit fields to use persisted config. Server validates station against the 5
known values and clamps `minutes`.)

---

## 5. UI Sketch (single page)

One static HTML page, vanilla JS polling `/api/status`. No framework, no build.

```
┌───────────────────────────────────────────────────────────────────────┐
│  txtempus · time-signal transmitter                       [● TX ACTIVE] │
├───────────────────────────────────────────────────────────────────────┤
│  STATUS                                                                  │
│   State:        Transmitting (DCF77, 77.5 kHz) — 6:41 remaining          │
│   Next run:     tomorrow 01:59                                           │
│   Last run:     2026-06-05 03:59  → completed (10 min)                   │
│   System time:  2026-06-06 02:03:11   NTP: ✔ synced                      │
│   CPU temp:     48.7 °C                                          [↻]      │
├───────────────────────────────────────────────────────────────────────┤
│  STATION / REGION                                                        │
│   ( ) DCF77  — Germany / Europe   77.5 kHz                               │
│   ( ) WWVB   — USA                60   kHz                               │
│   ( ) MSF    — UK                 60   kHz                               │
│   ( ) JJY40  — Japan              40   kHz                               │
│   ( ) JJY60  — Japan              60   kHz                               │
│                                                       [ Save station ]   │
├───────────────────────────────────────────────────────────────────────┤
│  TRANSMIT NOW                                                            │
│   Duration: [ 10 ] min     [ ] dry-run (no RF)                           │
│        [ ▶ Start transmit ]            [ ■ Stop ]                        │
├───────────────────────────────────────────────────────────────────────┤
│  SCHEDULE                            [x] enabled                         │
│   Nightly times:  [01:59] [02:59] [03:59]  (+ add)   Duration [10] min   │
│                                                       [ Save schedule ]  │
├───────────────────────────────────────────────────────────────────────┤
│  ADVANCED (collapsed)                                                    │
│   Zone offset (-z): [  0 ] min     Test time (-t): [____-__-__ __:__]    │
│   [ Preview modulation ]  ── disabled while transmitting ──              │
│   :00 [________##]  :01 [__########]  :02 [_____#####] ...               │
└───────────────────────────────────────────────────────────────────────┘
```

Polling interval ~3–5 s for the status block; **stop polling / no preview while
`transmitting` is true** to keep the core free (§6).

---

## 6. Resource Budget & Staying Out of the Transmitter's Way

**Why this is fine on a Pi Zero W:**
- **Idle RAM:** the recommended Python sidecar is ~12–20 MB RSS against
  ~200–300 MB free on Raspberry Pi OS Lite — comfortably under budget and far
  below anything Node/Docker would cost. (Bottle, if adopted later, adds only a
  few MB and has the best repeated-request memory profile of the Python
  micro-frameworks.)
- **Idle CPU:** the server blocks on `accept()` — **0% CPU when nobody's looking
  at it**. With nightly transmits and a single admin browser, traffic is
  negligible; there is no high-throughput serving.
- **No build pipeline / no DB:** nothing to compile on-device, no database daemon
  resident in RAM. State = one config file + systemd + the journal.

**Keeping clear of the real-time transmit window (the critical constraint):**
1. **Different process, different priority.** The web sidecar runs at normal
   priority (optionally `Nice=10` / `CPUSchedulingPolicy=idle` in its unit) so
   the `SCHED_FIFO` 99 transmitter always preempts it on the single core.
2. **No heavy work on the hot path.** Status reads (`/sys`, `timedatectl`,
   `systemctl show`) are cheap and infrequent. The only non-trivial CPU op is the
   `-n` **preview**, which is **server-side gated: refused (HTTP 409) while
   `transmitting` is true**, and the UI hides the button then.
3. **The web app never modulates.** It writes config and asks systemd to start
   the binary; it doesn't itself touch GPIO or spin the carrier. During a
   transmit, the web app is essentially passive (occasional status poll).
4. **Slow-client safety.** Use `ThreadingHTTPServer` (or Bottle's WSGI server)
   with a short socket timeout so a hung browser can't pile up work; cap
   concurrent handlers. Even so, these threads are normal-priority and yield to
   the transmitter.
5. **Cheap status during TX:** when `transmitting` is true the UI backs off
   polling (e.g. every 10 s instead of 3 s) and disables preview — so a left-open
   tab can't nibble the core mid-broadcast.

Net effect: during the short, infrequent nightly windows the web layer is
near-silent; outside them it's a tiny idle process.

---

## 7. Security Note (proportionate — LAN only)

Per `summary.md`, this is **LAN-only and security is not a primary concern**, so
**do not over-engineer** — no TLS, no user accounts, no session DB.

- **Bind to the LAN** (configurable `WEB_BIND`/`WEB_PORT`). If the Pi has a known
  trusted subnet, bind to that interface rather than `0.0.0.0`.
- **Optional single PIN** (`WEB_PIN` in the conf): if set, require it on all
  **mutating** `POST`s via a header (`X-Txtempus-Pin`) or a one-field login that
  stores it client-side. Empty = open (acceptable on a private LAN). This is a
  speed bump against a curious housemate, not a security boundary.
- **Privilege minimization is the real win:** the web process runs **as a
  non-root user** and is granted sudo rights only to the **single
  `txtempus-control.sh`** allow-list (a tight `sudoers` entry), never to raw
  `systemctl`/`rm`/shell. All inputs are validated server-side (station ∈ the 5
  values; `minutes` clamped; `HH:MM` regex-checked) so nothing user-supplied is
  interpolated into a shell — call binaries with argument arrays, never
  `shell=True`.
- Explicitly **out of scope:** rate limiting, CSRF tokens, audit trails, HTTPS
  certs. If this ever faced the internet, that calculus changes — but that's a
  non-goal here.

---

## 8. Incremental Rollout

**Phase 0 — Config refactor (enabler, no UI):**
- Introduce `/etc/txtempus.conf`; make `txtempus-scheduler.sh` `source` it and
  drop the hard-coded `TXTEMPUS_PATH` / `SIGNAL_TYPE` / `RUN_DURATION`
  (also fixes the wrong binary path noted in `summary.md`).
- Add `txtempus-oneshot.service` and the `txtempus-control.sh` shim
  (`start`/`stop`/`status`/`preview`).

**Phase 1 — MVP web UI (the must-haves):**
- Single Python `http.server` sidecar + one static page + `txtempus-control.sh`.
- Features: **station selector** (writes conf), **Transmit now / Stop** with
  duration, and the **live status panel** (TX state, system time, NTP, CPU temp).
- `GET /api/status`, `GET/POST /api/config`, `POST /api/transmit/start|stop`.
- Ship as its own `txtempus-web.service` (unprivileged, `Nice`d).

**Phase 2 — Scheduling:**
- Schedule editor that rewrites the timer drop-in + `daemon-reload` + restart;
  enable/disable toggle. `GET/POST /api/schedule`. Surface "next run" + "last
  run result" in status.

**Phase 3 — Extras / polish:**
- **Preview modulation** (`-n`) viewer (gated off during TX), advanced `-z`/`-t`
  fields, dry-run toggle on "Transmit now", optional `WEB_PIN`, nicer styling.
- *Optional, only if RAM proves tight:* port the sidecar to a **single static Go
  binary** (Option D) for a ~5–12 MB footprint — same API, no Python interpreter
  resident.

---

## Recommended Approach (summary)

Build a **small, separate, unprivileged Python `http.server` sidecar** that
serves **one static admin page + a tiny JSON API**, persists everything to a
**shell-sourceable `/etc/txtempus.conf`** shared with the scheduler, and effects
all actions by **writing config and driving systemd** through a narrow
`txtempus-control.sh` allow-list — **never** by transmitting itself. This keeps
the real-time `SCHED_FIFO` 99 transmitter untouched and lean, costs ~12–20 MB
idle RAM and ~0% idle CPU on the Pi Zero W, needs **zero extra packages**
(Python ships with Raspberry Pi OS), and stays out of the transmit window by
running at lower priority and gating its only non-trivial CPU op (the `-n`
preview) while a broadcast is live. Adopt **Bottle** (one vendorable file) only
if routing grows; consider a **Go single binary** only if RAM ever becomes the
binding constraint.

---

### Sources
- [Python microframework memory/speed comparison (bottle/flask/cherrypy/tornado/web.py)](https://github.com/drandreaskrueger/pythonMicroframeworks) — Bottle shows the best memory behaviour under repeated requests.
- [Python `http.server` docs (`BaseHTTPRequestHandler`, `ThreadingHTTPServer`)](https://docs.python.org/3/library/http.server.html)
- [Controlling Raspberry Pi GPIO via `http.server` (no Flask/LAMP needed)](https://www.e-tinkers.com/2018/04/how-to-control-raspberry-pi-gpio-via-http-web-server/) · [code](https://github.com/e-tinkers/simple_httpserver)
- [busybox httpd minimal web server (~2 MB image)](https://github.com/hypriot/rpi-busybox-httpd)
- [Pi Zero hardware constraints — single-core ARMv6, slow I/O, tight RAM](https://blog.alexellis.io/memory-lane-raspberry-pi-zero/)
- [Raspberry Pi OS ships Python 3 / Pi Zero W free-RAM context](https://www.raspberrypi.com/documentation/computers/os.html)
- [systemd timers report `CanReload=no` → need `daemon-reload` + restart after edits](https://www.simplified.guide/systemd/timer-manage)
- [systemd drop-in overrides (`/etc/systemd/system/<unit>.d/*.conf`)](https://how2.sh/posts/how-to-manage-systemd-services-with-drop-in-overrides/)
