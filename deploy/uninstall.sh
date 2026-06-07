#!/bin/bash
#
# txtempus appliance uninstaller -- cleanly removes what install.sh added.
#
#   sudo ./deploy/uninstall.sh            # remove units/scripts/web, keep config
#   sudo ./deploy/uninstall.sh --purge    # also remove /etc/txtempus.conf
#
# The /usr/bin/txtempus binary (from `sudo make install`) is left in place.

set -euo pipefail

UNIT_DIR="/etc/systemd/system"
BIN_DIR="/usr/local/bin"
CONF="/etc/txtempus.conf"
ALL_UNITS="txtempus-web.service txtempus-oneshot.service txtempus-scheduler.timer txtempus-scheduler.service"

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "This uninstaller must be run as root." >&2
    exit 1
fi

if [ -d /run/systemd/system ]; then
    echo "Stopping and disabling units..."
    for u in $ALL_UNITS; do
        systemctl disable --now "$u" 2>/dev/null || true
    done
fi

echo "Removing systemd units..."
rm -f "$UNIT_DIR"/txtempus-web.service \
      "$UNIT_DIR"/txtempus-oneshot.service \
      "$UNIT_DIR"/txtempus-scheduler.service \
      "$UNIT_DIR"/txtempus-scheduler.timer
rm -rf "$UNIT_DIR"/txtempus-scheduler.timer.d

echo "Removing helper scripts and web UI..."
rm -f "$BIN_DIR"/txtempus-scheduler.sh \
      "$BIN_DIR"/txtempus-control.sh \
      "$BIN_DIR"/txtempus-web.py

echo "Removing logrotate config..."
rm -f /etc/logrotate.d/txtempus

# Best-effort runtime cleanup.
rm -rf /run/txtempus /run/txtempus.pid /run/txtempus-temp-monitor.pid 2>/dev/null || true

[ -d /run/systemd/system ] && systemctl daemon-reload 2>/dev/null || true

if [[ $PURGE -eq 1 ]]; then
    rm -f "$CONF"
    echo "Removed $CONF"
else
    echo "Kept $CONF (use --purge to remove it)."
fi

echo "Note: /usr/bin/txtempus (from 'make install') was left in place."
echo "Uninstalled."
