#!/bin/bash
#
# txtempus appliance installer (idempotent / upgrade-safe).
#
# Installs the config, helper scripts, systemd units, and the web UI for a
# Raspberry Pi time-signal appliance. Run as root from anywhere (paths are
# resolved relative to this script, so the old "must cd into build/" footgun is
# gone). Safe to re-run to upgrade: it stops a running install first, replaces
# files, migrates an existing schedule, and flags legacy cron jobs.
#
#   sudo ./deploy/install.sh                 # install or upgrade
#   sudo ./deploy/install.sh --purge-cron    # also remove old txtempus cron lines
#
# Ensures the transmitter binary is in place too: it uses an already-installed
# /usr/bin/txtempus, else a prebuilt build/txtempus, else builds it when cmake/make
# are available. So a single `install.sh` is enough; no separate `make install`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BIN_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"
CONF_DST="/etc/txtempus.conf"
ALL_UNITS="txtempus-web.service txtempus-oneshot.service txtempus-scheduler.timer txtempus-scheduler.service"

PURGE_CRON=0
for arg in "$@"; do
    case "$arg" in
        --purge-cron) PURGE_CRON=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root (writes /etc and /usr/local/bin)." >&2
    exit 1
fi

# True only when actually booted with systemd (the binary can exist in
# containers where systemd is not PID 1, where systemctl calls fail).
have_systemd() { [ -d /run/systemd/system ]; }

echo "txtempus installer"
echo "  source : $REPO_DIR"
echo "  binary : /usr/bin/txtempus"
echo

# --- 0. Pre-flight: handle an existing / older installation --------------------

# Stop anything currently running (old OR new -- same unit names) so we can
# replace files safely. This is what makes re-running an upgrade graceful.
if have_systemd; then
    for u in $ALL_UNITS; do
        if systemctl is-active --quiet "$u" 2>/dev/null; then
            echo "Stopping running $u ..."
            systemctl stop "$u" 2>/dev/null || true
        fi
    done
fi

# If we're about to create a fresh config, migrate any schedule from a previous
# install (its timer's OnCalendar times) so we don't lose it.
MIGRATED_TIMES=""
if [[ ! -e "$CONF_DST" ]]; then
    MIGRATED_TIMES=$(grep -hoE '^OnCalendar=.*' \
        "$UNIT_DIR/txtempus-scheduler.timer" \
        "$UNIT_DIR/txtempus-scheduler.timer.d/"*.conf 2>/dev/null \
        | grep -oE '[0-2][0-9]:[0-5][0-9]' | sort -u | paste -sd, - || true)
    [[ -n "$MIGRATED_TIMES" ]] && \
        echo "Migrating schedule from previous install: $MIGRATED_TIMES"
fi

# Note when we're replacing the old (hard-coded-path) scheduler script.
if [[ -f "$BIN_DIR/txtempus-scheduler.sh" ]] && \
   grep -q '/home/mark' "$BIN_DIR/txtempus-scheduler.sh" 2>/dev/null; then
    echo "Replacing an old txtempus-scheduler.sh (it had a hard-coded path)."
fi

# Detect legacy cron entries that would double-broadcast alongside the timer.
CRON_FILES=$( { grep -lsE 'txtempus' /etc/crontab 2>/dev/null || true;
                grep -lsrE 'txtempus' /etc/cron.d 2>/dev/null || true; } | sort -u)
ROOT_CRON=0
if crontab -l 2>/dev/null | grep -q 'txtempus'; then ROOT_CRON=1; fi

# --- 1. Config (preserve existing settings; seed migrated schedule if new) -----
if [[ -e "$CONF_DST" ]]; then
    echo "Keeping existing $CONF_DST (not overwriting your settings)."
else
    echo "Installing default config to $CONF_DST"
    install -m 0644 "$SCRIPT_DIR/txtempus.conf" "$CONF_DST"
    if [[ -n "$MIGRATED_TIMES" ]]; then
        sed -i "s/^SCHEDULE_TIMES=.*/SCHEDULE_TIMES=$MIGRATED_TIMES/" "$CONF_DST"
    fi
fi

# Watch-guide database (preserve any watches the user added).
WATCHES_DST="/etc/txtempus-watches.json"
if [[ -e "$WATCHES_DST" ]]; then
    echo "Keeping existing $WATCHES_DST (your watch additions are preserved)."
else
    echo "Installing watch-guide database to $WATCHES_DST"
    install -m 0644 "$REPO_DIR/web/watches.json" "$WATCHES_DST"
fi

# --- 1b. Transmitter binary ---------------------------------------------------
# The appliance is useless without /usr/bin/txtempus -- the oneshot/scheduler
# units and the scheduler script all exec it from there. Install it here so a
# single install.sh suffices: prefer an existing copy, then a prebuilt
# build/txtempus, then build it when a toolchain is present.
BIN_OK=1
BUILD_DIR="$REPO_DIR/build"
if [[ -x /usr/bin/txtempus ]]; then
    echo "Transmitter binary present: /usr/bin/txtempus"
elif [[ -x "$BUILD_DIR/txtempus" ]]; then
    echo "Installing prebuilt binary $BUILD_DIR/txtempus -> /usr/bin/txtempus"
    install -m 0755 "$BUILD_DIR/txtempus" /usr/bin/txtempus
elif command -v cmake >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
    echo "No /usr/bin/txtempus found -- building it (this can take a minute)..."
    if cmake -S "$REPO_DIR" -B "$BUILD_DIR" >/dev/null 2>&1 \
       && cmake --build "$BUILD_DIR" -j"$(nproc 2>/dev/null || echo 1)" >/dev/null 2>&1; then
        install -m 0755 "$BUILD_DIR/txtempus" /usr/bin/txtempus
        echo "Built and installed: /usr/bin/txtempus"
    else
        BIN_OK=0
        echo "WARNING: build failed. Build it by hand and re-run:"
        echo "         cmake -S $REPO_DIR -B $BUILD_DIR && cmake --build $BUILD_DIR"
    fi
else
    BIN_OK=0
    echo "WARNING: /usr/bin/txtempus is missing and there is no cmake/make to build it."
    echo "         sudo apt-get install -y build-essential cmake   # then re-run this installer"
fi

# --- 2. Helper scripts --------------------------------------------------------
echo "Installing helper scripts to $BIN_DIR"
install -m 0755 "$SCRIPT_DIR/txtempus-scheduler.sh" "$BIN_DIR/txtempus-scheduler.sh"
install -m 0755 "$SCRIPT_DIR/txtempus-control.sh"   "$BIN_DIR/txtempus-control.sh"

# --- 3. Web UI ----------------------------------------------------------------
echo "Installing web UI to $BIN_DIR/txtempus-web.py"
install -m 0755 "$REPO_DIR/web/txtempus-web.py" "$BIN_DIR/txtempus-web.py"

# --- 4. systemd units ---------------------------------------------------------
echo "Installing systemd units to $UNIT_DIR"
install -m 0644 "$SCRIPT_DIR/systemd/txtempus-scheduler.service" "$UNIT_DIR/"
install -m 0644 "$SCRIPT_DIR/systemd/txtempus-scheduler.timer"   "$UNIT_DIR/"
install -m 0644 "$SCRIPT_DIR/systemd/txtempus-oneshot.service"   "$UNIT_DIR/"
install -m 0644 "$SCRIPT_DIR/systemd/txtempus-web.service"       "$UNIT_DIR/"

# --- 5. Log rotation ----------------------------------------------------------
cat > /etc/logrotate.d/txtempus <<'EOF'
/var/log/txtempus-scheduler.log /var/log/txtempus-temp.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
}
EOF

# --- 6. Activate --------------------------------------------------------------
if have_systemd; then
    echo "Reloading systemd..."
    systemctl daemon-reload || echo "WARNING: daemon-reload failed"

    echo "Applying schedule from $CONF_DST..."
    "$BIN_DIR/txtempus-control.sh" apply-schedule || \
        echo "WARNING: apply-schedule failed (check SCHEDULE_TIMES in $CONF_DST)"

    echo "Enabling web UI..."
    systemctl enable --now txtempus-web.service || \
        echo "WARNING: could not start txtempus-web.service"
else
    echo "NOTE: systemd is not running here; skipped enabling units."
    echo "      On the Pi this step enables the timer and starts the web UI."
fi

# --- 7. Legacy cron handling --------------------------------------------------
if [[ -n "$CRON_FILES" || $ROOT_CRON -eq 1 ]]; then
    echo
    echo "WARNING: found legacy cron entries referencing txtempus -- these run"
    echo "         IN ADDITION to the new systemd schedule (double broadcasts):"
    [[ -n "$CRON_FILES" ]] && echo "         files: $CRON_FILES"
    [[ $ROOT_CRON -eq 1 ]] && echo "         root crontab"
    if [[ $PURGE_CRON -eq 1 ]]; then
        for f in $CRON_FILES; do
            sed -i '/txtempus/d' "$f" && echo "         cleaned $f"
        done
        if [[ $ROOT_CRON -eq 1 ]]; then
            (crontab -l 2>/dev/null | grep -v 'txtempus') | crontab - && \
                echo "         cleaned root crontab"
        fi
    else
        echo "         Re-run with --purge-cron to remove them automatically,"
        echo "         or edit them out by hand."
    fi
fi

# --- 8. Sanity check + summary ------------------------------------------------
if [[ ! -x /usr/bin/txtempus ]]; then
    echo
    echo "WARNING: /usr/bin/txtempus is still missing. The web UI will run, but"
    echo "         transmits will fail in the logs with"
    echo "         'error spawning txtempus: No such file or directory'."
    echo "         Provide the binary, then re-run this installer:"
    echo "         cd $REPO_DIR && cmake -S . -B build && cmake --build build"
    echo "         sudo install -m 0755 build/txtempus /usr/bin/txtempus"
fi

WEB_PORT_SHOW="$(. "$CONF_DST" 2>/dev/null; echo "${WEB_PORT:-8080}")"
echo
echo "Done. Web UI: http://<this-pi>:${WEB_PORT_SHOW}/"
echo "  Schedule : systemctl list-timers txtempus-scheduler.timer"
echo "  Logs     : journalctl -u txtempus-web.service -f"
echo "             journalctl -u txtempus-scheduler.service -f"
echo "  Uninstall: sudo $SCRIPT_DIR/uninstall.sh"
echo
echo "Hardening (optional, LAN security is relaxed by default): to run the web UI"
echo "as a non-root user, see the comments in txtempus-web.service."
