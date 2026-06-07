# txtempus — Future Directions / Roadmap

> Forward-looking ideas document for this fork (`tunlezah/dcf77`). Read
> [`summary.md`](summary.md) first for the foundational analysis of what the
> project *is* and how it is built. The deployment target assumed throughout is a
> **Raspberry Pi Zero W** (single-core ARMv6, 512 MB RAM) on a **LAN**, where
> **device CPU/power is the main constraint**. The web/admin UI is covered
> separately in `web.md`, so this document keeps web-UI specifics light and
> concentrates on **capabilities, protocols, reliability and packaging**.
>
> Every recommendation is anchored to the existing architecture: the
> `TimeSignalSource` abstraction (`include/time-signal-source.h`), the
> `HardwareControl` *pimpl* (`include/hardware-control.h`), and the CMake
> platform-select (`CMakeLists.txt` + `cmake/<platform>-control.cmake`).

---

## 1. Landscape / prior art

txtempus is the best-known LF time-signal *transmitter* (most projects are
*receivers/decoders*). The transmitter niche is small, which makes the
comparison set tractable. The table below is what comparable projects do that
this fork does **not**.

| Project | Platform | Stations | Notable features txtempus lacks | Source |
|---|---|---|---|---|
| **hzeller/txtempus** (upstream) | Pi, Jetson | DCF77, WWVB, JJY40/60, MSF | The baseline. Open issues request BPC, TDF, multi-signal, Pi-Zero-2/Pi-4 support (see below) | [github.com/hzeller/txtempus](https://github.com/hzeller/txtempus) |
| **harlock974/time-signal** | Pi 3 / **Pi 4** / Zero W | DCF77, WWVB, JJY40/60, MSF | **Pi 4 support** (BCM2711 base + 54 MHz xtal), **carrier-only test mode**, **no attenuation pin** (pure on-off keying), single-file C + Makefile (no CMake) | [github.com/harlock974/time-signal](https://github.com/harlock974/time-signal), [clock-control.c](https://github.com/harlock974/time-signal/blob/main/clock-control.c) |
| **SensorsIot/DCF77-Transmitter-for-ESP32** | ESP32 | DCF77 | Microcontroller (no Linux/root), **tuned ferrite antenna ~3 m range**, web/serial config, low idle power | [github.com/SensorsIot/DCF77-Transmitter-for-ESP32](https://github.com/SensorsIot/DCF77-Transmitter-for-ESP32) |
| **ORelio/DCF77-Transmitter** | ESP8266 | DCF77 | **POSIX-TZ timezone string**, periodic **NTP re-sync interval**, **deep-sleep / intermittent TX windows**, **status LED**, temperature-drift correction, "ready-to-use" manual | [github.com/ORelio/DCF77-Transmitter](https://github.com/ORelio/DCF77-Transmitter) |
| **mdaskalov/esp32-dcf77-transmitter** | ESP32 | DCF77 | Uses ESP32 LEDC/PWM peripheral for 77.5 kHz; NTP-synced | [github.com/mdaskalov/esp32-dcf77-transmitter](https://github.com/mdaskalov/esp32-dcf77-transmitter) |
| **luigicalligaris/dcfake77** | ESP32/ESP8266 | DCF77 | Cross-MCU; ORelio notes its protocol has accuracy gaps (a cautionary tale for testing) | [github.com/luigicalligaris/dcfake77](https://github.com/luigicalligaris/dcfake77) |
| **tarohs/nisejjy** | ESP32 | JJY | Dedicated "fake JJY" appliance | [github.com/tarohs/nisejjy](https://github.com/tarohs/nisejjy) |
| **GOTO-GOSUB/Antenna-Amplifiers** | (HW companion to txtempus) | — | A menu of **antenna amplifier circuits** to extend range, explicitly designed for txtempus | [github.com/GOTO-GOSUB/Antenna-Amplifiers](https://github.com/GOTO-GOSUB/Antenna-Amplifiers) |
| **SensorsIoT "Remote controller for clocks"** | Pi + web | DCF77/WWVB/MSF/JJY | Builds a **web dashboard** on top of txtempus (overlaps `web.md`) | [sensorsiot.org](https://www.sensorsiot.org/remote-controller-for-clocks-ikea-and-others-dcf77-wwvb-msf-jjy/) |
| **txtempus upstream issue #42** | Pi + HAT | — | A community-built **dedicated HAT + web dashboard** for txtempus | [issue #42](https://github.com/hzeller/txtempus/issues/42) |

### What the upstream issue tracker is asking for

The clearest signal of demand is hzeller's own open issues (verified June 2026):

- **#35 — Add BPC (China) support** ([link](https://github.com/hzeller/txtempus/issues/35))
- **#24 — Add ALS162 / TDF (France, 162 kHz)** ([link](https://github.com/hzeller/txtempus/issues/24))
- **#40 — Emit multiple signal types from one setup** (switch station per schedule) ([link](https://github.com/hzeller/txtempus/issues/40))
- **#20 — Leap-second handling bug** at the minute transition ([link](https://github.com/hzeller/txtempus/issues/20))
- **#34 — Remove the attenuation pin** (pure on-off keying; field-tested OK) ([link](https://github.com/hzeller/txtempus/issues/34))
- **#28 — DCF77 weather/Meteotime protocol bits** ([link](https://github.com/hzeller/txtempus/issues/28))
- **#36 — Pi Zero 2 W support?** ([link](https://github.com/hzeller/txtempus/issues/36))
- **#17 — Time-zone handling** (also linked from the README) ([link](https://github.com/hzeller/txtempus/issues/17))

The recurring themes — **more stations, multi-station scheduling, timezone
correctness, newer-Pi support, simpler hardware** — line up closely with the
gaps already noted in `summary.md §9`, and shape the roadmap in §3.

---

## 2. Candidate additions

Organised into themes. **Difficulty** is a rough engineering estimate (S/M/L/XL).
**Pi-Zero-W fit** rates how well the idea respects the low-power, single-core,
headless, real-time constraint.

### 2.1 More stations / standards

New stations are the cleanest fit for the architecture: most are just a new
`TimeSignalSource` subclass (a `GetCarrierFrequencyHz()`, a `PrepareMinute()`
bit-packer, and a `GetModulationForSecond()`), plus one line in
`CreateTimeSourceFromName()` in `src/txtempus.cc` and one entry in `usage()`. No
hardware-layer change is needed **as long as the modulation is amplitude
reduction / on-off keying** of a single carrier — which is the crux of the
feasibility split below.

| Station | Carrier | Scheme | Fits current AM model? | Difficulty | Pi-Zero-W fit | Notes & source |
|---|---|---|---|---|---|---|
| **BPC (China)** | 68.5 kHz | AM, −10 dB, **2 bits/sec**, **20-second frames** (3 frames/min) | **Yes** (amplitude reduction, same as DCF77/WWVB) | **M** | Excellent | Most-requested missing station (#35). Frame repeats every 20 s; needs a `PrepareMinute` that lays out 3 sub-frames and a `GetModulationForSecond` keyed on `second % 20`. Carrier 68.5 kHz is well within GPCLK range. Caveat: **the official frame format is not openly published / licensed**, but the bit layout has been reverse-engineered by the community. [Wikipedia: BPC](https://en.wikipedia.org/wiki/BPC_(time_signal)), [libdriver/bpc decoder](https://github.com/libdriver/bpc), [SigID: BPC](https://www.sigidwiki.com/wiki/BPC) |
| **MSF carrier-error fix / second stations** | — | — | — | S | — | (Not a new station, but worth folding in: MSF/JJY/WWVB all already share the AM path.) |
| **TDF / ALS162 (France)** | 162 kHz | **Phase modulation** (±1 rad, doubled = "1"); also AM for legacy radio | **No** — PM not AM | **XL** | Poor | Requested (#24). The time code is phase-modulated, which the current GPCLK amplitude path **cannot produce**. Would need a fundamentally different carrier-generation strategy (see §2.5 phase modulation) and 162 kHz is at the edge of the dividers. Low value for the use case (very few clocks need a *transmitted* ALS162). [Wikipedia: ALS162](https://en.wikipedia.org/wiki/TDF_time_signal) |
| **RBU (Russia)** | 66.66 kHz | **Sub-carrier tone keying** (100 Hz = 0, 312.5 Hz = 1), 1 bit/100 ms | **No** — tone-modulated, not simple AM | **XL** | Poor | Requires audio-rate sub-carrier modulation of the LF carrier; not an amplitude on/off pattern. Niche. [Wikipedia: RBU](https://en.wikipedia.org/wiki/RBU_(radio_station)) |
| **RTZ (Russia, Irkutsk)** | 50 kHz | Similar to RBU | **No** | XL | Poor | Same objection as RBU. [Wikipedia: RTZ](https://en.wikipedia.org/wiki/RTZ_(radio_station)) |
| **HBG (Switzerland)** | 75 kHz | AM (DCF77-like) | Yes (if it mattered) | — | — | **Decommissioned in 2011** — include only as a historical/educational mode if ever. [mgk25 LF clocks list](https://www.cl.cam.ac.uk/~mgk25/time/lf-clocks/) |

**Takeaway:** **BPC is the one clearly worth doing** — it is amplitude-modulated,
the most-requested gap, and slots straight into the existing `TimeSignalSource`
model. TDF, RBU and RTZ all need modulation schemes the current hardware layer
does not support and serve a tiny audience; treat them as non-goals (see §3).

### 2.2 Protocol completeness (existing stations)

These make the *already-supported* stations more spec-faithful. All are edits to
the relevant `src/*-source.cc` only — **zero hardware impact, negligible CPU**,
and naturally testable via the `-n` dry-run (see §2.4).

| Feature | What it is | Difficulty | Pi-Zero-W fit | Notes |
|---|---|---|---|---|
| **DCF77 DST-change announcement (bit 16, A1)** | Set "1" during the hour before a CET↔CEST switch | **S** | Excellent | `summary.md §3` lists this as unmodelled. Compute by comparing `tm_isdst` of *now* vs *+1 h*. Some watches show a "DST pending" indicator. [DCF77 time code, PTB](https://www.ptb.de/cms/en/ptb/fachabteilungen/abt4/fb-44/ag-442/dissemination-of-legal-time/dcf77/dcf77-time-code.html), [Wikipedia: DCF77](https://en.wikipedia.org/wiki/DCF77) |
| **DCF77 leap-second announcement (bit 19, A2)** | Set "1" for the hour before an inserted leap second | **S** | Excellent | Pairs with the leap-second handling fix below. |
| **Leap-second handling (the 61-second minute)** | `GetModulationForSecond` already documents `second` may reach 60; the loop in `txtempus.cc` is hard-coded to `second < 60`. Upstream **#20** reports the upcoming-minute logic breaks across a leap second | **M** | Excellent | Rare (a handful of times per decade) but a real correctness bug. Fix: make the per-minute second-count a property of the source / detect the leap minute. [issue #20](https://github.com/hzeller/txtempus/issues/20) |
| **WWVB DST/leap bits audit** | WWVB already sets DST today/tomorrow + leap-year; verify leap-second + DUT1 sign bits | **S** | Excellent | Mostly a correctness pass on `src/wwvb-source.cc`. |
| **MSF DUT1 + summer-time-warning bits** | `src/msf-source.cc` explicitly leaves DUT1 and the 53rd-second STW bit unset | **S** | Excellent | Set the STW bit symmetrically with DCF77's A1. |
| **JJY service-announcement minutes (15 & 45)** | `src/jjy-source.cc` deliberately skips the call-sign/Morse + interruption-notice format sent in minutes 15 and 45 | **M** | Good | Real JJY sends a different frame those minutes; most consumer clocks ignore it, so low priority, but it is a known shortcut. |
| **Timezone / locale correctness (#17)** | Today the time shown is *system local time* plus a raw `-z` minute offset; there is no first-class "transmit station X's home timezone regardless of Pi timezone" | **M** | Excellent | High real-world value: a DCF77 watch used in the US should show CET. Best done with a `TZ`/POSIX-tz override applied around the `localtime_r` calls in each source (or set `TZ` in `PrepareMinute`). Ties into config (§2.3). [issue #17](https://github.com/hzeller/txtempus/issues/17) |
| **DCF77 phase modulation (PRN)** | Real DCF77 superimposes a 512-chip pseudo-random phase modulation (±~13°, 9-bit LFSR) for high-precision PZF receivers | **XL** | Poor | The GPCLK amplitude path cannot phase-modulate the carrier; needs a different generation approach (§2.5). **Consumer clocks ignore it entirely** — explicitly out of scope. [DCF77 phase modulation, PTB](https://www.ptb.de/cms/en/ptb/fachabteilungen/abt4/fb-44/ag-442/dissemination-of-legal-time/dcf77/dcf77-phase-modulation.html) |
| **DCF77 weather / Meteotime bits (1–14)** (#28) | The first 14 bits carry Meteotime weather + civil-warning data | **XL (effectively N/A)** | N/A | **Encrypted** (a modified 40-bit DES; S-/P-boxes undocumented and license-locked) and the payload is *external commercial data*, not derivable from a clock. Not a sensible transmitter feature. [MeteoDecode](https://github.com/ottojo/MeteoDecode), [issue #28](https://github.com/hzeller/txtempus/issues/28) |

### 2.3 Reliability & ops (the appliance layer)

This is where the fork already started (the `build/` scheduler scripts) and where
the biggest quality-of-life wins are for an unattended nightstand appliance.

| Feature | What it is | Difficulty | Pi-Zero-W fit | Notes |
|---|---|---|---|---|
| **Config-file support** | A small `/etc/txtempus.conf` (key=value or TOML/INI) for service, schedule, timezone, run-duration, GPIO pins | **S–M** | Excellent | `summary.md §9` flags "no config file — everything is CLI flags / hardcoded." Parse in `main()` and let CLI flags override. Underpins multi-station scheduling and the web UI. Keep the parser tiny (no heavy deps) for ARMv6. |
| **Multi-station scheduling (#40)** | One daemon that transmits station A in one window and station B in another (e.g. JJY at 02:00, DCF77 at 03:00) | **M** | Excellent | The hardware emits one carrier at a time, so this is *time-division*, not simultaneous. Most naturally a schedule table in the config + restarting the carrier per window; the `TimeSignalSource` factory already makes switching trivial. Replaces the brittle per-station cron lines. [issue #40](https://github.com/hzeller/txtempus/issues/40) |
| **Fix & generalise the fork's scheduler scripts** | `build/txtempus-scheduler.sh` hardcodes `/home/mark/...` and points at the *build-tree* binary, not `/usr/bin/txtempus` | **S** | Excellent | Called out in `summary.md §5`/§9. Read paths from config; default to the installed binary. Also move these scripts out of the committed `build/` dir. |
| **Status / heartbeat LED** | Drive a GPIO LED: solid = carrier on, blink = transmitting bits, off = idle | **S** | Excellent | Mirrors ORelio's ESP8266 status LED. Slots into `HardwareControl` (a `SetStatusLed()` alongside `SetTxPower`), or a second attenuation-style GPIO. Great for a headless box with no screen. [ORelio](https://github.com/ORelio/DCF77-Transmitter) |
| **NTP-readiness gate** | Refuse to transmit (or warn loudly) if the clock is not NTP-synchronised — transmitting a *wrong* time is worse than transmitting nothing | **S** | Excellent | Check `adjtimex`/`ntp_adjtime` sync status, or `timedatectl` `NTPSynchronized`. The fork's script only *attempts* a sync; it never *verifies* one. |
| **Observability / metrics & heartbeat log** | Structured log line per transmit session (station, start, duration, achieved carrier Hz, sync status); optional tiny Prometheus textfile or a `/run` status file | **S–M** | Good | Keep it file-based/pull, not a always-on HTTP exporter, to avoid background CPU during transmit windows. The achieved-vs-requested frequency (already computed in `StartClock`) is a perfect health metric. |
| **Thermal/throttle awareness in-process** | The fork polls `/sys/.../thermal_zone0` from bash; fold a light check into the daemon and optionally back off | **S** | Good | Pi Zero W rarely overheats from this workload, but reusing the existing idea in-process removes a moving part. |
| **Graceful carrier teardown on all exits** | Ensure `StopClock()` runs on SIGTERM/SIGINT/crash so the GPIO isn't left clocking | **S** | Excellent | `main()` already handles SIGTERM/SIGINT for the loop; double-check the clock is always killed (RAII guard around `HardwareControl`). |

### 2.4 Build / test / packaging

The project today has **no tests, no CI, a committed `build/` tree, no
`.gitignore`, and a README that still points at upstream** (`summary.md §9`).
These are low-glamour, high-leverage, and (crucially) **run off-Pi**, so they cost
the Pi Zero W nothing.

| Item | What it is | Difficulty | Pi-Zero-W fit | Notes |
|---|---|---|---|---|
| **Golden tests for the bit encoders** | The `-n` dry-run prints a deterministic ASCII modulation envelope for a fixed `-t` time. Capture known-good output per station and diff in CI | **S** | N/A (host/CI) | This is the single highest-value test investment. It locks down DCF77/WWVB/JJY/MSF (and future BPC/DST/leap edits) against regressions, exactly the kind of protocol bug that bit dcfake77. The `-t` + `-z` flags already make output reproducible. |
| **Unit tests for helpers** | `to_bcd`, `to_padded5_bcd`, `parity`/`odd_parity`, leap-year, the DST/leap announcement logic | **S** | N/A | Pure functions, trivially testable; pair with the golden tests. |
| **CI (GitHub Actions)** | Build for `-DPLATFORM=rpi` and `jetson`; cross-compile / build the host-only dry-run; run the golden + unit tests; lint | **S–M** | N/A | Cross-compiling the Pi target with an ARM toolchain in CI catches breakage without hardware. |
| **`.gitignore` + purge committed build artifacts** | Remove the checked-in `build/` (object files, `a.out`, the compiled binary, CMake cache) | **S** | N/A | `summary.md §5` flags this. Relocate the genuinely-useful scheduler/systemd scripts to e.g. `dist/` or `packaging/`. |
| **Proper systemd packaging** | A real `txtempus.service` + `txtempus.timer` (the fork has setup *scripts*; ship the units as data, parameterised by the config file) | **S–M** | Excellent | Cleaner than the current "script that writes units." `Persistent=true` already used; keep `AccuracySec` tight so the timer fires on schedule. |
| **Debian package (`.deb`)** | `dpkg-buildpackage` producing a package that installs the binary to `/usr/bin`, the systemd units, a default `/etc/txtempus.conf`, and logrotate config | **M** | Excellent | Ideal distribution for an appliance: `apt install`, enable the timer, done. CMake already targets `/usr` and uses `GNUInstallDirs`. |
| **README/maintenance hygiene** | Update clone URL to this fork; document the config file, new stations, and the headless caveat prominently | **S** | N/A | `summary.md §9`: README still references `hzeller` for cloning. |

### 2.5 Hardware / signal

| Item | What it is | Difficulty | Pi-Zero-W fit | Notes |
|---|---|---|---|---|
| **Pure on-off-keying mode (drop the attenuation pin) (#34)** | Add a build/config option (or per-station default) that uses `CarrierPower::OFF` instead of `LOW`, removing GPIO17 + the 560 Ω resistor | **S** | Excellent | Field-tested by harlock974 on a Casio G-Shock at ~10 m with a MOSFET driver; **real receivers tolerate OOK** because it is a *larger* amplitude swing. Simplifies hardware to match MSF's single-resistor setup for *all* stations. Implement as an alternate `SetTxPower` mapping or a `--ook` flag. [issue #34](https://github.com/hzeller/txtempus/issues/34) |
| **Alternate clock-source selection (fix the HDMI caveat)** | Let the user pin the carrier to a stable source (e.g. force the 19.2/54 MHz oscillator, never HDMI) so a connected monitor doesn't shift the frequency | **M** | Excellent | The README/`summary.md` headless caveat is *because* `StartClock` may pick the 216 MHz HDMI source, which drifts when a display attaches. A `--clock-source`/config option that excludes HDMI (or prefers PLLC/PLLD/oscillator) removes the "must run headless" footgun. The source list already lives in `kClockSources[]` in `src/rpi-control.cc`. [README "very wrong frequency"](https://github.com/hzeller/txtempus/issues/1) |
| **Raspberry Pi 4 support (BCM2711)** | The current code prints "known not to work on Pi4." harlock974 gets Pi 4 working by using the **BCM2711 base (0xFE000000)** and a **54 MHz crystal** (vs 19.2 MHz) in the clock-source table | **M** | Good (Pi 4 is fine power-wise; just not the *target*) | Mostly a `src/rpi-control.cc` change: correct base (already `#define`d), and add the 54 MHz oscillator entry conditional on `PI_MODEL_4`. Worth doing for project reach even though the deployment target is the Zero W. [harlock974 clock-control.c](https://github.com/harlock974/time-signal/blob/main/clock-control.c) |
| **Raspberry Pi 5 support (RP1)** | Pi 5 moves GPIO/clocks to the **RP1** southbridge; the old `/dev/mem` BCM clock-manager mmap does **not** apply (driver is `rp1-clk`, not `bcm2711-cprman`) | **L** | N/A (target is Zero W) | A genuinely new `HardwareControl::Implementation` (a `cmake/rpi5-control.cmake` + `include/rpi5/...`), likely via the RP1 registers or a device-tree/`pinctrl` overlay. The pimpl design makes this a clean *additional* platform rather than a rewrite, but it is real work. [Pi forums: RPI5 GPCLK0](https://forums.raspberrypi.com/viewtopic.php?t=365761), [pinout.xyz GPCLK](https://pinout.xyz/pinout/gpclk) |
| **Pi Zero 2 W validation (#36)** | The Zero 2 W is BCM2710 (Pi-3-class); code already maps revision `0x12` to `PI_MODEL_2` | **S** | Excellent | Likely already works; just needs testing + a documented "supported" note. [issue #36](https://github.com/hzeller/txtempus/issues/36) |
| **Antenna improvements (tuned LC / ferrite / amplifier)** | Document/ship better coupling: a tuned LC tank at the carrier freq, a ferrite rod, or a small MOSFET amp for more range | **S (docs) / M (HW)** | Excellent (no extra MCU load) | Strictly a hardware/doc effort with big UX payoff (range from "few cm" to several metres). Reference the existing companion project rather than reinventing. **Must foreground local RF-emission legality.** [GOTO-GOSUB/Antenna-Amplifiers](https://github.com/GOTO-GOSUB/Antenna-Amplifiers), [SensorsIot ferrite ~3 m](https://github.com/SensorsIot/DCF77-Transmitter-for-ESP32) |

### 2.6 Genuinely novel ideas that fit the appliance

| Idea | Why it fits | Difficulty | Pi-Zero-W fit |
|---|---|---|---|
| **"Sync now" one-shot trigger** | A button-GPIO or a single command/endpoint that fires a short transmit burst on demand (e.g. when you put a freshly-reset watch on the stand at noon) instead of waiting for the nightly window | S–M | Excellent |
| **Auto station detection by Pi locale/timezone** | On first run, default the station from the system timezone (Europe→DCF77, US→WWVB, JP→JJY, UK→MSF) to make the appliance zero-config | S | Excellent |
| **Self-test / "loopback" confidence check** | Use the existing `-n` engine plus a frequency-counter read-back (or just report achieved-vs-requested Hz) as a built-in `--selftest` that confirms the carrier is within tolerance before a real run | S | Excellent |
| **Per-station "force value" test vectors** | Extend `-t` so QA/automation can drive corner cases (leap day, DST boundary, year rollover) — directly feeds the golden tests in §2.4 | S | N/A |

---

## 3. Suggested roadmap

### Do first — high value, low cost, respects the Pi Zero W

These are cheap, mostly off-Pi or zero-CPU-cost at runtime, and fix real
pain/correctness gaps:

1. **Golden tests for the `-n` dry-run + a `.gitignore` + purge `build/`.**
   Foundational; makes every later protocol change safe. Pure host/CI cost.
   (§2.4)
2. **Config file + fix/relocate the fork's scheduler & systemd assets.**
   Removes the hardcoded `/home/mark` path and the wrong binary location; unlocks
   scheduling and the web UI. (§2.3, §2.4)
3. **Multi-station time-division scheduling (#40)** on top of that config.
   High demand, trivial given the existing factory. (§2.3)
4. **Timezone correctness (#17).** High real-world value for out-of-region
   clocks; small code change in the sources. (§2.2)
5. **DCF77/MSF/WWVB DST-change + leap-announcement bits, and the leap-second
   minute fix (#20).** Spec-faithfulness + a real bug, all dry-run-testable. (§2.2)
6. **Add BPC (China) (#35).** The one new station that fits the AM model and is
   actively requested. (§2.1)
7. **Optional on-off-keying mode (#34) and alternate clock-source selection.**
   Together they simplify the hardware *and* kill the "must be headless" caveat —
   both small `rpi-control.cc`/config changes with outsized UX wins. (§2.5)
8. **CI + a `.deb`/systemd packaging pass.** Turns it into a real
   `apt-install-and-enable` appliance. (§2.4)
9. **Status LED + NTP-readiness gate.** Cheap robustness for an unattended box;
   prevents broadcasting a wrong time. (§2.3)

### Do later / opportunistic

- **Pi 4 (BCM2711) support** — good for reach; well-understood thanks to
  harlock974; not needed for the Zero W target. (§2.5)
- **Pi Zero 2 W: test + document** (probably already works). (§2.5)
- **JJY minutes 15/45 service-announcement frames** — completeness only. (§2.2)
- **Observability/metrics file, self-test, "sync now" trigger, auto station
  detection** — nice appliance polish. (§2.3, §2.6)
- **Antenna/amp documentation** (reference the companion project; lead with
  legality). (§2.5)

### Probably not worth it (and why)

| Idea | Why to skip |
|---|---|
| **TDF / ALS162 (France)** | Phase-modulated, not AM; the GPCLK hardware path can't produce it, and almost nobody needs a *transmitted* ALS162. High effort, tiny audience. (§2.1) |
| **RBU / RTZ (Russia)** | Sub-carrier tone keying (100 Hz/312.5 Hz), not amplitude on/off — same hardware mismatch, even more niche. (§2.1) |
| **DCF77 phase modulation (PRN)** | Only PZF/high-precision receivers use it; consumer clocks ignore it entirely; requires a different carrier-generation method. (§2.2) |
| **DCF77 weather / Meteotime bits (#28)** | Encrypted (modified 40-bit DES, undocumented S/P-boxes, license-locked) **and** the payload is external commercial weather data — not something a clock-time transmitter can or should synthesise. (§2.2) |
| **Pi 5 (RP1) support** | A whole new hardware backend (RP1, not BCM clock-manager); real work for a platform that is overkill for this appliance and not the deployment target. Revisit only if Zero W / older Pis become unavailable. (§2.5) |
| **HBG (Switzerland)** | Station decommissioned in 2011 — educational mode at best. (§2.1) |
| **Simultaneous multi-carrier transmission** | One GPCLK = one carrier; true simultaneity would need multiple clock outputs/hardware and offers little over time-division scheduling. (§2.3) |

### Architecture fit recap

Almost everything in the "do first" list lands in exactly the places the design
already anticipates:

- **New stations & all protocol-completeness work** → a `TimeSignalSource`
  subclass / edits to `src/*-source.cc`, plus a line in
  `CreateTimeSourceFromName()` and `usage()` in `src/txtempus.cc`. No
  hardware-layer change. Validated by the `-n` golden tests.
- **OOK mode, clock-source selection, Pi 4/Pi 5** → the `HardwareControl` pimpl:
  small edits to `src/rpi-control.cc` / `kClockSources[]` for OOK/clock-source/Pi
  4; a brand-new `include/rpi5/...` + `cmake/rpi5-control.cmake` for Pi 5,
  registered in `SUPPORTED_PLATFORMS` — i.e. the documented "add a platform"
  recipe in `include/hardware-control.h`.
- **Config, scheduling, status LED, NTP gate, metrics** → `src/txtempus.cc`
  (`main()` / the transmit loop) plus a thin config parser and the
  systemd/packaging layer; the `TimeSignalSource` factory already makes
  per-window station switching a one-liner.

The single most leveraged move is **#1 (golden tests on the dry-run)**: it is
free at runtime, runs in CI without a Pi, and de-risks every protocol change that
follows.
