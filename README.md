# txtempus — radio time-station transmitter & Raspberry Pi appliance

> Bring a radio-controlled clock or watch back to life where it can't hear its time station.

[![build](https://github.com/tunlezah/dcf77/actions/workflows/build.yml/badge.svg)](https://github.com/tunlezah/dcf77/actions/workflows/build.yml)

**txtempus** takes the (NTP-disciplined) system clock of a Raspberry Pi and
generates a low-frequency, amplitude-modulated carrier on a GPIO pin.
Magnetically coupled through a small wire loop held a few centimetres away, that
signal sets [DCF77], [WWVB], [MSF], [JJY] and [BPC] clocks and watches — useful
when a radio-controlled timepiece is out of range of its real transmitter (for
example a European DCF77 watch used outside Europe).

This fork packages the original command-line transmitter into a small,
config-driven **appliance** for a Raspberry Pi Zero W on a home LAN:

- a single config file (`/etc/txtempus.conf`),
- a `systemd` scheduler that broadcasts for a few minutes at night,
- a tiny **web UI** to pick the station/region, transmit on demand, edit the
  schedule, watch a live transmit status, see the time/DST being sent, and read
  a per-model **watch guide**,
- an idempotent installer/uninstaller, encoder **tests**, and **CI** that
  cross-compiles for ARM.

> ⚠️ **Before you transmit, make sure you follow your local laws on radio
> transmissions.** The coupling here is intentionally very weak (a few cm range)
> to set a nearby watch without causing interference — but the responsibility is
> yours.

This is a fork of Henner Zeller's [hzeller/txtempus]; all credit for the core
transmitter and protocol work is his (see [Credits](#credits)).

---

## Table of contents

- [Features](#features)
- [Supported time services](#supported-time-services)
- [How it works](#how-it-works)
- [Hardware](#hardware)
- [Build](#build)
- [Run (command line)](#run-command-line)
- [Appliance: config, scheduler & install](#appliance-config-scheduler--install)
- [Web interface](#web-interface)
- [Watch guide (modular)](#watch-guide-modular)
- [Tests](#tests)
- [Continuous integration](#continuous-integration)
- [Project documentation](#project-documentation)
- [Limitations & platform notes](#limitations--platform-notes)
- [Credits](#credits)
- [License](#license)

---

## Features

- **Five longwave time stations across four regions** — DCF77, WWVB, MSF, JJY
  (40/60 kHz) and an experimental BPC, each a self-contained encoder.
- **Accurate carrier synthesis** straight off the Pi's general-purpose clock,
  with second-aligned amplitude modulation under a real-time scheduler.
- **Root-free dry-run** (`-n`) that prints the modulation envelope as ASCII —
  great for understanding a protocol and the basis of the test suite.
- **Set-and-forget appliance layer:** one config file, a `systemd` nightly
  scheduler with NTP discipline and CPU-temperature monitoring, plus an
  idempotent, upgrade-safe installer.
- **Live, low-power web UI** for a Pi Zero W — pick the station, transmit on
  demand, edit the schedule, and watch an auto-refreshing transmit status.
- **Modular, data-driven watch guide** you extend by editing a JSON file.
- **Tests and CI** — golden encoder regressions, a BPC self-test, host build and
  a 32-bit ARM cross-compile on every push.

## Supported time services

| Service | Region | Carrier | CLI | Notes |
|---|---|---|---|---|
| **DCF77** | Germany / Europe | **77.5 kHz** | `-s DCF77` | Pi synthesises ~77500.003 Hz |
| **WWVB** | USA | **60 kHz** | `-s WWVB` | Transmitted in UTC |
| **MSF** | United Kingdom | **60 kHz** | `-s MSF` | On-off keyed (no attenuation pin needed) |
| **JJY** | Japan | **40 / 60 kHz** | `-s JJY40` / `-s JJY60` | Two transmitters exist |
| **BPC** ⚠️ | China | **68.5 kHz** | `-s BPC` | **Experimental** — see below |

Each is a self-contained `TimeSignalSource` subclass (carrier frequency + a
per-second amplitude-modulation pattern), so adding a station doesn't touch the
others.

**BPC is experimental.** It uses *quaternary* pulse-width modulation (each
second the carrier is reduced for 100/200/300/400 ms to encode a 2-bit symbol;
a 20-second frame is sent three times per minute). The carrier and modulation
mechanism are implemented and visible with `-n`, but BPC's exact field/bit
layout is reverse-engineered — the mapping in `src/bpc-source.cc` is a tentative
best-effort that has not been verified against a real receiver. If you have a
BPC-capable clock (e.g. a Citizen Skyhawk set to a Chinese city, or a Casio
Multi-Band 6), please test and report.

## How it works

Each station broadcasts the time as one (or two) bits per second by briefly
**reducing the carrier amplitude** (or, for MSF, switching it off). Over a
minute the bits carry the full date/time as BCD with parity; the receiver waits
for the minute marker, then decodes. Most stations transmit the data for the
*upcoming* minute and switch over on the minute boundary.

txtempus reproduces this by synthesising the carrier on the Pi's general-purpose
clock output and toggling a second GPIO to attenuate it on schedule, aligned to
real second boundaries under a real-time scheduler (`SCHED_FIFO`). Keep the Pi's
clock accurate with `ntpd`/`chrony` (the included scheduler nudges NTP before
each run).

## Hardware

> txtempus targets the **Raspberry Pi** (the Pi Zero W is the recommended
> appliance target). See [Limitations & platform notes](#limitations--platform-notes)
> for the headless/HDMI caveat and unsupported models.

Three resistors — 2×4.7 kΩ and 1×560 Ω (precision not critical) — wired to
**GPIO4** (carrier) and **GPIO17** (attenuation):

Schematic                      | Real world
-------------------------------|------------------------------
![](img/schematic-dcf77.png)   |![](img/contacts-dcf77.jpg)

GPIO4 and GPIO17 are on the inner row of the header, three pins in. Wire a loop
of wire (≈10–20 turns) between the open end of one 4.7 kΩ and ground — this is
the coupling coil. Bring it within a few centimetres of the watch/clock antenna.

![](img/watch-wired.jpg)

Being *too* close can confuse a sensitive receiver, so experiment with distance;
if it won't receive, add more turns to the coil. For **MSF** you don't need
GPIO17 or the 560 Ω resistor (it's on-off keyed) — a single 10 kΩ in place of the
two 4.7 kΩ works. BPC uses the same wiring as DCF77.

## Build

```sh
sudo apt-get install git build-essential cmake -y
git clone https://github.com/tunlezah/dcf77.git
cd dcf77
mkdir build && cd build
cmake ../          # or: cmake ../ -DPLATFORM=rpi
make
sudo make install  # installs /usr/bin/txtempus
```

## Run (command line)

```sh
sudo ./txtempus -v -s DCF77        # transmit current time as DCF77 (needs root)
./txtempus -n -s WWVB              # dry-run: print the modulation envelope (no root, any machine)
sudo ./txtempus -s DCF77 -r 10     # run for 10 minutes, then stop
```

```
usage: ./txtempus [options]
Options:
        -s <service>          : Service; one of 'DCF77', 'WWVB', 'JJY40', 'JJY60', 'MSF', 'BPC'
        -r <minutes>          : Run for a limited number of minutes. (default: no limit)
        -t 'YYYY-MM-DD HH:MM' : Transmit the given local time (default: now)
        -z <minutes>          : Offset the transmitted time from local (default: 0)
        -v                    : Verbose.
        -n                    : Dry-run: only show the modulation envelope.
        -f                    : Force run on unsupported hardware (e.g. Pi 4); carrier may be wrong.
        -h                    : This help.
```

The dry-run (`-n`) renders each second of the minute as ASCII — `_` is low
(reduced) carrier, `#` is high — which is great for understanding a protocol and
is what the tests use:

```
$ ./txtempus -n -s wwvb
2018-08-17 13:22:00 -> tx-modulation
:00 [________##]
:01 [__########]
:02 [_____#####]
  ... and so on for the whole minute ...
```

## Appliance: config, scheduler & install

For a set-and-forget device, install the appliance layer:

```sh
sudo make install            # the binary, if you haven't already
sudo ./deploy/install.sh
```

`install.sh` is **idempotent / upgrade-safe**: run from anywhere, it stops a
running install, installs the files below, migrates an existing schedule, and
warns about leftover txtempus **cron** entries (`--purge-cron` removes them). It
installs:

- **`/etc/txtempus.conf`** — the single source of truth (station, run duration,
  zone offset, nightly schedule, web bind/port/PIN), shell-sourceable
  `KEY=VALUE`, read by both the scheduler and the web UI. An existing config is
  **never overwritten**, so your settings survive upgrades.
- **systemd units** — `txtempus-scheduler.{service,timer}` (nightly runs at the
  times in `SCHEDULE_TIMES`), `txtempus-oneshot.service` (on-demand transmit,
  `Type=simple` so it reports "transmitting now" honestly and stops cleanly),
  and `txtempus-web.service` (the web UI, run at idle priority so it never
  preempts the real-time transmit loop).
- **`txtempus-scheduler.sh`** — the nightly runner: nudges NTP, monitors CPU
  temperature, runs the binary for `RUN_DURATION`, records the last result.
- **`txtempus-control.sh`** — the small privileged shim the web UI drives (the
  only state-changing surface: start/stop and schedule management).

Typical setup: a Pi Zero W keeps its clock disciplined with `ntpd`/`chrony`, and
the timer transmits for ~10 minutes a few times a night (default 01:59 / 02:59 /
03:59) — right before a watch does its nightly receive.

```sh
systemctl list-timers txtempus-scheduler.timer    # when will it run?
journalctl -u txtempus-scheduler.service -f        # what happened?
sudo ./deploy/uninstall.sh                          # remove (add --purge to drop config too)
```

Prefer plain cron? A manual alternative:

```crontab
57 1,2  * * *  root  /usr/bin/txtempus -s DCF77 -r 10
```

## Web interface

A tiny, dependency-free **Python-stdlib** sidecar (`web/txtempus-web.py`) serves
one page plus a small JSON API on a trusted LAN. It is built for a Pi Zero W:
~0 % idle CPU, a few MB RAM, no extra packages, no build step. It **never
transmits itself** — it only writes the config and asks systemd (via
`txtempus-control.sh`) to (re)start the binary, staying out of the real-time
transmit window.

After `install.sh`, open **`http://<your-pi>:8080/`**.

### Live, low-power status

The status panel **auto-refreshes** — it no longer updates only when you click:

- The **browser ticks the clock and any countdowns locally every second**, so
  the display stays live with **no extra server load**.
- The page only fetches `/api/status` **occasionally**: roughly **every 60 s when
  idle** and **every 15 s while transmitting**.
- Polling **pauses while the browser tab is hidden** and resumes (with an
  immediate refresh) when you return to it.
- The server **caches the (subprocess-heavy) status for a couple of seconds**, so
  multiple open tabs or bursts of polls can't overload the Pi Zero W.

It clearly shows whether a transmission is actually happening — a live, pulsing
**TX ACTIVE** indicator — with a live **countdown of how long the current
broadcast will run**, plus the **next scheduled run** shown both as an absolute
time and a relative "in Xh Ym" countdown. A manual refresh button is still there
if you want an immediate, forced update.

```
┌───────────────────────────────────────────────────────────────────────┐
│  txtempus · time-signal transmitter                    [● TX ACTIVE ⟳] │
├───────────────────────────────────────────────────────────────────────┤
│  STATUS    State: Transmitting (DCF77, 77.5 kHz) · ends in 7m 41s        │
│            Will set watch to: Sun 2026-06-07 02:03 (local)              │
│            DST signal: CEST (central European summer time)               │
│            Next run: 2026-06-08 01:59 (in 23h 56m) · NTP ✔ · CPU 48.7 °C │
│            ─ auto-refreshing every 15s · last updated 3s ago ─           │
├───────────────────────────────────────────────────────────────────────┤
│  STATION ( ) DCF77 — Germany/Europe 77.5 kHz   ( ) WWVB — USA 60 kHz ... │
│  TRANSMIT NOW  Duration [10] min  [▶ Start] [■ Stop]                     │
│  SCHEDULE  [x] enabled  Broadcast at [01:59,02:59,03:59]                 │
│  WATCH GUIDE  [ Citizen Skyhawk A-T (U680) ▾ ]                           │
└───────────────────────────────────────────────────────────────────────┘
```

The rest of the page lets you:

- **pick the station / region** (DCF77 / WWVB / MSF / JJY40 / JJY60 / BPC),
- **transmit now / stop** for a chosen duration,
- **edit the nightly schedule**, with the saved times and the live next run shown,
- see **what time the watch will be set to** (local for DCF77/MSF/JJY, UTC for
  WWVB, plus any zone offset) and the **DST signal** being sent (CET/CEST,
  GMT/BST; JJY/BPC have no DST),
- use the **watch-sync drift helper**: type what your watch currently shows and
  it tells you how far it has drifted (so you can tell whether its "2 AM" check
  is really 2 AM),
- read the **watch guide** for your model (see below),
- **preview** a station's modulation (the `-n` chart), disabled while
  transmitting to keep that CPU work out of the real-time window.

**Security (LAN-only, deliberately light):** the UI is meant for a private
network. It runs as root by default for simplicity; set an optional `WEB_PIN` in
the config to gate changes. To harden, run it as a non-root user with a narrow
sudo grant to `txtempus-control.sh` — see the comments in
`deploy/systemd/txtempus-web.service`. Don't expose it to the open internet.

## Watch guide (modular)

The web UI's **watch guide** shows, for a chosen model, which stations it
receives (checked against your current broadcast), when it auto-syncs, and the
basic setup steps. It's **data-driven** — entries live in
`/etc/txtempus-watches.json` (seeded with the Citizen Skyhawk A-T (U680), Casio
Multi-Band 6, Junghans Mega, and a generic DCF77 clock). **Add your own watch by
editing that JSON — no code change required.**

## Tests

A golden-output test exercises every station's encoder through the `-n` dry-run
(no root, no Pi) and compares against committed expected envelopes, and a BPC
self-test round-trips the BPC envelope back to time fields:

```sh
cmake -S . -B build && cmake --build build
test/run-golden.sh            # PASS/FAIL per station
test/run-golden.sh --update   # regenerate expected output after an intentional change
python3 test/bpc_selftest.py  # BPC encoder round-trip (time, parity, frames, markers)
```

The BPC self-test verifies the encoder is internally consistent (bit-packing,
framing, parity, markers, pulse widths); it does **not** prove conformance to the
real BPC broadcast format.

## Continuous integration

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on every
push/PR:

- **Build & test (host):** builds, then runs the golden encoder tests and the
  BPC self-test.
- **Cross-compile (32-bit ARM / Raspberry Pi):** installs
  `g++-arm-linux-gnueabihf` and builds, confirming the code compiles for the
  Pi's ARM target.

## Project documentation

Deeper write-ups live alongside the code:

- [`summary.md`](summary.md) — architecture and what the project does.
- [`todo.md`](todo.md) — review: what works, what's flawed, prioritised fixes.
- [`future.md`](future.md) — prior art and a roadmap of possible additions.
- [`web.md`](web.md) — the full design behind the web interface.

## Limitations & platform notes

- **Run headless on the Pi.** The internal oscillator that can be used for the
  carrier is shared with HDMI; connecting a monitor changes it and the
  transmission fails.
- **Raspberry Pi 4 (BCM2711) is not supported** — frequency generation doesn't
  work there, so txtempus refuses to run on a Pi 4 unless you pass `-f` (the
  carrier may be wrong). Use an older Pi (the Pi Zero W is the recommended
  target). Pull requests welcome.
- Keep the Pi's clock **NTP-disciplined** (`ntpd`/`chrony`); the appliance
  scheduler nudges NTP before each run, but accurate time is on you.
- These protocols also carry bits for DST-change *announcements*, leap seconds
  and (on some stations) phase modulation, which are not generated. Consumer
  clocks are generally fine without them — the current DST state *is* sent.

<hr/>

**tx** _common telecommunication abbreviation for 'transmit'_<br/>
**tempus**, n _Latin. Time; period; age_

## Credits

- Original project and all core transmitter/protocol work:
  **Henner Zeller** — [hzeller/txtempus].
- This repository ([tunlezah/dcf77](https://github.com/tunlezah/dcf77)) adds the
  appliance layer (config, systemd, idempotent installer), the web UI, the BPC
  station, the modular watch guide, the tests and the CI.

## License

Licensed under the **GNU General Public License** — see [`COPYING`](COPYING).

[DCF77]: https://en.wikipedia.org/wiki/DCF77
[WWVB]: https://en.wikipedia.org/wiki/WWVB
[MSF]: https://en.wikipedia.org/wiki/Time_from_NPL_(MSF)
[JJY]: https://en.wikipedia.org/wiki/JJY
[BPC]: https://en.wikipedia.org/wiki/BPC_(time_signal)
[NTP]: https://en.wikipedia.org/wiki/Network_Time_Protocol
[hzeller/txtempus]: https://github.com/hzeller/txtempus
