#!/bin/bash
#
# Golden-output regression test for the time-signal encoders.
#
# Runs the root-free, hardware-free `-n` dry-run for each station at a fixed
# time and timezone, and compares the modulation envelope to committed expected
# output. This catches accidental changes to any protocol encoder without
# needing a Pi or a real clock. Great for CI.
#
#   test/run-golden.sh [path-to-txtempus]    # check (default: build/txtempus)
#   test/run-golden.sh --update [path]       # (re)generate the expected files
#
# TZ is pinned so output is identical on any machine. This is a regression
# lock on the *encoding*, not a statement about real local time / DST.

set -uo pipefail
cd "$(dirname "$0")/.."

UPDATE=0
if [[ "${1:-}" == "--update" ]]; then UPDATE=1; shift; fi
BIN="${1:-build/txtempus}"
GOLDEN_DIR="test/golden"
FIXED_TIME="2026-06-07 14:30"
export TZ=UTC
STATIONS="DCF77 WWVB MSF JJY40 JJY60 BPC"

if [[ ! -x "$BIN" ]]; then
    echo "txtempus binary not found/executable: $BIN" >&2
    echo "Build it first: cmake -S . -B build && cmake --build build" >&2
    exit 2
fi

mkdir -p "$GOLDEN_DIR"
fail=0
for s in $STATIONS; do
    out=$("$BIN" -n -s "$s" -t "$FIXED_TIME" 2>&1)
    exp="$GOLDEN_DIR/$s.txt"
    if [[ $UPDATE -eq 1 ]]; then
        printf '%s\n' "$out" > "$exp"
        echo "updated $exp"
        continue
    fi
    if [[ ! -f "$exp" ]]; then
        echo "MISSING $s  (no $exp; run with --update)"; fail=1; continue
    fi
    if diff -u "$exp" <(printf '%s\n' "$out") > /tmp/golden.diff 2>&1; then
        echo "PASS $s"
    else
        echo "FAIL $s"; sed 's/^/    /' /tmp/golden.diff; fail=1
    fi
done

if [[ $UPDATE -eq 1 ]]; then echo "Goldens written to $GOLDEN_DIR/."; exit 0; fi
if [[ $fail -eq 0 ]]; then echo "All golden tests passed."; else echo "Golden tests FAILED."; fi
exit $fail
