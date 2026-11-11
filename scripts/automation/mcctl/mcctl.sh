#!/bin/bash
# Per-server control. Usage: mcctl {start|stop|restart|status|attach|list} [name]
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF=/etc/minecraft/servers.yaml
KEEPALIVE=/opt/minecraft/keepalive.sh

ACTION="${1:-list}"
NAME="${2:-}"

declare -A DIRS=()

die() { echo "$*" >&2; exit 1; }

command -v yq >/dev/null || die "yq (mikefarah v4) is required"
[[ -r "$CONF" ]] || die "Cannot read $CONF"

# Load servers from the YAML config and validate every entry.
while IFS=$'\t' read -r n d; do
    [[ "$n" =~ ^[a-z0-9_-]{1,32}$ ]] || die "Invalid server name in $CONF: '$n'"
    [[ "$d" == /* && -d "$d" ]]      || die "Bad or missing dir for '$n' in $CONF: '$d'"
    DIRS["$n"]="$d"
done < <(yq -r '.servers | to_entries[] | [.key, .value.dir] | @tsv' "$CONF")

valid() {
    [[ "$1" =~ ^[a-z0-9_-]{1,32}$ && -n "${DIRS[$1]+set}" ]] \
        || die "Unknown server '$1'. Known: ${!DIRS[*]}"
}

# Exact match on the session name (the part after the PID).
running() {
    screen -ls 2>/dev/null | awk -v n="$1" '
        { split($1, p, "."); if (p[2] == n) found = 1 }
        END { exit !found }'
}

start_server() {
    valid "$1"
    if running "$1"; then echo "$1 already running."; return 0; fi
    echo "Starting $1..."
    screen -dmS "$1" "$KEEPALIVE" "$1" "${DIRS[$1]}"
}

stop_server() {
    valid "$1"
    if ! running "$1"; then echo "$1 not running."; return 0; fi
    echo "Stopping $1..."
    # Graceful RCON stop if configured, else just quit the session.
    if command -v mc >/dev/null && mc "$1" "list" >/dev/null 2>&1; then
        mc "$1" "stop"
        for _ in $(seq 1 30); do running "$1" || break; sleep 1; done
    fi
    screen -S "$1" -X quit 2>/dev/null
    pkill -f "$KEEPALIVE $1 " 2>/dev/null
}

case "$ACTION" in
    list)
        for n in "${!DIRS[@]}"; do
            if running "$n"; then echo "  $n  RUNNING  (${DIRS[$n]})"
            else                  echo "  $n  stopped  (${DIRS[$n]})"
            fi
        done
        ;;
    start)   start_server "$NAME" ;;
    stop)    stop_server "$NAME" ;;
    restart) stop_server "$NAME"; sleep 2; start_server "$NAME" ;;
    status)
        valid "$NAME"
        if running "$NAME"; then
            id=$(screen -ls | awk -v n="$NAME" '{ split($1, p, "."); if (p[2] == n) print p[1] }')
            echo "$NAME is running (session $id)."
            pgrep -af "$KEEPALIVE $NAME " | grep -v grep
        else
            echo "$NAME is not running."
        fi
        ;;
    attach)
        valid "$NAME"
        running "$NAME" || die "$NAME not running."
        exec screen -r "$NAME"
        ;;
    *)
        die "Usage: mcctl {list|start|stop|restart|status|attach} [name]"
        ;;
esac

