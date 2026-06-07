#!/bin/bash
#
# txtempus scheduled-broadcast runner.
#
# Runs the txtempus binary for a bounded time with NTP sync + CPU temperature
# monitoring. All tunables come from /etc/txtempus.conf (single source of truth)
# instead of being hard-coded -- this is what the systemd timer invokes nightly.

set -euo pipefail

# --- Configuration ------------------------------------------------------------
# Source the shared config if present, then fall back to sane defaults so the
# script still works on a bare checkout.
CONF_FILE="${TXTEMPUS_CONF:-/etc/txtempus.conf}"
# shellcheck source=/dev/null
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"

TXTEMPUS_PATH="${TXTEMPUS_PATH:-/usr/bin/txtempus}"
STATION="${STATION:-DCF77}"
RUN_DURATION="${RUN_DURATION:-10}"   # minutes
ZONE_OFFSET="${ZONE_OFFSET:-0}"      # minutes
TEMP_WARN_C="${TEMP_WARN_C:-70}"

LOG_FILE="${TXTEMPUS_LOG:-/var/log/txtempus-scheduler.log}"
TEMP_LOG="${TXTEMPUS_TEMP_LOG:-/var/log/txtempus-temp.log}"
PID_FILE="/run/txtempus.pid"
TEMP_MONITOR_PID_FILE="/run/txtempus-temp-monitor.pid"
LAST_RUN_FILE="${TXTEMPUS_LAST_RUN:-/run/txtempus/last-run}"

# --- Logging ------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    record_last_run "error" 1
    cleanup
    exit 1
}

record_last_run() {
    # $1 = result string, $2 = exit code
    mkdir -p "$(dirname "$LAST_RUN_FILE")" 2>/dev/null || true
    {
        echo "at=$(date -Iseconds)"
        echo "station=$STATION"
        echo "duration=$RUN_DURATION"
        echo "result=$1"
        echo "exit=$2"
    } > "$LAST_RUN_FILE" 2>/dev/null || true
}

cleanup() {
    log "Cleaning up processes..."
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log "Stopping txtempus process..."
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    if [[ -f "$TEMP_MONITOR_PID_FILE" ]] && kill -0 "$(cat "$TEMP_MONITOR_PID_FILE")" 2>/dev/null; then
        log "Stopping temperature monitor..."
        kill "$(cat "$TEMP_MONITOR_PID_FILE")" 2>/dev/null || true
        rm -f "$TEMP_MONITOR_PID_FILE"
    fi
}

# --- Temperature monitoring ---------------------------------------------------
monitor_temperature() {
    local duration=$1
    local end_time=$((SECONDS + duration * 60))
    log "Starting temperature monitoring for $duration minutes"
    while [[ $SECONDS -lt $end_time ]]; do
        if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
            local temp temp_c
            temp=$(cat /sys/class/thermal/thermal_zone0/temp)
            temp_c=$((temp / 1000))
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] CPU Temperature: ${temp_c}°C" >> "$TEMP_LOG"
            if [[ $temp_c -gt $TEMP_WARN_C ]]; then
                log "WARNING: High CPU temperature detected: ${temp_c}°C (limit ${TEMP_WARN_C}°C)"
            fi
        else
            log "WARNING: Cannot read temperature sensor"
        fi
        sleep 30
    done
    log "Temperature monitoring completed"
}

# --- NTP sync -----------------------------------------------------------------
sync_ntp() {
    log "Ensuring system time is NTP-disciplined..."
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true 2>/dev/null \
            && log "NTP enabled via timedatectl" \
            || log "WARNING: Failed to enable NTP via timedatectl"
    elif command -v chronyc >/dev/null 2>&1; then
        # Step the clock now so the very first transmitted minute is correct.
        chronyc makestep >/dev/null 2>&1 \
            && log "Clock stepped via chronyc makestep" \
            || log "WARNING: chronyc makestep failed"
    elif command -v ntpdate >/dev/null 2>&1; then
        ntpdate -s pool.ntp.org \
            && log "Time synchronized via ntpdate" \
            || log "WARNING: Failed to sync time via ntpdate"
    else
        log "WARNING: No NTP client found (timedatectl, chronyc, or ntpdate)"
    fi
    log "Current system time: $(date)"
}

# --- Validation ---------------------------------------------------------------
validate_setup() {
    log "Validating setup..."
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root (GPIO/clock access)"
    fi
    if [[ ! -x "$TXTEMPUS_PATH" ]]; then
        error_exit "txtempus binary not found or not executable at $TXTEMPUS_PATH (run 'sudo make install', or set TXTEMPUS_PATH in $CONF_FILE)"
    fi
    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$TEMP_LOG")" 2>/dev/null || true
    log "Setup valid: station=$STATION duration=${RUN_DURATION}m zone=${ZONE_OFFSET}m binary=$TXTEMPUS_PATH"
}

# --- Run ----------------------------------------------------------------------
run_txtempus() {
    log "Starting txtempus broadcast (station=$STATION, duration=${RUN_DURATION}m)"

    monitor_temperature "$RUN_DURATION" &
    local temp_monitor_pid=$!
    echo "$temp_monitor_pid" > "$TEMP_MONITOR_PID_FILE"

    "$TXTEMPUS_PATH" -s "$STATION" -r "$RUN_DURATION" -z "$ZONE_OFFSET" &
    local txtempus_pid=$!
    echo "$txtempus_pid" > "$PID_FILE"
    log "txtempus PID $txtempus_pid, temperature monitor PID $temp_monitor_pid"

    local timeout_seconds=$((RUN_DURATION * 60 + 60))
    local elapsed=0
    while kill -0 "$txtempus_pid" 2>/dev/null && [[ $elapsed -lt $timeout_seconds ]]; do
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if kill -0 "$txtempus_pid" 2>/dev/null; then
        log "WARNING: txtempus exceeded timeout, terminating..."
        kill "$txtempus_pid" 2>/dev/null || true
        sleep 2
        kill -9 "$txtempus_pid" 2>/dev/null || true
        record_last_run "timeout" 124
    else
        if wait "$txtempus_pid" 2>/dev/null; then
            record_last_run "completed" 0
        else
            record_last_run "completed" $?
        fi
    fi

    wait "$temp_monitor_pid" 2>/dev/null || true
    rm -f "$PID_FILE" "$TEMP_MONITOR_PID_FILE"
    log "txtempus broadcast session completed"
}

main() {
    log "=== txtempus Scheduler Started (conf: $CONF_FILE) ==="
    trap cleanup EXIT INT TERM
    validate_setup
    sync_ntp
    run_txtempus
    log "=== txtempus Scheduler Completed ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
