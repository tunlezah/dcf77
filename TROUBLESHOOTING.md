# Troubleshooting & diagnostics

A console cheat-sheet for checking what the txtempus appliance is actually doing,
so you can diagnose problems yourself on the Pi.

> **Important: the appliance runs on a `systemd` timer, not cron.** The schedule
> you set in the web UI is stored in `/etc/txtempus.conf` and turned into a timer
> drop-in — so `crontab -l` will normally show *nothing*, and that's expected.
> Cron only matters if you deliberately used the manual cron alternative, or have
> leftover entries from an old setup (see [§3](#3-actual-cron-only-if-you-used-it--to-find-leftovers)).

## Contents
- [0. First check: is the binary actually installed?](#0-first-check-is-the-binary-actually-installed)
- [1. Is it transmitting right now?](#1-is-it-transmitting-right-now)
- [2. The schedule (the "cron" equivalent)](#2-the-schedule-the-cron-equivalent)
- [3. Actual cron (only if you used it / to find leftovers)](#3-actual-cron-only-if-you-used-it--to-find-leftovers)
- [4. What happened last / live logs](#4-what-happened-last--live-logs)
- [5. The current configuration](#5-the-current-configuration-source-of-truth)
- [6. Health: clock & temperature](#6-health-clock--temperature)
- [7. The web UI itself](#7-the-web-ui-itself)
- [8. Test a transmission yourself](#8-test-a-transmission-yourself-bypassing-the-schedule)
- [Quickest "why isn't it working?" sequence](#quickest-why-isnt-it-working-sequence)
- [What gets installed where](#what-gets-installed-where)

---

## 0. First check: is the binary actually installed?

The most common failure is the transmitter binary not being present. Everything
else (the schedule, the web UI, the control script) is installed by
`deploy/install.sh`, but they all *exec* `/usr/bin/txtempus` — if it isn't there,
the logs show:

```
error spawning txtempus: No such file or directory
```

Check it:

```sh
command -v txtempus            # should print /usr/bin/txtempus
ls -l /usr/bin/txtempus        # should exist and be executable
/usr/bin/txtempus -n -s DCF77  # dry-run; prints the ASCII modulation if it works
```

**If it's missing, build and install it (then the units work immediately):**

```sh
cd /path/to/dcf77
cmake -S . -B build && cmake --build build
sudo install -m 0755 build/txtempus /usr/bin/txtempus
# …or just re-run the installer, which now builds/installs the binary for you:
sudo ./deploy/install.sh
```

> The binary lives in `/usr/bin/` (from `make install` / the installer), while the
> helper scripts and web UI live in `/usr/local/bin/`. That split is intentional —
> see [What gets installed where](#what-gets-installed-where).

## 1. Is it transmitting right now?

```sh
# The two units that actually transmit:
systemctl is-active txtempus-oneshot.service     # "active" = on-demand TX running
systemctl is-active txtempus-scheduler.service   # "active" = scheduled TX running
systemctl status   txtempus-oneshot.service txtempus-scheduler.service

# Or just look for the process + its exact arguments:
pgrep -a txtempus            # e.g. 1234 /usr/bin/txtempus -s DCF77 -r 10 -z 0
```

`pgrep -a txtempus` is the single best **"what is actually being run"** check — it
prints the real command line, including the station, duration (`-r`) and zone
offset (`-z`) in force.

## 2. The schedule (the "cron" equivalent)

```sh
# When will it next fire, and when did it last?
systemctl list-timers txtempus-scheduler.timer

# Is the timer actually enabled/active?
systemctl is-enabled txtempus-scheduler.timer
systemctl is-active  txtempus-scheduler.timer

# The exact times it will run (generated from SCHEDULE_TIMES in the config):
cat /etc/systemd/system/txtempus-scheduler.timer.d/schedule.conf
systemctl cat txtempus-scheduler.timer       # full effective timer (base + drop-in)
```

If `list-timers` shows nothing or `n/a`, the timer is disabled — which matches
`SCHEDULE_ENABLED=false` in the config.

## 3. Actual cron (only if you used it / to find leftovers)

```sh
crontab -l 2>/dev/null | grep -i txtempus                 # root's crontab
grep -rsi txtempus /etc/crontab /etc/cron.d /etc/cron.*   # system cron
```

The installer warns about these because they would double-broadcast alongside the
timer. Remove them with `sudo ./deploy/install.sh --purge-cron`.

## 4. What happened last / live logs

```sh
# Result of the most recent scheduled run (written by the scheduler script):
cat /run/txtempus/last-run        # at=… station=… duration=… result=… exit=…

# Full history via the journal:
journalctl -u txtempus-scheduler.service -n 50 --no-pager   # scheduled runs
journalctl -u txtempus-oneshot.service   -n 50 --no-pager   # on-demand runs
journalctl -u txtempus-scheduler.service -f                 # follow live

# The scheduler's own log files + the CPU-temp log sampled during transmits:
tail -n 50 /var/log/txtempus-scheduler.log
tail -n 50 /var/log/txtempus-temp.log
```

Note: `/run/...` is a tmpfs, so `last-run` and the PID files reset on reboot —
that's normal.

## 5. The current configuration (source of truth)

```sh
cat /etc/txtempus.conf            # STATION, RUN_DURATION, ZONE_OFFSET, SCHEDULE_TIMES, …
cat /run/txtempus/oneshot.env     # per-run overrides the web UI wrote for the last "Start" (if any)
```

## 6. Health: clock & temperature

Accurate time is critical — a radio clock will only accept a correct signal.

```sh
timedatectl                                  # is NTP active & synchronized?
timedatectl show -p NTPSynchronized --value  # just "yes"/"no"
awk '{printf "%.1f°C\n", $1/1000}' /sys/class/thermal/thermal_zone0/temp   # CPU temp
```

## 7. The web UI itself

```sh
systemctl status txtempus-web.service
journalctl -u txtempus-web.service -n 30 --no-pager
ss -ltnp | grep ':8080'           # confirm it's listening on the expected port
curl -s http://localhost:8080/api/status | python3 -m json.tool   # the exact JSON the page shows
```

## 8. Test a transmission yourself (bypassing the schedule)

First confirm the binary is installed (see [§0](#0-first-check-is-the-binary-actually-installed)) —
`command -v txtempus` should print `/usr/bin/txtempus`. Then:

```sh
/usr/bin/txtempus -n -s DCF77             # dry-run: prints the ASCII modulation, no root, no RF
sudo /usr/bin/txtempus -v -s DCF77 -r 1   # real 1-minute transmit with verbose output

# Drive it exactly like the web UI does (the only privileged surface):
sudo /usr/local/bin/txtempus-control.sh start DCF77 1 0   # station, minutes, zone
sudo /usr/local/bin/txtempus-control.sh stop
sudo /usr/local/bin/txtempus-control.sh apply-schedule    # rebuild the timer from the config
```

---

## Quickest "why isn't it working?" sequence

```sh
command -v txtempus                                         # is the binary installed at all? (§0)
systemctl list-timers txtempus-scheduler.timer              # will it run, and when?
timedatectl                                                 # is the clock NTP-synced?
cat /run/txtempus/last-run                                  # did the last run succeed?
journalctl -u txtempus-scheduler.service -n 30 --no-pager   # why it failed, if it did
pgrep -a txtempus                                           # is something transmitting now?
```

## What gets installed where

| Path | What it is |
|---|---|
| `/usr/bin/txtempus` | the transmitter binary (`make install`) |
| `/etc/txtempus.conf` | single source of truth (station, duration, zone, schedule, web bind/port/PIN) |
| `/etc/txtempus-watches.json` | modular watch-guide database (kept across upgrades) |
| `/usr/local/bin/txtempus-scheduler.sh` | nightly runner (NTP nudge, temp monitor, runs the binary) |
| `/usr/local/bin/txtempus-control.sh` | the privileged shim the web UI drives (start/stop/schedule) |
| `/usr/local/bin/txtempus-web.py` | the web admin UI |
| `/etc/systemd/system/txtempus-scheduler.{service,timer}` | the nightly schedule |
| `/etc/systemd/system/txtempus-scheduler.timer.d/schedule.conf` | generated `OnCalendar=` times |
| `/etc/systemd/system/txtempus-oneshot.service` | on-demand transmit |
| `/etc/systemd/system/txtempus-web.service` | the web UI service |
| `/run/txtempus/last-run` | result of the most recent scheduled run (tmpfs) |
| `/run/txtempus/oneshot.env` | per-run overrides from the web UI (tmpfs) |
| `/var/log/txtempus-scheduler.log`, `/var/log/txtempus-temp.log` | logs (rotated by `/etc/logrotate.d/txtempus`) |
