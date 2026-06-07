#!/usr/bin/env python3
"""txtempus web admin UI -- a tiny, dependency-free sidecar.

Serves one static admin page plus a small JSON API for a Raspberry Pi
time-signal appliance. It is deliberately lightweight (Python 3 stdlib only,
no Flask/Node/DB) so it fits a Pi Zero W, and it NEVER transmits itself: all
state-changing actions are delegated to systemd via txtempus-control.sh, and
the only non-trivial CPU op (the -n preview) is refused while transmitting.

Config and control paths can be overridden via environment variables for
testing off-device:
    TXTEMPUS_CONF      (default /etc/txtempus.conf)
    TXTEMPUS_CONTROL   (default /usr/local/bin/txtempus-control.sh; may include
                        a 'sudo ' prefix, e.g. "sudo /usr/local/bin/txtempus-control.sh")
    TXTEMPUS_WEB_BIND  / TXTEMPUS_WEB_PORT  (override conf WEB_BIND/WEB_PORT)
"""

import json
import os
import re
import shlex
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

CONF_PATH = os.environ.get("TXTEMPUS_CONF", "/etc/txtempus.conf")
CONTROL = os.environ.get("TXTEMPUS_CONTROL", "/usr/local/bin/txtempus-control.sh")
LAST_RUN_PATH = os.environ.get("TXTEMPUS_LAST_RUN", "/run/txtempus/last-run")
# Modular watch-guide database (user-editable). Falls back to the copy bundled
# next to this script when the installed one isn't present (e.g. during dev).
WATCHES_PATH = os.environ.get("TXTEMPUS_WATCHES", "/etc/txtempus-watches.json")
_BUNDLED_WATCHES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "watches.json")

ONESHOT_UNIT = "txtempus-oneshot.service"
SCHED_UNIT = "txtempus-scheduler.service"
TIMER_UNIT = "txtempus-scheduler.timer"

# Station metadata (single source of truth for the UI labels + carrier).
STATIONS = {
    "DCF77": {"region": "Germany / Europe", "carrier_hz": 77500},
    "WWVB":  {"region": "USA",              "carrier_hz": 60000},
    "MSF":   {"region": "United Kingdom",   "carrier_hz": 60000},
    "JJY40": {"region": "Japan",            "carrier_hz": 40000},
    "JJY60": {"region": "Japan",            "carrier_hz": 60000},
    "BPC":   {"region": "China",            "carrier_hz": 68500, "experimental": True},
}
TIME_RE = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")


# --------------------------------------------------------------------------- #
# Config helpers (shell-sourceable KEY=VALUE, comment-preserving writes)
# --------------------------------------------------------------------------- #
def read_conf():
    conf = {}
    try:
        with open(CONF_PATH) as f:
            for line in f:
                s = line.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, v = s.split("=", 1)
                conf[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return conf


def update_conf(updates):
    """Update KEY=VALUE pairs in place, preserving comments/order; atomic."""
    try:
        with open(CONF_PATH) as f:
            lines = f.readlines()
    except FileNotFoundError:
        lines = []
    seen, out = set(), []
    for line in lines:
        s = line.strip()
        if s and not s.startswith("#") and "=" in s:
            k = s.split("=", 1)[0].strip()
            if k in updates:
                out.append(f"{k}={updates[k]}\n")
                seen.add(k)
                continue
        out.append(line)
    for k, v in updates.items():
        if k not in seen:
            out.append(f"{k}={v}\n")
    tmp = CONF_PATH + ".tmp"
    with open(tmp, "w") as f:
        f.writelines(out)
    os.replace(tmp, CONF_PATH)


# --------------------------------------------------------------------------- #
# Subprocess helpers (always argument arrays, never shell=True)
# --------------------------------------------------------------------------- #
def run_cmd(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError as e:
        return 127, "", str(e)
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"


def control(*args):
    return run_cmd(shlex.split(CONTROL) + list(args))


def systemctl(*args):
    return run_cmd(["systemctl", *args])


def sc_value(unit, prop):
    rc, out, _ = systemctl("show", unit, "-p", prop, "--value")
    return out.strip() if rc == 0 else ""


def is_active(unit):
    rc, out, _ = systemctl("is-active", unit)
    return out.strip() == "active"


# --------------------------------------------------------------------------- #
# Validation
# --------------------------------------------------------------------------- #
def valid_station(s):
    return s in STATIONS


def clamp_minutes(v, default):
    try:
        return max(1, min(120, int(v)))
    except (TypeError, ValueError):
        return default


def valid_zone(v):
    try:
        int(v)
        return True
    except (TypeError, ValueError):
        return False


def clean_times(value):
    """Accept a list or comma string of HH:MM; return validated list or None."""
    if isinstance(value, str):
        items = value.split(",")
    elif isinstance(value, list):
        items = value
    else:
        return None
    out = []
    for t in items:
        t = str(t).strip()
        if not t:
            continue
        if not TIME_RE.match(t):
            return None
        out.append(t)
    return out


# --------------------------------------------------------------------------- #
# Status
# --------------------------------------------------------------------------- #
def read_last_run():
    info = {}
    try:
        with open(LAST_RUN_PATH) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    info[k] = v
    except (FileNotFoundError, OSError):
        return None
    return info or None


def cpu_temp_c():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read().strip()) / 1000.0, 1)
    except (FileNotFoundError, OSError, ValueError):
        return None


def transmitting_now():
    if is_active(ONESHOT_UNIT) or is_active(SCHED_UNIT):
        return True
    # Fallback when systemd is unavailable (e.g. dev box): look for the process.
    rc, out, _ = run_cmd(["pgrep", "-x", "txtempus"])
    return rc == 0 and out.strip() != ""


def transmitted_info(station, zone_offset):
    """What time the watch will be set to + the DST signalling, mirroring what
    the binary encodes: local time for DCF77/MSF/JJY, UTC for WWVB; DST derived
    from the Pi's local timezone (same as the C++ localtime_r tm_isdst)."""
    effective = time.time() + zone_offset * 60
    basis = "UTC" if station == "WWVB" else "local"
    ts = time.gmtime(effective) if basis == "UTC" else time.localtime(effective)
    isdst = time.localtime(effective).tm_isdst > 0
    if station == "DCF77":
        dst_active, dst_text = isdst, ("CEST (central European summer time)" if isdst
                                       else "CET (central European time)")
    elif station == "MSF":
        dst_active, dst_text = isdst, ("BST (British summer time)" if isdst
                                       else "GMT (Greenwich mean time)")
    elif station == "WWVB":
        dst_active, dst_text = isdst, ("DST flag set" if isdst
                                       else "no DST flag (standard time)")
    elif station == "BPC":
        dst_active, dst_text = None, "CST (China has no daylight saving)"
    else:  # JJY40 / JJY60 -- Japan has no DST
        dst_active, dst_text = None, "JST (Japan has no daylight saving)"
    return {
        "time": time.strftime("%H:%M", ts),
        "date": time.strftime("%Y-%m-%d", ts),
        "weekday": time.strftime("%a", ts),
        "basis": basis,
        "zone_offset_min": zone_offset,
        "dst_active": dst_active,
        "dst_text": dst_text,
    }


def build_status():
    conf = read_conf()
    station = conf.get("STATION", "DCF77")
    zone = int(conf["ZONE_OFFSET"]) if conf.get("ZONE_OFFSET", "0").lstrip("-").isdigit() else 0
    tx = transmitting_now()
    active_unit = ONESHOT_UNIT if is_active(ONESHOT_UNIT) else (
        SCHED_UNIT if is_active(SCHED_UNIT) else None)
    ntp = None
    rc, out, _ = run_cmd(["timedatectl", "show", "-p", "NTPSynchronized", "--value"])
    if rc == 0:
        ntp = (out.strip() == "yes")
    return {
        "transmitting": tx,
        "station": station,
        "carrier_hz": STATIONS.get(station, {}).get("carrier_hz"),
        "run_duration_min": clamp_minutes(conf.get("RUN_DURATION"), 10),
        "started_at": sc_value(active_unit, "ActiveEnterTimestamp") if active_unit else None,
        "next_scheduled": sc_value(TIMER_UNIT, "NextElapseUSecRealtime") or None,
        "schedule_enabled": conf.get("SCHEDULE_ENABLED", "true").lower() == "true",
        "schedule_times": clean_times(conf.get("SCHEDULE_TIMES", "")) or [],
        "timer_enabled": sc_value(TIMER_UNIT, "UnitFileState") == "enabled",
        "timer_active": is_active(TIMER_UNIT),
        "transmitted": transmitted_info(station, zone),
        "last_run": read_last_run(),
        "system_time": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "ntp_synchronized": ntp,
        "cpu_temp_c": cpu_temp_c(),
        "stations": STATIONS,
    }


def load_watches():
    """Load the modular watch-guide list; tolerate missing/!malformed files."""
    for path in (WATCHES_PATH, _BUNDLED_WATCHES):
        try:
            with open(path) as f:
                return json.load(f).get("watches", [])
        except (FileNotFoundError, OSError):
            continue
        except (json.JSONDecodeError, ValueError):
            continue
    return []


def get_config():
    conf = read_conf()
    return {
        "station": conf.get("STATION", "DCF77"),
        "run_duration": clamp_minutes(conf.get("RUN_DURATION"), 10),
        "zone_offset": int(conf["ZONE_OFFSET"]) if conf.get("ZONE_OFFSET", "0").lstrip("-").isdigit() else 0,
        "schedule_times": clean_times(conf.get("SCHEDULE_TIMES", "")) or [],
        "schedule_enabled": conf.get("SCHEDULE_ENABLED", "true").lower() == "true",
        "temp_warn_c": conf.get("TEMP_WARN_C", "70"),
        "web_port": conf.get("WEB_PORT", "8080"),
        "pin_required": bool(conf.get("WEB_PIN", "")),
        "stations": STATIONS,
    }


# --------------------------------------------------------------------------- #
# Actions (called from POST handlers)
# --------------------------------------------------------------------------- #
def do_preview(station):
    if not valid_station(station):
        return False, {"error": f"unknown station {station!r}"}, 400
    if transmitting_now():
        return False, {"error": "refused: a transmission is in progress"}, 409
    conf = read_conf()
    binary = conf.get("TXTEMPUS_PATH", "/usr/bin/txtempus")
    rc, out, err = run_cmd([binary, "-n", "-s", station], timeout=20)
    if rc != 0:
        return False, {"error": err.strip() or f"{binary} exited {rc}"}, 500
    # txtempus prints the dry-run modulation chart to stderr; combine both.
    return True, {"station": station, "envelope": (out or "") + (err or "")}, 200


def do_transmit_start(body):
    station = body.get("station") or read_conf().get("STATION", "DCF77")
    if not valid_station(station):
        return False, {"error": f"unknown station {station!r}"}, 400
    minutes = clamp_minutes(body.get("minutes"), clamp_minutes(read_conf().get("RUN_DURATION"), 10))
    zone = body.get("zone")
    if zone is None:
        zone = read_conf().get("ZONE_OFFSET", "0")
    if not valid_zone(zone):
        return False, {"error": "invalid zone offset"}, 400

    if body.get("dryrun"):
        return do_preview(station)

    rc, out, err = control("start", station, str(minutes), str(int(zone)))
    if rc != 0:
        return False, {"error": err.strip() or out.strip() or f"control exited {rc}"}, 500
    return True, {"started": True, "station": station, "minutes": minutes}, 200


def do_transmit_stop():
    rc, out, err = control("stop")
    if rc != 0:
        return False, {"error": err.strip() or f"control exited {rc}"}, 500
    return True, {"stopped": True}, 200


def do_save_config(body):
    updates = {}
    if "station" in body:
        if not valid_station(body["station"]):
            return False, {"error": "invalid station"}, 400
        updates["STATION"] = body["station"]
    if "run_duration" in body:
        updates["RUN_DURATION"] = str(clamp_minutes(body["run_duration"], 10))
    if "zone_offset" in body:
        if not valid_zone(body["zone_offset"]):
            return False, {"error": "invalid zone offset"}, 400
        updates["ZONE_OFFSET"] = str(int(body["zone_offset"]))
    if not updates:
        return False, {"error": "nothing to update"}, 400
    update_conf(updates)
    return True, {"saved": list(updates.keys()), "config": get_config()}, 200


def do_save_schedule(body):
    updates = {}
    if "times" in body:
        times = clean_times(body["times"])
        if times is None:
            return False, {"error": "invalid times (expected HH:MM)"}, 400
        updates["SCHEDULE_TIMES"] = ",".join(times)
    if "enabled" in body:
        updates["SCHEDULE_ENABLED"] = "true" if body["enabled"] else "false"
    if "duration" in body:
        updates["RUN_DURATION"] = str(clamp_minutes(body["duration"], 10))
    if updates:
        update_conf(updates)
    rc, out, err = control("apply-schedule")
    if rc != 0:
        return False, {"error": err.strip() or out.strip() or f"control exited {rc}"}, 500
    return True, {"saved": True, "config": get_config()}, 200


# --------------------------------------------------------------------------- #
# HTTP handler
# --------------------------------------------------------------------------- #
class Handler(BaseHTTPRequestHandler):
    timeout = 15
    server_version = "txtempus-web"

    def log_message(self, fmt, *args):  # keep journald tidy
        pass

    # -- helpers --
    def _send_json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send(self, body, ctype="text/plain; charset=utf-8", code=200):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
        except ValueError:
            n = 0
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except (json.JSONDecodeError, ValueError):
            return None

    def _pin_ok(self):
        pin = read_conf().get("WEB_PIN", "")
        if not pin:
            return True
        return self.headers.get("X-Txtempus-Pin", "") == pin

    # -- routing --
    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            return self._send(PAGE, "text/html; charset=utf-8")
        if path == "/api/status":
            return self._send_json(build_status())
        if path == "/api/config":
            return self._send_json(get_config())
        if path == "/api/schedule":
            c = get_config()
            return self._send_json({
                "enabled": c["schedule_enabled"],
                "times": c["schedule_times"],
                "duration": c["run_duration"],
            })
        if path == "/api/watches":
            return self._send_json({"watches": load_watches()})
        if path == "/api/preview":
            q = parse_qs(urlparse(self.path).query)
            station = (q.get("station") or [""])[0]
            ok, payload, code = do_preview(station)
            return self._send_json(payload, code)
        return self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._pin_ok():
            return self._send_json({"error": "PIN required or incorrect"}, 403)
        body = self._read_json()
        if body is None:
            return self._send_json({"error": "invalid JSON"}, 400)

        if path == "/api/config":
            ok, payload, code = do_save_config(body)
        elif path == "/api/transmit/start":
            ok, payload, code = do_transmit_start(body)
        elif path == "/api/transmit/stop":
            ok, payload, code = do_transmit_stop()
        elif path == "/api/schedule":
            ok, payload, code = do_save_schedule(body)
        else:
            return self._send_json({"error": "not found"}, 404)
        payload.setdefault("ok", code < 400)
        return self._send_json(payload, code)


# --------------------------------------------------------------------------- #
# Single-page UI (vanilla HTML/CSS/JS, no build step)
# --------------------------------------------------------------------------- #
PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>txtempus</title>
<style>
  :root { --bg:#0f1419; --card:#1a2129; --fg:#e6e6e6; --muted:#8a97a6;
          --accent:#4a9eff; --ok:#3fb950; --warn:#d29922; --bad:#f85149; }
  * { box-sizing:border-box; }
  body { margin:0; font:15px/1.5 system-ui,sans-serif; background:var(--bg); color:var(--fg); }
  header { display:flex; align-items:center; justify-content:space-between;
           padding:14px 20px; background:#131a21; border-bottom:1px solid #232c36; }
  header h1 { font-size:18px; margin:0; font-weight:600; }
  .pill { font-size:12px; padding:4px 10px; border-radius:999px; background:#232c36; color:var(--muted); }
  .pill.on { background:rgba(63,185,80,.15); color:var(--ok); }
  main { max-width:760px; margin:0 auto; padding:18px; display:grid; gap:16px; }
  .card { background:var(--card); border:1px solid #232c36; border-radius:10px; padding:16px; }
  .card h2 { margin:0 0 12px; font-size:13px; letter-spacing:.08em; text-transform:uppercase; color:var(--muted); }
  .grid { display:grid; grid-template-columns:140px 1fr; gap:6px 12px; font-size:14px; }
  .grid .k { color:var(--muted); }
  label.station { display:flex; align-items:center; gap:10px; padding:8px 10px; border:1px solid #2a333d;
                  border-radius:8px; margin-bottom:6px; cursor:pointer; }
  label.station:hover { border-color:var(--accent); }
  label.station .freq { margin-left:auto; color:var(--muted); font-variant-numeric:tabular-nums; }
  input[type=number], input[type=text] { background:#0f1419; border:1px solid #2a333d; color:var(--fg);
                  border-radius:6px; padding:6px 8px; font:inherit; }
  button { background:var(--accent); color:#04101f; border:0; border-radius:6px; padding:8px 14px;
           font:inherit; font-weight:600; cursor:pointer; }
  button.secondary { background:#2a333d; color:var(--fg); }
  button.danger { background:var(--bad); color:#1a0000; }
  button:disabled { opacity:.45; cursor:not-allowed; }
  .row { display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
  .row.end { justify-content:flex-end; margin-top:10px; }
  pre { background:#0b0f14; border:1px solid #232c36; border-radius:8px; padding:10px;
        overflow:auto; font-size:12px; max-height:260px; }
  details summary { cursor:pointer; color:var(--muted); }
  .toast { position:fixed; bottom:16px; left:50%; transform:translateX(-50%); background:#232c36;
           padding:10px 16px; border-radius:8px; opacity:0; transition:opacity .2s; pointer-events:none; }
  .toast.show { opacity:1; }
  .muted { color:var(--muted); }
</style>
</head>
<body>
<header>
  <h1>txtempus &middot; time-signal transmitter</h1>
  <span id="txpill" class="pill">—</span>
</header>
<main>
  <section class="card">
    <h2>Status <button class="secondary" style="float:right;padding:2px 8px" onclick="refresh()">&#x21bb;</button></h2>
    <div class="grid">
      <div class="k">State</div><div id="st-state">…</div>
      <div class="k">Will set watch to</div><div id="st-settime">…</div>
      <div class="k">DST signal</div><div id="st-dst">…</div>
      <div class="k">Next run</div><div id="st-next">…</div>
      <div class="k">Last run</div><div id="st-last">…</div>
      <div class="k">System time</div><div id="st-time">…</div>
      <div class="k">NTP</div><div id="st-ntp">…</div>
      <div class="k">CPU temp</div><div id="st-temp">…</div>
    </div>
  </section>

  <section class="card">
    <h2>Station / region</h2>
    <div id="stations"></div>
    <div class="row end"><button onclick="saveStation()">Save station</button></div>
  </section>

  <section class="card">
    <h2>Transmit now</h2>
    <div class="row">
      Duration <input id="dur" type="number" min="1" max="120" value="10" style="width:70px"> min
      <label class="muted"><input id="dry" type="checkbox"> dry-run (no RF)</label>
    </div>
    <div class="row end">
      <button onclick="txStart()">&#9658; Start</button>
      <button class="danger" onclick="txStop()">&#9632; Stop</button>
    </div>
  </section>

  <section class="card">
    <h2>Schedule</h2>
    <div id="sched-summary" class="muted" style="font-size:13px;margin-bottom:10px">…</div>
    <div class="row">
      <label><input id="sched-on" type="checkbox"> enabled</label>
    </div>
    <div class="row" style="margin-top:8px">
      Broadcast at <input id="sched-times" type="text" value="01:59,02:59,03:59" style="flex:1;min-width:180px">
    </div>
    <div class="muted" style="font-size:12px;margin-top:4px">
      Comma-separated HH:MM (24h), Pi local time. These are when the Pi <i>starts</i>
      broadcasting (for the duration above) — set them a minute or two before your
      watch's own check time so the window brackets it. Default brackets 2 AM &amp; 3 AM.
    </div>
    <div class="row end"><button onclick="saveSchedule()">Save schedule</button></div>
  </section>

  <section class="card">
    <h2>Watch sync helper</h2>
    <div class="muted" style="font-size:13px;margin-bottom:8px">
      A radio watch listens at <i>its own</i> clock's time (often 2 AM) — and that
      drifts when it can't receive, so its "2 AM" may not be the real 2 AM. Enter
      what your watch shows right now to see how far off it is.
    </div>
    <div class="row">
      My watch shows <input id="watch-time" type="time" step="60">
      <button class="secondary" onclick="calcDrift()">Check drift</button>
    </div>
    <div id="drift-out" style="margin-top:10px"></div>
  </section>

  <section class="card">
    <h2>Watch guide</h2>
    <div class="row">
      Your watch
      <select id="watch-select" onchange="renderWatch()" style="flex:1;min-width:200px">
        <option value="">— choose your model —</option>
      </select>
    </div>
    <div id="watch-guide" style="margin-top:10px"></div>
    <div class="muted" style="font-size:12px;margin-top:8px">
      Don't see yours? Add it to <code>/etc/txtempus-watches.json</code> — no code change needed.
    </div>
  </section>

  <details class="card">
    <summary>Advanced</summary>
    <div class="row" style="margin-top:12px">
      Zone offset <input id="zone" type="number" value="0" style="width:80px"> min
      <button class="secondary" onclick="saveZone()">Save</button>
    </div>
    <div class="row" style="margin-top:12px">
      <button class="secondary" id="preview-btn" onclick="preview()">Preview modulation</button>
      <span class="muted" id="preview-note"></span>
    </div>
    <pre id="preview-out" style="display:none"></pre>
    <div class="row" style="margin-top:12px">
      PIN (if set) <input id="pin" type="password" style="width:120px" placeholder="optional">
    </div>
  </details>
</main>
<div id="toast" class="toast"></div>

<script>
const $ = id => document.getElementById(id);
let transmitting = false, pollTimer = null;

function toast(msg) {
  const t = $("toast"); t.textContent = msg; t.classList.add("show");
  setTimeout(() => t.classList.remove("show"), 2200);
}
function pinHeaders() {
  const p = $("pin").value;
  return p ? {"X-Txtempus-Pin": p, "Content-Type":"application/json"} : {"Content-Type":"application/json"};
}
async function postJSON(url, body) {
  const r = await fetch(url, {method:"POST", headers:pinHeaders(), body:JSON.stringify(body||{})});
  let j = {}; try { j = await r.json(); } catch(e){}
  if (!r.ok) { toast(j.error || ("error " + r.status)); throw new Error(j.error||r.status); }
  return j;
}

function fmtTime(s){ if(!s) return "—"; try { return new Date(s).toLocaleString(); } catch(e){ return s; } }

function renderStations(stations, current) {
  const box = $("stations"); box.innerHTML = "";
  for (const [name, meta] of Object.entries(stations)) {
    const id = "stn-"+name;
    const lab = document.createElement("label"); lab.className = "station";
    const exp = meta.experimental ? ` <span style="color:var(--warn);font-size:11px">experimental</span>` : "";
    lab.innerHTML = `<input type="radio" name="station" id="${id}" value="${name}" ${name===current?"checked":""}>
                     <b>${name}</b> <span>${meta.region}</span>${exp}
                     <span class="freq">${(meta.carrier_hz/1000).toFixed(meta.carrier_hz%1000?1:0)} kHz</span>`;
    box.appendChild(lab);
  }
}
function selectedStation(){ const el = document.querySelector("input[name=station]:checked"); return el?el.value:null; }

async function refresh() {
  let s; try { s = await (await fetch("/api/status")).json(); } catch(e){ return; }
  window.lastStatus = s;
  transmitting = s.transmitting;
  $("txpill").textContent = transmitting ? "● TX ACTIVE" : "idle";
  $("txpill").className = "pill" + (transmitting ? " on" : "");
  let state = transmitting
    ? `Transmitting (${s.station}, ${(s.carrier_hz/1000)} kHz)`
    : "Idle";
  $("st-state").textContent = state;
  const t = s.transmitted || {};
  $("st-settime").textContent = t.time
    ? `${t.weekday} ${t.date} ${t.time} (${t.basis}${t.zone_offset_min ? ", offset "+t.zone_offset_min+" min" : ""})`
    : "—";
  $("st-dst").textContent = t.dst_text || "—";
  $("st-next").textContent = s.next_scheduled || (s.schedule_enabled ? "—" : "disabled");
  $("st-last").textContent = s.last_run ? `${fmtTime(s.last_run.at)} → ${s.last_run.result} (${s.last_run.duration}m)` : "—";
  $("st-time").textContent = fmtTime(s.system_time);
  $("st-ntp").textContent = s.ntp_synchronized===null ? "unknown" : (s.ntp_synchronized ? "✔ synced" : "✘ not synced");
  $("st-temp").textContent = s.cpu_temp_c===null ? "n/a" : (s.cpu_temp_c + " °C");
  // Schedule summary line.
  const times = (s.schedule_times||[]).join(", ") || "none set";
  $("sched-summary").innerHTML = s.schedule_enabled
    ? `<b style="color:var(--ok)">Enabled</b> — broadcasting at <b>${times}</b>.`
      + (s.next_scheduled ? ` Next run: <b>${s.next_scheduled}</b>.` : "")
    : `<b style="color:var(--warn)">Disabled</b> — no automatic broadcasts (saved times: ${times}).`;
  // Keep the preview button out of the RT window.
  $("preview-btn").disabled = transmitting;
  $("preview-note").textContent = transmitting ? "disabled while transmitting" : "";
  // Back off polling during a broadcast.
  scheduleNextPoll(transmitting ? 10000 : 4000);
}

function calcDrift(){
  const v = $("watch-time").value, out = $("drift-out");
  if (!v){ out.textContent = "Enter the time your watch shows."; return; }
  const s = window.lastStatus;
  if (!s || !s.system_time){ out.textContent = "No status yet — try again in a moment."; return; }
  const now = new Date(s.system_time);
  const [wh, wm] = v.split(":").map(Number);
  let diff = (wh*60+wm) - (now.getHours()*60 + now.getMinutes());   // minutes: watch - real
  if (diff > 720) diff -= 1440;
  if (diff < -720) diff += 1440;
  const mag = Math.abs(diff);
  if (mag <= 1){
    out.innerHTML = `<span style="color:var(--ok)">Your watch is accurate</span> — within 1 min of the Pi.`;
    return;
  }
  const dir = diff > 0 ? "fast" : "slow";
  let real = (((120 - diff) % 1440) + 1440) % 1440;   // watch 02:00 happens at real (02:00 - drift)
  const hh = String(Math.floor(real/60)).padStart(2,"0"), mm = String(real%60).padStart(2,"0");
  out.innerHTML = `Your watch is <b>${mag} min ${dir}</b> versus the Pi. `
    + `If it checks at its own 02:00, that is about real time <b>${hh}:${mm}</b>. `
    + `Tip: press <b>Start</b> (Transmit now) to sync it immediately if your watch has a manual-receive, `
    + `or it will resync at the next scheduled window once it drifts within range.`;
}
function scheduleNextPoll(ms){ clearTimeout(pollTimer); pollTimer = setTimeout(refresh, ms); }

async function loadConfig() {
  const c = await (await fetch("/api/config")).json();
  renderStations(c.stations, c.station);
  $("dur").value = c.run_duration;
  $("zone").value = c.zone_offset;
  $("sched-on").checked = c.schedule_enabled;
  $("sched-times").value = (c.schedule_times||[]).join(",");
}

async function saveStation(){ const st=selectedStation(); if(!st) return;
  await postJSON("/api/config", {station:st}); toast("Station saved: "+st); refresh(); }
async function saveZone(){ await postJSON("/api/config", {zone_offset:parseInt($("zone").value||"0")}); toast("Saved"); }
async function txStart(){
  await postJSON("/api/transmit/start",
    {station:selectedStation(), minutes:parseInt($("dur").value||"10"), dryrun:$("dry").checked});
  toast($("dry").checked ? "Dry-run (see Advanced › Preview)" : "Transmit started"); setTimeout(refresh, 600);
}
async function txStop(){ await postJSON("/api/transmit/stop", {}); toast("Stopped"); setTimeout(refresh, 600); }
async function saveSchedule(){
  await postJSON("/api/schedule",
    {enabled:$("sched-on").checked, times:$("sched-times").value, duration:parseInt($("dur").value||"10")});
  toast("Schedule saved"); refresh();
}
async function preview(){
  const st = selectedStation(); const out = $("preview-out");
  try {
    const j = await (await fetch("/api/preview?station="+encodeURIComponent(st))).json();
    if (j.error){ toast(j.error); return; }
    out.style.display="block"; out.textContent = j.envelope;
  } catch(e){ toast("preview failed"); }
}

async function loadWatches(){
  try { window.watches = (await (await fetch("/api/watches")).json()).watches || []; }
  catch(e){ window.watches = []; }
  const sel = $("watch-select");
  window.watches.forEach((w, i) => {
    const o = document.createElement("option");
    o.value = i; o.textContent = `${w.brand} ${w.model}`;
    sel.appendChild(o);
  });
}
function renderWatch(){
  const idx = $("watch-select").value, out = $("watch-guide");
  if (idx === "" || !window.watches){ out.innerHTML = ""; return; }
  const w = window.watches[idx];
  const cur = selectedStation();
  const chips = w.stations.map(s => {
    const ok = s === cur;
    return `<span style="display:inline-block;padding:1px 7px;margin:0 4px 4px 0;border-radius:999px;`
      + `background:${ok?'rgba(63,185,80,.18)':'#2a333d'};color:${ok?'var(--ok)':'var(--fg)'}">${s}</span>`;
  }).join("");
  const supported = w.stations.includes(cur);
  let html = `<div style="margin-bottom:6px">Receives: ${chips}</div>`;
  html += `<div class="muted" style="margin-bottom:6px">Your current broadcast <b>${cur}</b>: `
    + (supported ? `<span style="color:var(--ok)">supported &#10003;</span>`
                 : `<span style="color:var(--bad)">not received by this watch — pick a station it supports</span>`)
    + `</div>`;
  if (w.sync_times && w.sync_times.length)
    html += `<div class="muted" style="margin-bottom:6px">Typical auto-sync (watch's own time): ${w.sync_times.join(", ")}</div>`;
  if (w.setup && w.setup.length)
    html += "<ol style='margin:8px 0 0 18px;padding:0'>" + w.setup.map(s => `<li style="margin-bottom:4px">${s}</li>`).join("") + "</ol>";
  if (w.notes) html += `<div class="muted" style="margin-top:8px">${w.notes}</div>`;
  out.innerHTML = html;
}
// Re-render the watch guide when the chosen station changes (updates the ✓/✗).
$("stations").addEventListener("change", () => { if ($("watch-select").value !== "") renderWatch(); });

loadConfig().then(refresh);
loadWatches();
</script>
</body>
</html>
"""


def main():
    conf = read_conf()
    bind = os.environ.get("TXTEMPUS_WEB_BIND") or conf.get("WEB_BIND", "0.0.0.0")
    try:
        port = int(os.environ.get("TXTEMPUS_WEB_PORT") or conf.get("WEB_PORT", "8080"))
    except ValueError:
        port = 8080
    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    print(f"txtempus-web listening on http://{bind}:{port}/  (conf: {CONF_PATH})", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
