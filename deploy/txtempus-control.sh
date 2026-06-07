#!/bin/bash
#
# txtempus-control.sh -- the single privileged surface for controlling txtempus.
#
# The web UI (web/txtempus-web.py) calls ONLY this script for state-changing
# actions, so the web user needs sudo rights to just this one allow-listed
# script (see deploy/install.sh) rather than to systemctl/rm/etc. Read-only
# status and the (unprivileged) -n preview are done by the web server directly.
#
# Usage:
#   txtempus-control.sh start [STATION] [MINUTES] [ZONE]  # on-demand transmit
#   txtempus-control.sh stop                              # stop any transmit
#   txtempus-control.sh apply-schedule                    # regen timer from conf
#   txtempus-control.sh schedule on|off                   # enable/disable timer

set -euo pipefail

CONF_FILE="${TXTEMPUS_CONF:-/etc/txtempus.conf}"
# shellcheck source=/dev/null
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"

STATION="${STATION:-DCF77}"
RUN_DURATION="${RUN_DURATION:-10}"
ZONE_OFFSET="${ZONE_OFFSET:-0}"
SCHEDULE_TIMES="${SCHEDULE_TIMES:-01:59,02:59,03:59}"
SCHEDULE_ENABLED="${SCHEDULE_ENABLED:-true}"

ONESHOT_UNIT="txtempus-oneshot.service"
SCHED_UNIT="txtempus-scheduler.service"
TIMER_UNIT="txtempus-scheduler.timer"
ONESHOT_ENV="/run/txtempus/oneshot.env"
DROPIN_DIR="/etc/systemd/system/${TIMER_UNIT}.d"
DROPIN_FILE="${DROPIN_DIR}/schedule.conf"

VALID_STATIONS="DCF77 WWVB MSF JJY40 JJY60 BPC"

die() { echo "error: $*" >&2; exit 1; }

validate_station() {
    local s="$1"
    for v in $VALID_STATIONS; do [[ "$s" == "$v" ]] && return 0; done
    die "invalid station '$s' (expected one of: $VALID_STATIONS)"
}

validate_minutes() {
    [[ "$1" =~ ^[0-9]+$ ]] || die "minutes must be an integer"
    (( $1 >= 1 && $1 <= 120 )) || die "minutes out of range (1..120)"
}

validate_zone() {
    [[ "$1" =~ ^-?[0-9]+$ ]] || die "zone offset must be an integer (minutes)"
}

cmd_start() {
    local station="${1:-$STATION}"
    local minutes="${2:-$RUN_DURATION}"
    local zone="${3:-$ZONE_OFFSET}"
    validate_station "$station"
    validate_minutes "$minutes"
    validate_zone "$zone"

    # Per-run overrides for the oneshot unit (EnvironmentFile, later-wins).
    mkdir -p "$(dirname "$ONESHOT_ENV")"
    cat > "$ONESHOT_ENV" <<EOF
STATION=$station
RUN_DURATION=$minutes
ZONE_OFFSET=$zone
EOF
    systemctl start "$ONESHOT_UNIT"
    echo "started: $station for ${minutes}m (zone ${zone}m)"
}

cmd_stop() {
    # Stop both the on-demand and scheduled paths; ignore "not active".
    systemctl stop "$ONESHOT_UNIT" "$SCHED_UNIT" 2>/dev/null || true
    echo "stopped"
}

write_dropin() {
    mkdir -p "$DROPIN_DIR"
    {
        echo "# Managed by txtempus-control.sh from SCHEDULE_TIMES in $CONF_FILE."
        echo "# Do not edit by hand; changes are overwritten."
        echo "[Timer]"
        echo "OnCalendar="   # reset any inherited values first
        local IFS=','
        for t in $SCHEDULE_TIMES; do
            t="${t// /}"
            [[ -z "$t" ]] && continue
            [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
                || die "invalid schedule time '$t' (expected HH:MM)"
            echo "OnCalendar=*-*-* ${t}:00"
        done
    } > "$DROPIN_FILE"
}

cmd_apply_schedule() {
    write_dropin
    systemctl daemon-reload
    if [[ "$SCHEDULE_ENABLED" == "true" ]]; then
        # Timers report CanReload=no, so restart to pick up new OnCalendar lines.
        systemctl enable "$TIMER_UNIT" >/dev/null 2>&1 || true
        systemctl restart "$TIMER_UNIT"
        echo "schedule applied and enabled: $SCHEDULE_TIMES"
    else
        systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1 || true
        echo "schedule applied but disabled"
    fi
}

cmd_schedule() {
    case "${1:-}" in
        on)  systemctl enable --now "$TIMER_UNIT";  echo "schedule enabled" ;;
        off) systemctl disable --now "$TIMER_UNIT"; echo "schedule disabled" ;;
        *)   die "usage: schedule on|off" ;;
    esac
}

case "${1:-}" in
    start)          shift; cmd_start "$@" ;;
    stop)           cmd_stop ;;
    apply-schedule) cmd_apply_schedule ;;
    schedule)       shift; cmd_schedule "$@" ;;
    *) die "usage: $0 {start [STATION] [MINUTES] [ZONE]|stop|apply-schedule|schedule on|off}" ;;
esac
