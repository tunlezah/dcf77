#!/usr/bin/env python3
"""BPC encoder self-test.

Decodes txtempus's own `-n` BPC dry-run envelope back into time fields and
checks it round-trips the input time, with valid markers, pulse widths, frame
numbers and parity.

IMPORTANT: this verifies the encoder is INTERNALLY consistent and deterministic
(it catches bugs in bit-packing, framing, parity, marker/width handling). It
does NOT prove conformance to the real BPC broadcast format, whose exact field
layout is reverse-engineered/tentative here -- only the official spec or a real
BPC receiver can confirm that. The decode below intentionally mirrors the
TENTATIVE layout in src/bpc-source.cc, so if that layout is corrected, update
this file's field offsets to match.
"""

import os
import re
import subprocess
import sys
from datetime import datetime, timedelta

BIN = sys.argv[1] if len(sys.argv) > 1 else "build/txtempus"
# The dry-run prints "\b\b\b:NN [envelope]"; backspaces are literal under capture,
# so search for the pattern rather than anchoring at start of line.
LINE_RE = re.compile(r":(\d{2}) \[([_#]+)\]")

TEST_TIMES = [
    "2026-06-07 14:30",   # PM
    "2026-01-01 00:00",   # midnight / New Year (12 AM)
    "2026-12-31 23:59",   # end of year, PM
    "2026-06-15 12:00",   # noon (12 PM)
    "2026-03-09 09:05",   # AM
    "2024-02-29 06:30",   # leap day
]


def run_bpc(t):
    env = dict(os.environ, TZ="UTC")
    p = subprocess.run([BIN, "-n", "-s", "BPC", "-t", t],
                       capture_output=True, text=True, env=env)
    if p.returncode != 0:
        raise RuntimeError(f"txtempus failed: {p.stderr.strip()}")
    return p.stdout + p.stderr


def parse_widths(text):
    """Return list of 60 leading-low widths in 100ms units (0 == marker)."""
    widths = [None] * 60
    for line in text.splitlines():
        m = LINE_RE.search(line)
        if not m:
            continue
        sec = int(m.group(1))
        env = m.group(2)
        lead = len(env) - len(env.lstrip("_"))  # leading '_' (100ms each)
        if 0 <= sec < 60:
            widths[sec] = lead
    return widths


def even_parity(x):
    p = 0
    while x:
        p ^= 1
        x &= x - 1
    return p


def decode_frame(widths, frame):
    base = frame * 20
    assert widths[base] == 0, f"frame {frame}: second {base} should be a marker (no reduction)"
    bits = 0
    for p in range(1, 20):
        w = widths[base + p]
        assert w is not None, f"missing second {base+p}"
        assert 1 <= w <= 4, f"second {base+p}: width {w} not a valid symbol (1..4)"
        sym = w - 1  # 100/200/300/400ms -> 0/1/2/3
        bits |= sym << (2 * (19 - p))
    return {
        "frame":   (bits >> 36) & 0x3,
        "ampm":    (bits >> 35) & 0x1,
        "hour12":  (bits >> 31) & 0xF,
        "minute":  (bits >> 25) & 0x3F,
        "weekday": (bits >> 22) & 0x7,
        "day":     (bits >> 17) & 0x1F,
        "month":   (bits >> 13) & 0xF,
        "year":    (bits >> 6) & 0x7F,
        "parity":  (bits >> 1) & 0x1,
        "parity_ok": ((bits >> 1) & 0x1) == even_parity(bits >> 2),
    }


def check(t):
    text = run_bpc(t)
    widths = parse_widths(text)
    dt = datetime.strptime(t, "%Y-%m-%d %H:%M")
    for frame in range(3):
        d = decode_frame(widths, frame)
        # Block start = same minute (offsets 0/20/40s), so fields match `dt`.
        hour24 = (d["hour12"] % 12) + (12 if d["ampm"] else 0)
        exp_wd = dt.weekday() + 1  # Mon=1 .. Sun=7
        errs = []
        if d["frame"] != frame: errs.append(f"frame {d['frame']}!={frame}")
        if hour24 != dt.hour:    errs.append(f"hour {hour24}!={dt.hour}")
        if d["minute"] != dt.minute: errs.append(f"min {d['minute']}!={dt.minute}")
        if d["weekday"] != exp_wd:   errs.append(f"wday {d['weekday']}!={exp_wd}")
        if d["day"] != dt.day:       errs.append(f"day {d['day']}!={dt.day}")
        if d["month"] != dt.month:   errs.append(f"mon {d['month']}!={dt.month}")
        if d["year"] != dt.year % 100: errs.append(f"year {d['year']}!={dt.year%100}")
        if not d["parity_ok"]:       errs.append("parity bad")
        if errs:
            return False, f"{t} frame {frame}: " + ", ".join(errs)
    return True, f"{t}: 3 frames OK (round-trip time, parity, markers, widths)"


def main():
    if not os.access(BIN, os.X_OK):
        print(f"binary not found/executable: {BIN}", file=sys.stderr)
        return 2
    ok_all = True
    for t in TEST_TIMES:
        try:
            ok, msg = check(t)
        except (AssertionError, RuntimeError) as e:
            ok, msg = False, f"{t}: {e}"
        print(("PASS " if ok else "FAIL ") + msg)
        ok_all = ok_all and ok
    print("BPC self-test passed." if ok_all else "BPC self-test FAILED.")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
