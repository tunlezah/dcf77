#!/bin/bash

# Setup script for txtempus systemd service and timer
# This creates the necessary systemd files for automated scheduling

set -euo pipefail

SCRIPT_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This setup script must be run as root"
    exit 1
fi

echo "Setting up txtempus systemd service and timer..."

# Create the service file
cat > "$SERVICE_DIR/txtempus-scheduler.service" << 'EOF'
[Unit]
Description=txtempus DCF77 Signal Broadcaster
After=network-online.target time-sync.target
Wants=network-online.target time-sync.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/txtempus-scheduler.sh
StandardOutput=journal
StandardError=journal
TimeoutStartSec=1500
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

# Create the timer file for multiple daily runs
cat > "$SERVICE_DIR/txtempus-scheduler.timer" << 'EOF'
[Unit]
Description=Run txtempus DCF77 broadcaster at scheduled times
Requires=txtempus-scheduler.service

[Timer]
# Run at 01:59, 02:59, and 03:59 (1 minute before 2am, 3am, 4am)
OnCalendar=*-*-* 01:59:00
OnCalendar=*-*-* 02:59:00
OnCalendar=*-*-* 03:59:00
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

# Copy the main script to the system location
echo "Copying txtempus-scheduler.sh to $SCRIPT_DIR..."
cp txtempus-scheduler.sh "$SCRIPT_DIR/"
chmod +x "$SCRIPT_DIR/txtempus-scheduler.sh"

# Create log rotation configuration
cat > "/etc/logrotate.d/txtempus" << 'EOF'
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

# Reload systemd and enable the timer
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling txtempus timer..."
systemctl enable txtempus-scheduler.timer

echo "Starting txtempus timer..."
systemctl start txtempus-scheduler.timer

# Show timer status
echo ""
echo "Timer status:"
systemctl status txtempus-scheduler.timer --no-pager

echo ""
echo "Next scheduled runs:"
systemctl list-timers txtempus-scheduler.timer --no-pager

echo ""
echo "Setup completed successfully!"
echo ""
echo "To check logs: journalctl -u txtempus-scheduler.service -f"
echo "To check timer status: systemctl status txtempus-scheduler.timer"
echo "To manually run now: systemctl start txtempus-scheduler.service"
echo "To stop the timer: systemctl stop txtempus-scheduler.timer"
echo "To disable the timer: systemctl disable txtempus-scheduler.timer"
