# txtempus — Project Summary

> Foundational analysis of this repository. Other planning docs (`todo.md`,
> `future.md`, `web.md`) build on this. Written for a deployment target of a
> **Raspberry Pi Zero W**, on a **LAN** (security is not a primary concern),
> where **device power/CPU is the main constraint**.

---

## 1. What this project is

**txtempus** is a low-frequency (LF) **radio time-signal transmitter**. It takes
the (NTP-disciplined) system clock of a Raspberry Pi (or Nvidia Jetson) and
generates an **amplitude-modulated longwave carrier** on a GPIO pin. Magnetically
coupled through a small wire loop, that signal sets **radio-controlled clocks and
watches** that are out of range of a real time station (e.g. a European DCF77
watch used outside Europe).

- Upstream project: `hzeller/txtempus` (this repo, `tunlezah/dcf77`, is a fork).
- License: **GNU GPL** (v2/v3 — headers vary per file; `COPYING` is GPLv3).
- Language: **C++14**, built with **CMake**.
- Author: Henner Zeller; Jetson port by Jueon Park.
- Coupling is intentionally very weak (a few centimetres range) to act as a
  local re-transmitter without causing interference. **Users are responsible for
  local radio-transmission regulations** (stated repeatedly in the README).

---

## 2. How it works (concept)

Each supported station broadcasts the time as **one (or two) bits per second**,
encoded by **briefly reducing the carrier amplitude** (or switching it off). Over
one minute, ~59 bits carry the full date/time as BCD with parity. Receivers wait
for the special **minute marker** (second 59 / second 0) and then decode.

txtempus reproduces this by:
1. Synthesising the **carrier frequency** on a GPIO clock output.
2. **Modulating** its amplitude each second according to the station's protocol
   (pulling the level down via a second GPIO + resistor divider, or, for MSF,
   switching the carrier off entirely / on-off keying).

The program transmits the **upcoming** minute's data and aligns transitions to
real-second boundaries using absolute-time sleeps under a real-time scheduler.

---

## 3. Supported time services

| Service | Region | Carrier | Modulation style | CLI value | Notes |
|---|---|---|---|---|---|
| **DCF77** | Germany / Europe | **77.5 kHz** | Amplitude reduction; 100 ms = `0`, 200 ms = `1`; sec 59 = no reduction (minute mark) | `DCF77` | Pi synthesises 77500.003 Hz (close enough) |
| **WWVB** | USA | **60 kHz** | Reduction; 200 ms = `0`, 500 ms = `1`, 800 ms = marker | `WWVB` | Transmitted in **UTC** |
| **MSF** | UK | **60 kHz** | **On-off keying** (carrier off); 2 bits/sec (A & B bits) | `MSF` | No attenuation pin/resistor needed |
| **JJY** (40) | Japan | **40 kHz** | Like WWVB but **inverted** power; 800 ms = `0`, 500 ms = `1`, 200 ms = marker | `JJY40` | |
| **JJY** (60) | Japan | **60 kHz** | Same as JJY40 | `JJY60` | Two real JJY transmitters exist |

**Not modelled (documented limitations):** DST-change announcement bits, leap
seconds, phase modulation (real stations phase-modulate; txtempus does AM only),
and some service-announcement minutes.

---

## 4. Architecture

Clean separation between **protocol encoding** (portable) and **hardware/GPIO**
(platform-specific via the *pimpl* idiom).

```
                 ┌──────────────────────────────────────────┐
                 │              txtempus.cc (main)            │
                 │  - parse CLI options                       │
                 │  - SCHED_FIFO realtime priority            │
                 │  - per-minute / per-second transmit loop   │
                 │  - dry-run ASCII modulation chart          │
                 └───────────────┬──────────────┬────────────┘
                                 │              │
              ┌──────────────────▼───┐   ┌──────▼─────────────────────┐
              │   TimeSignalSource    │   │      HardwareControl        │
              │ (abstract, per-station)│   │  (pimpl → platform impl)   │
              │  GetCarrierFrequencyHz │   │  Init / StartClock / Stop  │
              │  PrepareMinute(t)      │   │  EnableClockOutput         │
              │  GetModulationForSecond│   │  SetTxPower(OFF/LOW/HIGH)  │
              └───────────────────────┘   └──────┬──────────────┬──────┘
               DCF77 / WWVB / JJY / MSF          │              │
                                          ┌──────▼──────┐  ┌────▼─────────┐
                                          │  rpi-control │  │ jetson impl  │
                                          │ (BCM mmap +  │  │ (JetsonGPIO  │
                                          │  GPCLK + GPIO)│  │  PWM)        │
                                          └──────────────┘  └──────────────┘
```

### Key abstractions
- **`TimeSignalSource`** (`include/time-signal-source.h`): abstract base.
  - `GetCarrierFrequencyHz()` — carrier in Hz.
  - `PrepareMinute(time_t)` — called once per minute; computes the 59/60 bit
    pattern (BCD + parity). Most sources add `+60 s` because the data describes
    the *upcoming* minute.
  - `GetModulationForSecond(int second)` — returns a `vector<ModulationDuration>`
    (a list of `{CarrierPower, duration_ms}` transitions; last with `0` ms
    auto-fills to the end of the second).
- **`CarrierPower`** (`include/carrier-power.h`): `enum class {OFF, LOW, HIGH}`.
- **`HardwareControl`** (`include/hardware-control.h`): platform-agnostic façade,
  forwards to a `HardwareControl::Implementation` (pimpl). Adding a platform =
  add `include/<plat>/hardware-control-implementation.h` + `cmake/<plat>-control.cmake`
  + register in `CMakeLists.txt`.

---

## 5. File-by-file breakdown

### Core / portable
- **`src/txtempus.cc`** (~228 lines) — entry point.
  - Options: `-s` service, `-r` minutes-to-run, `-t 'YYYY-MM-DD HH:MM'` test time,
    `-z` minute offset, `-v` verbose, `-n` dry-run, `-h` help.
  - `TruncateTo(now, 60)` aligns to a full minute.
  - Sets **`SCHED_FIFO`, priority 99** for sleep accuracy.
  - Loop: for each minute → `PrepareMinute`; for each second → `clock_nanosleep`
    (`CLOCK_REALTIME`, `TIMER_ABSTIME`) to the boundary, then apply each
    modulation transition.
  - `-n` dry-run renders the per-second envelope as `_`/`#` ASCII (no root, runs
    off-Pi — great for understanding/validating protocols).
- **`include/time-signal-source.h`** — base class + concrete class declarations
  (`DCF77…`, `WWVB…`, `JJY…`/`JJY40`/`JJY60`, `MSF…`).
- **`src/dcf77-source.cc`** — DCF77 encoding. Little-endian bits (bit 0 sent
  first). DST flags (bits 17/18), start bit (20), minute/hour/day/weekday/month/
  year in BCD, parity bits (28, 35, 58). Sec ≥ 59 → no attenuation (minute mark).
- **`src/wwvb-source.cc`** — WWVB. Big-endian (bit 59 first), **UTC**, padded
  BCD, leap-year bit, DST bits (today/tomorrow). Markers at sec 0 and every
  `sec%10==9`.
- **`src/jjy-source.cc`** — JJY (shared `JJYTimeSignalSource`, freq set by
  `JJY40`/`JJY60` subclasses). Padded BCD + parity (PA1/PA2). Inverted power
  relative to WWVB. Service-announcement minutes (15/45) deliberately ignored.
- **`src/msf-source.cc`** — MSF. **On-off keying** (`CarrierPower::OFF`). Two bit
  streams `a_bits_`/`b_bits_`. Sec 0 = 500 ms off marker. Each other sec = 100 ms
  off + A-bit + B-bit (100 ms each) + on. Odd-parity helpers.
- **`src/hardware-control.cc`** — thin pimpl forwarders.

### Platform: Raspberry Pi
- **`include/rpi/hardware-control-implementation.h`** — GPIO register pointers,
  `kValidBits` (GPIO header pins), `kAttenuationGPIOBit`.
- **`src/rpi-control.cc`** — the heart of the Pi port:
  - mmaps BCM peripheral registers; auto-detects Pi model from
    `/proc/cpuinfo` Revision → chooses peripheral base
    (BCM2708 / BCM2709 / BCM2711).
  - **Carrier** via the General-Purpose Clock **GPCLK0 on GPIO4** (clock manager
    `CM_GP0CTL/DIV`). Chooses the best source among **PLLC (1000 MHz), PLLD
    (500 MHz), HDMI (216 MHz), oscillator (19.2 MHz)** with an integer +
    fractional (**MASH=1**) divider to minimise frequency error.
  - **Attenuation** via **GPIO17** (`1<<17`): drive low (pull-down through the
    resistor divider) for `LOW`; switch to input/high-Z for `HIGH`; disable clock
    output for `OFF`.
  - Known caveat: the **HDMI clock source (216 MHz) shifts if a monitor is
    connected** → wrong carrier; run **headless**. **Pi 4 (BCM2711) does not
    work** (registers differ).

### Platform: Nvidia Jetson (experimental)
- **`include/jetson/hardware-control-implementation.h`** — uses **JetsonGPIO**
  `GPIO::PWM` (50% duty) for the carrier and a separate attenuation pin
  (board-numbered pins vary by model; TX1/TX2 unsupported — no usable PWM pin).
- **`cmake/jetson-control.cmake`** — `find_package(JetsonGPIO)`.

### Build system
- **`CMakeLists.txt`** — C++14, `-Wall -O3`, exports `compile_commands.json`,
  installs to `/usr/bin`. **Platform select** via `-DPLATFORM=rpi|jetson`
  (default `rpi`); includes `cmake/<platform>-control.cmake`.
- **`cmake/rpi-control.cmake`** — adds `src/rpi-control.cc`.

### Fork-specific additions (NOT in upstream) — deployment/automation
> These live under `build/` (which is otherwise generated output — organisationally odd).
- **`build/txtempus-scheduler.sh`** — Bash wrapper that:
  - requires root; validates the binary;
  - **syncs NTP** (tries `timedatectl` → `ntpdate` → `chronyd`);
  - runs `txtempus -s dcf77 -r 20` in the background;
  - **monitors CPU temperature** every 30 s (warns > 70 °C) to a temp log;
  - manages PID files, timeouts, cleanup traps, logging.
  - ⚠️ **Hardcodes** `TXTEMPUS_PATH=/home/mark/txtempus/build/txtempus` (a
    user-specific path, and points at the *build* tree, not the installed
    `/usr/bin/txtempus`).
- **`build/txtempus-systemd-setup.sh`** — installs a **systemd service + timer**
  (oneshot service runs the scheduler; timer fires **01:59 / 02:59 / 03:59**
  daily, `Persistent=true`, `AccuracySec=1s`) plus a **logrotate** config. Must
  run as root.

### Other
- `img/` — schematics and photos used by the README.
- `COPYING` — GPLv3 text.
- **Entire `build/` directory is committed to git** (object files, `a.out`,
  `compile_commands.json`, the compiled `txtempus` binary, CMake cache). There is
  **no `.gitignore`**. Git history is a single commit ("Add files via upload").

---

## 6. Runtime / usage

```
sudo ./txtempus -v -s DCF77            # transmit current time as DCF77
./txtempus -n -s WWVB                  # dry-run: print modulation envelope (no root)
sudo ./txtempus -s DCF77 -r 10         # run for 10 minutes then stop
sudo ./txtempus -s JJY60 -t '2024-01-01 09:00' -z 60   # test time + offset
```

Typical real-world deployment (from README + fork scripts):
- Pi Zero W runs `ntpd`/`chrony`, keeping system time within ~±50 ms of atomic.
- A **cron** line *or* the **systemd timer** runs txtempus for a few minutes,
  a few times per night, when the watch/clock checks for a signal.

---

## 7. Hardware (minimal)

- **Raspberry Pi:** 2 × 4.7 kΩ + 1 × 560 Ω resistors. **GPIO4** = carrier,
  **GPIO17** = attenuation pull-down. A wire loop (≈10–20 turns) between the
  4.7 kΩ and ground forms the coupling coil; place within a few cm of the
  clock/watch. **MSF** needs no attenuation pin/560 Ω (on-off keyed) — a single
  10 kΩ suffices.
- **Jetson:** as above plus an NPN transistor; PWM/attenuation pins vary by model.

---

## 8. Deployment-target constraints (important for downstream docs)

The intended device is a **Raspberry Pi Zero W**:
- **Single-core ARMv6 @ 1 GHz, 512 MB RAM** — very limited; heavyweight runtimes
  (Node, big Python frameworks, containers) are a poor fit.
- The transmit loop runs at **`SCHED_FIFO` priority 99** (hard real-time). On a
  single core, **any concurrent CPU work during a transmit window can disturb
  timing** — but transmit windows are short (minutes) and infrequent (nightly).
  A web/admin UI should ideally do its heavy lifting *outside* those windows.
- **LAN-only, security not a primary concern** — but it is still wise to bind to
  the LAN interface and keep the surface small; no need for auth/TLS complexity.
- Must run **headless** (HDMI clock-source caveat).
- The whole appliance should be **lightweight, resilient to power loss, and
  config-driven** (NTP for time; persisted settings for station/schedule).

---

## 9. Quick capability / gap snapshot

**Works / strengths**
- Clean, well-factored protocol layer; easy to add stations or platforms.
- Five station variants across four regions.
- Accurate timing approach (realtime sched + absolute sleeps).
- Excellent `-n` dry-run for understanding/validating protocols offline.
- Fork adds real-world automation (NTP sync, scheduling, thermal monitoring).

**Gaps / smells (expanded in `todo.md`)**
- Committed `build/` artifacts + binary; no `.gitignore`.
- Scheduler hardcodes a user path and the wrong (build-tree) binary location.
- No config file — everything is CLI flags / hardcoded in scripts.
- **No remote/web interface** (the entire point of `web.md`): station selection,
  schedule, and on-demand transmit are CLI/cron only.
- Pi 4 unsupported; HDMI-source headless caveat; no DST/leap/phase modelling.
- No tests, no CI.
- README still references the upstream `hzeller` repo for cloning.
```
