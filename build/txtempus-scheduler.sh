#!/bin/bash

# txtempus DCF77 Signal Scheduler Script
# Runs txtempus binary at specified times with temperature monitoring
# Author: Generated for Raspberry Pi DCF77 time signal broadcasting

set -euo pipefail

# Configuration
TXTEMPUS_PATH="/home/mark/txtempus/build/txtempus"
SIGNAL_TYPE="dcf77"
RUN_DURATION=20  # minutes
LOG_FILE="/var/log/txtempus-scheduler.log"
TEMP_LOG="/var/log/txtempus-temp.log"
PID_FILE="/var/run/txtempus.pid"
TEMP_MONITOR_PID_FILE="/var/run/txtempus-temp-monitor.pid"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "ERROR: $1"
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    log "Cleaning up processes..."
    
    # Kill txtempus if running
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log "Stopping txtempus process..."
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    
    # Kill temperature monitor if running
    if [[ -f "$TEMP_MONITOR_PID_FILE" ]] && kill -0 "$(cat "$TEMP_MONITOR_PID_FILE")" 2>/dev/null; then
        log "Stopping temperature monitor..."
        kill "$(cat "$TEMP_MONITOR_PID_FILE")" 2>/dev/null || true
        rm -f "$TEMP_MONITOR_PID_FILE"
    fi
}

# Temperature monitoring function
monitor_temperature() {
    local duration=$1
    local end_time=$((SECONDS + duration * 60))
    
    log "Starting temperature monitoring for $duration minutes"
    
    while [[ $SECONDS -lt $end_time ]]; do
        if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
            local temp=$(cat /sys/class/thermal/thermal_zone0/temp)
            local temp_c=$((temp / 1000))
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] CPU Temperature: ${temp_c}°C" >> "$TEMP_LOG"
            
            # Warning if temperature is high
            if [[ $temp_c -gt 70 ]]; then
                log "WARNING: High CPU temperature detected: ${temp_c}°C"
            fi
        else
            log "WARNING: Cannot read temperature sensor"
        fi
        
        sleep 30  # Check every 30 seconds
    done
    
    log "Temperature monitoring completed"
}

# NTP sync function
sync_ntp() {
    log "Synchronizing time with NTP server..."
    
    # Try different NTP sync methods
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl set-ntp true; then
            log "NTP sync enabled via timedatectl"
        else
            log "WARNING: Failed to enable NTP via timedatectl"
        fi
    elif command -v ntpdate >/dev/null 2>&1; then
        if ntpdate -s pool.ntp.org; then
            log "Time synchronized via ntpdate"
        else
            log "WARNING: Failed to sync time via ntpdate"
        fi
    elif command -v chronyd >/dev/null 2>&1; then
        if systemctl is-active --quiet chronyd; then
            chrony sources -v || log "WARNING: chrony sync check failed"
            log "Time sync via chronyd (already running)"
        else
            log "WARNING: chronyd service not running"
        fi
    else
        log "WARNING: No NTP client found (timedatectl, ntpdate, or chronyd)"
    fi
    
    log "Current system time: $(date)"
}

# Validate binary and permissions
validate_setup() {
    log "Validating setup..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
    
    # Check if binary exists and is executable
    if [[ ! -f "$TXTEMPUS_PATH" ]]; then
        error_exit "txtempus binary not found at $TXTEMPUS_PATH"
    fi
    
    if [[ ! -x "$TXTEMPUS_PATH" ]]; then
        error_exit "txtempus binary is not executable at $TXTEMPUS_PATH"
    fi
    
    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$(dirname "$TEMP_LOG")"
    
    log "Setup validation completed successfully"
}

# Run txtempus with monitoring
run_txtempus() {
    log "Starting txtempus broadcast (Signal: $SIGNAL_TYPE, Duration: $RUN_DURATION minutes)"
    
    # Start temperature monitoring in background
    monitor_temperature "$RUN_DURATION" &
    local temp_monitor_pid=$!
    echo "$temp_monitor_pid" > "$TEMP_MONITOR_PID_FILE"
    
    # Start txtempus in background
    "$TXTEMPUS_PATH" -s "$SIGNAL_TYPE" -r "$RUN_DURATION" &
    local txtempus_pid=$!
    echo "$txtempus_pid" > "$PID_FILE"
    
    log "txtempus started with PID: $txtempus_pid"
    log "Temperature monitor started with PID: $temp_monitor_pid"
    
    # Wait for txtempus to complete or timeout
    local timeout_seconds=$((RUN_DURATION * 60 + 60))  # Extra minute for safety
    local elapsed=0
    
    while kill -0 "$txtempus_pid" 2>/dev/null && [[ $elapsed -lt $timeout_seconds ]]; do
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    # Check if process completed normally or timed out
    if kill -0 "$txtempus_pid" 2>/dev/null; then
        log "WARNING: txtempus process exceeded timeout, terminating..."
        kill "$txtempus_pid" 2>/dev/null || true
        sleep 2
        kill -9 "$txtempus_pid" 2>/dev/null || true
    else
        log "txtempus process completed normally"
    fi
    
    # Wait for temperature monitor to finish
    wait "$temp_monitor_pid" 2>/dev/null || true
    
    # Cleanup PID files
    rm -f "$PID_FILE" "$TEMP_MONITOR_PID_FILE"
    
    log "txtempus broadcast session completed"
}

# Main execution function
main() {
    log "=== txtempus Scheduler Started ==="
    
    # Set up signal handlers for cleanup
    trap cleanup EXIT INT TERM
    
    # Validate setup
    validate_setup
    
    # Sync with NTP
    sync_ntp
    
    # Run txtempus
    run_txtempus
    
    log "=== txtempus Scheduler Completed ==="
}

# Check if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
