# txtempus — TODO / Review

> Companion to `summary.md`. This doc **compares the options/choices**, calls out
> **what works**, **what is flawed**, and gives a **prioritized fix list**.
> Target device: **Raspberry Pi Zero W** (single-core ARMv6, 512 MB), **LAN**
> (security secondary), **CPU/power is the main constraint**. Every concrete claim
> cites `path:line`. Each flagged item is marked **CONFIRMED** or **SPECULATIVE**.

---

## 1. Time-service comparison (DCF77 / WWVB / MSF / JJY40 / JJY60)

### 1.1 Encoding / modulation summary

| Service | Carrier | Modulation | Bit `0` / `1` / marker | Frame is for | `+60`? | Source |
|---|---|---|---|---|---|---|
| **DCF77** | 77.5 kHz | Amplitude **reduction** (LOW→HIGH each sec) | `0`=100 ms LOW, `1`=200 ms LOW; sec 59 = no reduction (minute mark) | **upcoming** minute | yes | `src/dcf77-source.cc:54-59` |
| **WWVB** | 60 kHz | Amplitude **reduction** | `0`=200 ms, `1`=500 ms, marker=800 ms LOW | **current** minute (UTC) | no | `src/wwvb-source.cc:52-58` |
| **MSF** | 60 kHz | **On-off keying** (carrier OFF) | per sec: 100 ms off + A-bit (100 ms) + B-bit (100 ms); sec 0 = 500 ms off marker | **upcoming** minute | yes | `src/msf-source.cc:56-67` |
| **JJY40** | 40 kHz | Amplitude reduction, **inverted** (HIGH→LOW) | `0`=800 ms HIGH, `1`=500 ms HIGH, marker=200 ms HIGH | **current** minute | no | `src/jjy-source.cc:60-66` |
| **JJY60** | 60 kHz | same as JJY40 | same | **current** minute | no | `src/jjy-source.cc:60-66`, `include/time-signal-source.h:95-100` |

The `+60` column is a **real correctness subtlety, and the code gets it right**:
DCF77 (`src/dcf77-source.cc:30`) and MSF (`src/msf-source.cc:30`) add 60 s because
their minute marker sits at the *leading edge of the next* minute, so the data must
describe the upcoming minute. WWVB and JJY do **not** add 60 s
(`src/wwvb-source.cc:28-32`, `src/jjy-source.cc:39-41`) because their `:00` marker
opens the minute the frame describes. **This is correct, not a bug.**

### 1.2 Robust vs. fragile

- **Most robust on this hardware: MSF.** On-off keying needs **no attenuation pin
  and no 560 Ω resistor** (`README.md:80-82`); `SetTxPower` just enables/disables the
  clock output (`src/rpi-control.cc:310-324`, OFF path at `:312-313`). Fewer analog
  parts, no resistor-divider tolerance, simplest wiring.
- **DCF77 / WWVB / JJY rely on the resistor-divider attenuation** via GPIO17
  (`src/rpi-control.cc:72`, `:315-323`). The HIGH/LOW ratio depends on 4.7 kΩ/560 Ω
  values (`README.md:68-70`); "precision not critical" but it is one more thing to get
  wrong, and the carrier never fully stops so a poorly-tuned divider can yield weak
  contrast.
- **JJY is the trickiest to reason about** because power is **inverted** vs. WWVB
  (HIGH carries the bit body, `src/jjy-source.cc:65`). Functionally fine, but the
  inversion is a common source of confusion.
- **DCF77 minute mark is a full second of *no* attenuation** (`src/dcf77-source.cc:55-56`,
  returns a single HIGH), which is exactly how receivers detect the gap — clean.

### 1.3 Encoding/parity correctness (cross-checked against the protocol comments)

All checks **pass**:

- **DCF77** parity: P1 over min bits 21-27 → bit 28; P2 over hour bits 29-34 → bit 35;
  P3 over date bits 36-57 → bit 58 (`src/dcf77-source.cc:48-50`). Matches the spec.
  DST flags are complementary (`:38-39`), start bit set (`:40`), and weekday maps
  Sunday `0`→`7` ISO (`:44`). **Correct.**
- **WWVB** uses padded-BCD with a zero between digits (`src/wwvb-source.cc:20-22`),
  big-endian from bit 59 (`:37-41`), leap-year bit (`:42`), and DST today/tomorrow
  (`:46-49`). **Correct.** Minor: variable named `breakdown` is **reused** for the
  local-time conversion (`:45`), overwriting the UTC breakdown — harmless because the
  UTC fields were already consumed, but mildly confusing.
- **JJY** PA1/PA2 parity (`src/jjy-source.cc:53-54`) over the hour and minute fields
  respectively; year uses plain BCD (`:27-29,:50`) while min/hour/yday use padded BCD
  (`:22-24`). Matches spec. Service-announcement minutes 15/45 deliberately skipped
  (`:56-57`) — fine for consumer clocks. **Correct.**
- **MSF** odd-parity helper (`src/msf-source.cc:21-27`) and the four parity bits over
  year/day/weekday/time fields (`:49-52`); the `a_bits_` minute-identifier trailer
  `0b1111110` (`:38`). **Correct.**

> **Net:** no bit-encoding or parity bugs found. The protocol layer is solid.

### 1.4 Platform support differences (rpi vs jetson)

| Aspect | Raspberry Pi | Nvidia Jetson |
|---|---|---|
| Carrier gen | GPCLK0 on **GPIO4**, BCM clock-manager divider, MASH=1 (`src/rpi-control.cc:109-172`, `:185-191`) | `GPIO::PWM` 50% duty (`include/jetson/hardware-control-implementation.h:69-77`) |
| Attenuation | GPIO17 pull-down / high-Z (`src/rpi-control.cc:72,:310-324`) | board attenuation pin via NPN (`.../jetson/...:99-121`) |
| Frequency accuracy | integer+fractional divider, chooses best of 4 sources to minimize error (`src/rpi-control.cc:114-137`) | **exact requested Hz assumed** — returns `frequency_hertz` unchanged (`.../jetson/...:69-77`); real accuracy depends on the PWM driver and is not measured |
| Model gaps | **Pi 4 (BCM2711) does not work** (`src/rpi-control.cc:246-250`); HDMI source drifts | **TX1/TX2 unsupported** (no PWM pin) (`.../jetson/...:45-49`) |
| Maturity | primary, tested Pi3 / Pi Zero W (`README.md:24-27`) | **experimental**, tested only Jetson Nano (`README.md:29-31`) |

For the stated Pi Zero W target, the **rpi** path is the one that matters; Jetson is
out of scope but worth knowing the carrier-accuracy story is weaker there.

---

## 2. What works well (preserve these)

- **Clean protocol/hardware separation via pimpl.** `TimeSignalSource` is fully
  portable (`include/time-signal-source.h:32-110`); hardware hidden behind
  `HardwareControl` + `Implementation` (`include/hardware-control.h:25-58`,
  `src/hardware-control.cc:21-27`). Adding a station or platform is documented inline
  (`include/hardware-control.h:27-34`). Genuinely easy to extend.
- **Correct, well-commented encoders** for five station variants across four regions
  (see §1.3). Comments cite the Wikipedia/spec source per file.
- **Accurate timing approach.** Absolute-time sleeps to each second boundary using
  `clock_nanosleep(CLOCK_REALTIME, TIMER_ABSTIME)` (`src/txtempus.cc:49-52,:206-221`),
  with per-second `tv_nsec` reset (`:208`) so intra-second transitions don't drift.
  Under `SCHED_FIFO` (`:189-191`) this is the right design for jitter-sensitive output.
- **Excellent `-n` dry-run.** Renders the per-second envelope as `_`/`#` ASCII without
  root or Pi hardware (`src/txtempus.cc:85-101,:163-167,:222`). Great for validating
  protocols and for CI later. Preserve.
- **Smart clock-source selection.** Iterates PLLC/PLLD/HDMI/oscillator and picks the
  lowest-error integer+fractional divider (`src/rpi-control.cc:114-137`), yielding
  e.g. 77500.003 Hz for DCF77 (`README.md:42-44`).
- **Pi model auto-detection** from `/proc/cpuinfo` revision with sane fallbacks
  (`src/rpi-control.cc:211-269`), including Zero W and Zero 2 W (`:238-239,:242-243`).
- **Fork automation adds real operational value** (not in upstream): NTP sync with
  three fallbacks (`build/txtempus-scheduler.sh:77-105`), PID files + cleanup traps
  (`:30-47,:182`), timeout guard (`:150-166`), CPU-temp monitoring with a 70 °C warning
  (`:50-74`), and a systemd service+timer+logrotate installer
  (`build/txtempus-systemd-setup.sh:20-73`). The intent is right even where the wiring
  is buggy (§3).

---

## 3. Flaws / bugs / smells (CONFIRMED unless noted)

### 3.1 Repo hygiene

- **CONFIRMED — entire `build/` tree committed; no `.gitignore`.** 46 of 72 tracked
  files are build artifacts: object files (`build/CMakeFiles/txtempus.dir/src/*.cc.o`),
  two `a.out` probes, CMake cache, `compile_commands.json`, and the compiled binary
  `build/txtempus`. History is a single commit `467ddcf "Add files via upload"`. No
  `.gitignore` exists.
  **Impact:** bloated repo; merge conflicts on binaries; stale artifacts mistaken for
  current. Worse: `build/CMakeCache.txt` bakes in
  `CMAKE_HOME_DIRECTORY:INTERNAL=/home/mark/txtempus` and
  `CMAKE_CACHEFILE_DIR:INTERNAL=/home/mark/txtempus/build`, so a fresh `cd build && make`
  on another machine reuses **someone else's absolute paths** and can fail confusingly.
  The committed `build/txtempus` is ARM EABI5 (so at least Pi-targeted), but shipping a
  binary in git is still wrong.
- **CONFIRMED — fork scripts live *inside* `build/`** (`build/txtempus-scheduler.sh`,
  `build/txtempus-systemd-setup.sh`). They are hand-written source, not generated, yet
  sit in the throwaway output dir — they will be deleted by any `rm -rf build`. They
  belong in a tracked `scripts/` (or `deploy/`) directory.

### 3.2 Scheduler / systemd / README inconsistencies

- **CONFIRMED — hardcoded user path to the *build tree* binary.**
  `build/txtempus-scheduler.sh:10`: `TXTEMPUS_PATH="/home/mark/txtempus/build/txtempus"`.
  This is user `mark`-specific **and** points at the build tree, not the installed
  `/usr/bin/txtempus` that `make install` produces (`CMakeLists.txt:11,:44`) and that
  the README assumes (`README.md:278,:281-282`). On any other machine the scheduler
  fails its own validation (`build/txtempus-scheduler.sh:117-119`).
- **CONFIRMED — three different run schedules/durations across the three sources:**
  - README cron: **`-r 10`**, at **:57**, twice (2 am/3 am) (`README.md:275-278`).
  - Scheduler script: **`RUN_DURATION=20`** (`build/txtempus-scheduler.sh:12`), used at
    `:142`.
  - systemd timer: **:59 three times** (01:59/02:59/03:59) (`build/txtempus-systemd-setup.sh:46-49`).
  Nothing reconciles 10 vs 20 minutes, :57 vs :59, or twice vs thrice. Pick one source
  of truth.
- **CONFIRMED — systemd installer uses a relative `cp`.**
  `build/txtempus-systemd-setup.sh:59`: `cp txtempus-scheduler.sh "$SCRIPT_DIR/"` only
  works if you happen to `cd` into the script's directory first. There is no path
  resolution (`$(dirname "$0")`).
- **CONFIRMED — `chrony` typo / dead branch.** `build/txtempus-scheduler.sh:95` calls
  `chrony sources -v` — the binary is `chronyc`, not `chrony`. Under `set -euo pipefail`
  (`:7`) this branch only runs when `chronyd` is already active (`:94`), and the `|| log`
  swallows the error, so it is mostly cosmetic, but it never does what it claims.
- **SPECULATIVE (minor) — duplicated NTP logic.** `timedatectl set-ntp true`
  (`build/txtempus-scheduler.sh:81-86`) only *enables* NTP; it does not *step* the
  clock before transmit. If the clock is far off at wake, the first run can transmit a
  wrong time until `ntpd`/`chrony` converges. For a nightly appliance this is usually
  fine (clock stays disciplined) but worth a `chronyc makestep` / `ntpd -gq` on cold
  boot.

### 3.3 Platform / RF caveats

- **CONFIRMED — Pi 4 (BCM2711) frequency generation does not work.** Code detects Pi 4,
  warns, and proceeds anyway (`src/rpi-control.cc:246-250`); README confirms
  (`README.md:247-249`). For the Pi Zero W target this is **not blocking**, but the
  binary still *runs* on a Pi 4 and silently emits a wrong/no carrier. Should hard-fail
  or at least be loud.
- **CONFIRMED — HDMI clock source drifts if a monitor is connected.** The 216 MHz HDMI
  source is in the candidate list (`src/rpi-control.cc:117`) and can be chosen; if a
  monitor changes that clock, the carrier shifts (`README.md:188-197`). Mitigation today
  is purely procedural ("run headless"). A `--clock-source` flag to exclude HDMI would
  remove the footgun; this is the upstream-suggested fix (`README.md:194-196`).

### 3.4 Main-loop / synthesis robustness

- **CONFIRMED — first (partial) minute is fast-forwarded / garbled.** `minute_start`
  starts at `now` truncated to the minute (`src/txtempus.cc:139,:196`). If the program
  starts mid-minute, the already-elapsed seconds have past `target_wait` times, so
  `clock_nanosleep(TIMER_ABSTIME)` (`:51`) returns immediately and the loop blasts
  through those seconds, toggling `SetTxPower` with no spacing. The **next** full minute
  is correct, so receivers (which wait for a clean minute marker) recover — but with
  `-r N` you effectively lose the first minute. The README cron starting at `:57`
  (`README.md:278`) implicitly depends on getting a whole clean minute. Worth skipping
  to the next full minute, or documenting `-r` should account for it.
- **CONFIRMED — `sched_setscheduler` return value ignored.**
  `src/txtempus.cc:191`. If it fails (not root / no `CAP_SYS_NICE`), the program
  continues at normal priority and timing silently degrades. Should check and at least
  warn.
- **CONFIRMED — no `mlockall`.** Nothing locks memory (grep: only mention of scheduling
  is `src/txtempus.cc:191`). At `SCHED_FIFO` priority 99 a major page fault during a
  transmit window stalls a real-time thread; `mlockall(MCL_CURRENT|MCL_FUTURE)` is the
  standard companion to `SCHED_FIFO` and is cheap. **Real gap on a 512 MB device that
  may be under memory pressure.**
- **SPECULATIVE — priority 99 on a single-core Pi Zero W can starve the kernel.**
  `src/txtempus.cc:189-191` uses the maximum RT priority. On one ARMv6 core, a busy/
  spinning section at prio 99 can momentarily starve kernel housekeeping. The loop is
  sleep-bound (mostly blocked in `clock_nanosleep`), so in practice it is fine, but 99
  is higher than necessary; a priority in the 50-80 range is conventional and safer.
  Confirm before changing — it has worked in the field.
- **CONFIRMED — busy-ish `StopClock` spin.** `src/rpi-control.cc:178-182` polls
  `CLK_CTL_BUSY` with `usleep(10)`. Fine (runs once at shutdown), noted only for
  completeness.

### 3.5 Configuration / ergonomics

- **CONFIRMED — no config file; everything is CLI flags or hardcoded.** Options parsed
  in `src/txtempus.cc:145-171`; deployment knobs are baked into the bash script
  (`build/txtempus-scheduler.sh:10-16`). Changing station/duration/schedule means
  editing source. For an appliance, a tiny `/etc/txtempus.conf` (shell-sourced
  `KEY=VALUE`) read by the scheduler is the lightweight fix — no new dependency.
- **CONFIRMED — hardcoded GPIO pins.** Carrier is GPIO4 (`src/rpi-control.cc:187,:189`,
  and GPCLK0 is physically tied to that pinmux ALT0), attenuation is GPIO17
  (`src/rpi-control.cc:72`). GPIO4/GPCLK0 is a genuine hardware constraint (not freely
  movable), but **GPIO17 is arbitrary** and could be a `#define`/flag. Low priority for
  a fixed board.
- **CONFIRMED — README points at the upstream repo for cloning.**
  `README.md:141`: `git clone https://github.com/hzeller/txtempus.git`, and the
  "very wrong frequency" / timezone links point at `hzeller` issues (`README.md:61-62,
  :196-197,:299`). Cloning that gives upstream, **not** this fork (no `build/` scripts).
  Update to `tunlezah/dcf77` and document the scheduler/systemd workflow.
- **CONFIRMED — no tests, no CI.** No test files, no `.github/`, no workflow (verified).
  The `-n` dry-run is a ready-made oracle for a golden-output test that needs neither
  root nor a Pi.

### 3.6 Documented limitations — do they matter for consumer clocks?

| Limitation | Where | Matters? |
|---|---|---|
| No DST-change **announcement** bit (the "change imminent" flag) | `README.md:240-243` | **Mostly no.** The *current* DST state **is** sent (DCF77 `:38-39`, WWVB `:48-49`, MSF `:53`), so clocks display correct local time. Only the pre-announcement hour around a switch is unset; consumer clocks resync nightly and self-correct. Low priority. |
| No leap-second handling | `README.md:240-243`, `include/time-signal-source.h:59-61` | **No, in practice.** Leap seconds are rare and the device resyncs from NTP nightly; a one-off second of skew at the boundary is invisible to a watch. Skip. |
| No phase modulation | `README.md:245` | **No.** Consumer clocks decode the AM envelope; phase modulation is for high-end/scientific receivers. Skip. |
| JJY service-announcement minutes 15/45 | `src/jjy-source.cc:56-57` | **No.** Consumer clocks ignore. Skip. |

> Verdict: the "missing protocol features" are correctly judged non-issues for the
> stated use case. **Do not spend effort here.** The real problems are repo hygiene,
> the broken scheduler wiring, and a couple of robustness gaps (`mlockall`, error
> checks, first-minute).

---

## 4. Prioritized fix list

Effort: **S** ≈ <1 h, **M** ≈ a few hours, **L** ≈ a day+.

### P0 — correctness / blocking (deployment is broken without these)

| # | Problem | Fix | Effort | Risk |
|---|---|---|---|---|
| P0-1 | Scheduler hardcodes `/home/mark/.../build/txtempus` (`build/txtempus-scheduler.sh:10`) — wrong on every other machine and points at the build tree, not the install. | Default `TXTEMPUS_PATH=/usr/bin/txtempus`; allow override via env/config (§P1-3). Run `sudo make install` first (`CMakeLists.txt:44`). | S | None. |
| P0-2 | Reconcile the **three** divergent schedules/durations: README `-r 10`@:57×2 (`README.md:275-278`), script `RUN_DURATION=20` (`build/txtempus-scheduler.sh:12`), systemd :59×3 (`build/txtempus-systemd-setup.sh:46-49`). | Choose one (e.g. `-r 12` starting ~2 min before the clock's listen time, matching the actual watch schedule) and make README + script + timer agree. | S | Need the real listen times of the target clock; wrong window = clock never syncs. |
| P0-3 | systemd installer `cp txtempus-scheduler.sh` is CWD-relative (`build/txtempus-systemd-setup.sh:59`); fails unless run from the script dir. | Use `cp "$(dirname "$0")/txtempus-scheduler.sh" "$SCRIPT_DIR/"`. Same for any other relative reference. | S | None. |
| P0-4 | `git clone` in README targets upstream `hzeller` (`README.md:141`), which lacks the fork's scheduler/systemd assets users are told to run. | Point clone at `tunlezah/dcf77`; add a short "Deploy (scheduler + systemd)" section. | S | None. |

### P1 — should fix (correctness-adjacent robustness, repo health, deploy quality)

| # | Problem | Fix | Effort | Risk |
|---|---|---|---|---|
| P1-1 | `build/` (objects, `a.out`, binary, CMake cache w/ `/home/mark` paths, `compile_commands.json`) committed; no `.gitignore` (46/72 tracked files). | Add `.gitignore` (`/build/`, `*.o`, `a.out`, `compile_commands.json`); `git rm -r --cached build/`. (Parent handles the commit.) | S | History still holds blobs; acceptable on a LAN hobby repo. |
| P1-2 | Hand-written scripts live in throwaway `build/`; `rm -rf build` deletes them. | Move to tracked `scripts/` (or `deploy/`); update systemd installer paths. | S | Update the two `cp`/path references. |
| P1-3 | No config file — station/duration/schedule hardcoded (`build/txtempus-scheduler.sh:10-16`). | Source `/etc/txtempus.conf` (`KEY=VALUE`) for `TXTEMPUS_PATH`, `SIGNAL_TYPE`, `RUN_DURATION`. Shell-sourced; **no new dependency** (good for Pi Zero W). | S–M | None. |
| P1-4 | No `mlockall` despite `SCHED_FIFO` 99 (`src/txtempus.cc:189-191`); a page fault can stall the RT loop on a 512 MB device. | Add `mlockall(MCL_CURRENT|MCL_FUTURE)` after going RT; warn (don't abort) on failure. | S | Negligible RAM for this tiny process. |
| P1-5 | `sched_setscheduler` return ignored (`src/txtempus.cc:191`); silent timing degradation if not privileged. | Check return; if it fails, `fprintf(stderr, ...)` warning (still allow dry-run / best-effort). | S | None. |
| P1-6 | Pi 4 runs anyway and emits a bad/no carrier (`src/rpi-control.cc:246-250`). | Make Pi 4 a hard error (non-zero exit) unless an explicit `--force` flag is given. | S | Closes the door on a future Pi 4 fix; gate behind a flag. |
| P1-7 | HDMI (216 MHz) clock source can be auto-selected and drifts with a monitor (`src/rpi-control.cc:117`; `README.md:188-197`). | Add `--clock-source` (or exclude HDMI by default); skip the HDMI entry unless opted in. | S–M | Excluding HDMI may slightly raise frequency error for some carriers — verify error stays within receiver tolerance. |
| P1-8 | `chrony sources` typo (`build/txtempus-scheduler.sh:95`) — wrong binary name (`chronyc`), branch never works as intended. | Use `chronyc -n sources` (or `chronyc makestep` to actually step the clock pre-transmit). | S | None. |

### P2 — nice-to-have / polish

| # | Problem | Fix | Effort | Risk |
|---|---|---|---|---|
| P2-1 | First partial minute is fast-forwarded/garbled (`src/txtempus.cc:139,:196,:51`). | Start `minute_start` at the **next** full minute (or skip emitting until the first boundary) so every transmitted minute is clean; note `-r` semantics. | S–M | Adds up to ~59 s startup latency; fine for a nightly run, document it. |
| P2-2 | No tests / CI (verified absent). | Golden-output test driving `-n` dry-run for each service against a fixed `-t` time; run in a trivial GitHub Action (build + dry-run diff). Lightweight, **no Pi needed**. | M | None. Don't over-engineer — one workflow. |
| P2-3 | `RequestOutput`/`RequestInput` per-call `INP_GPIO`/`OUT_GPIO` loops on every `SetTxPower` (`src/rpi-control.cc:85-106,:310-324`). | Configure GPIO17 direction once at init; in the per-second hot path only set/clear the bit. Micro-optimization that also reduces register churn. | S | Behavioral change to pinmux timing — test on hardware. |
| P2-4 | Attenuation pin GPIO17 hardcoded (`src/rpi-control.cc:72`). | Promote to a `#define` or `--attenuation-gpio` flag. (GPIO4/GPCLK0 must stay — hardware-fixed.) | S | None. |
| P2-5 | Lower RT priority from 99 (`src/txtempus.cc:191`) to ~50-80 to be gentler on the single core. | Change constant; **verify timing on real hardware first**. | S | Could worsen jitter — measure before/after. SPECULATIVE benefit. |
| P2-6 | WWVB reuses `breakdown` for both UTC and local conversions (`src/wwvb-source.cc:32,:45`). | Use a separate local-time `tm` for clarity. | S | Cosmetic; current code is functionally correct. |
| P2-7 | Document the AM-only / DST-announcement / leap-second / phase limitations as **intentional and harmless for consumer clocks** (don't "fix" them). | One short README note. | S | None. |

---

## 5. Bottom line

- **Protocol layer is correct and well-structured** — no encoding/parity bugs across
  all five services (§1.3); the `+60` upcoming-vs-current-minute handling is right.
- **The suspected `tv_nsec` overflow in the main loop does NOT exist**: `tv_nsec` is
  reset every second (`src/txtempus.cc:208`) and the max intra-second accumulation is
  800 ms < 1 e9 ns, so it never overflows. Not a bug.
- **The documented "missing features"** (DST announcement, leap seconds, phase mod, JJY
  announce minutes) are **correctly judged non-issues** for consumer clocks — current
  DST state *is* transmitted. Don't spend effort there.
- **Real problems are operational, not algorithmic:** the scheduler is wired to one
  developer's machine and the build tree (P0-1), three docs disagree on schedule/
  duration (P0-2), the systemd installer's relative `cp` is fragile (P0-3), the README
  clones upstream (P0-4), the whole `build/` tree (incl. binary + `/home/mark` CMake
  cache) is committed with no `.gitignore` (P1-1/P1-2), and there are two cheap
  RT-robustness gaps (`mlockall` P1-4, ignored scheduler-error P1-5).
- **Keep it lightweight** for the Pi Zero W: a shell-sourced `/etc/txtempus.conf`
  (P1-3) and a single dry-run CI job (P2-2) are the right weight — no daemons,
  containers, or heavy frameworks.
