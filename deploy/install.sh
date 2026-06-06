#!/bin/bash
#
# txtempus appliance installer.
#
# Installs the config, helper scripts, systemd units, and the web UI for a
# Raspberry Pi time-signal appliance. Run as root from anywhere (paths are
# resolved relative to this script, so the old "must cd into build/" footgun is
# gone).
#
#   sudo ./deploy/install.sh
#
# Assumes the binary is already built+installed (`cd build && cmake .. && make &&
# sudo make install` -> /usr/bin/txtempus). A warning is printed if it is not.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BIN_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"
CONF_DST="/etc/txtempus.conf"

if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root (writes /etc and /usr/local/bin)." >&2
    exit 1
fi

echo "txtempus installer"
echo "  source : $REPO_DIR"
echo "  binary : /usr/bin/txtempus"
echo

# --- 1. Config (preserve existing settings) -----------------------------------
if [[ -e "$CONF_DST" ]]; then
    echo "Keeping existing $CONF_DST (not overwriting your settings)."
else
    echo "Installing default config to $CONF_DST"
    install -m 0644 "$SCRIPT_DIR/txtempus.conf" "$CONF_DST"
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
echo "Reloading systemd..."
systemctl daemon-reload

echo "Applying schedule from $CONF_DST..."
"$BIN_DIR/txtempus-control.sh" apply-schedule || \
    echo "WARNING: apply-schedule failed (check SCHEDULE_TIMES in $CONF_DST)"

echo "Enabling web UI..."
systemctl enable --now txtempus-web.service || \
    echo "WARNING: could not start txtempus-web.service"

# --- 7. Sanity check ----------------------------------------------------------
if [[ ! -x /usr/bin/txtempus ]]; then
    echo
    echo "NOTE: /usr/bin/txtempus not found. Build & install the binary:"
    echo "      cd $REPO_DIR && mkdir -p build && cd build && cmake .. && make && sudo make install"
fi

WEB_PORT_SHOW="$(. "$CONF_DST" 2>/dev/null; echo "${WEB_PORT:-8080}")"
echo
echo "Done. Web UI: http://<this-pi>:${WEB_PORT_SHOW}/"
echo "  Schedule : systemctl list-timers txtempus-scheduler.timer"
echo "  Logs     : journalctl -u txtempus-web.service -f"
echo "             journalctl -u txtempus-scheduler.service -f"
echo
echo "Hardening (optional, LAN security is relaxed by default): to run the web UI"
echo "as a non-root user, see the comments in txtempus-web.service."
