#!/usr/bin/env bash
# Records what the native Kindle reader does while you look words up: every LIPC event, D-Bus traffic,
# syslog lines, and which files get written. Needs SSH that runs while KOReader is closed: the dev
# Wi-Fi SSH extension (port 22, see docs/development.md).
#
#   KINDLE_HOST=192.168.1.50 scripts/native-capture.sh start          # then look words up in the native reader
#   KINDLE_HOST=192.168.1.50 scripts/native-capture.sh stop <outdir>  # stops and copies the logs to <outdir>
set -euo pipefail

host="root@${KINDLE_HOST:?Set KINDLE_HOST to the Kindle IP address}"
export SSH_PORT="${KINDLE_PORT:-22}"
ssh() { command ssh -p "$SSH_PORT" "$@"; }
vocab=/mnt/us/system/vocabulary/vocab.db

case "${1:-}" in
start)
    ssh "$host" "sh -s" <<SH
mkdir -p /tmp/cap && cd /tmp/cap && rm -f ./*.log ./*.pid ./*.txt && touch marker
sqlite3 $vocab "select count(*) from LOOKUPS" > lookups_before.txt 2>&1
lipc-probe -l > sources.txt
# Only our own PIDs are recorded and killed: the system runs other lipc-wait-event processes.
nohup lipc-wait-event -m -t -l "*" < sources.txt > lipc.log 2>&1 &
echo \$! >> capture.pid
nohup dbus-monitor --system > dbus.log 2>&1 &
echo \$! >> capture.pid
nohup tail -n 0 -F /var/log/messages > messages.log 2>&1 &
echo \$! >> capture.pid
# Safety net: stop the capture after 30 minutes even if "stop" is never called.
nohup sh -c 'sleep 1800; kill \$(cat /tmp/cap/capture.pid) 2>/dev/null' > /dev/null 2>&1 &
echo "capturing on the Kindle in /tmp/cap"
SH
    ;;
stop)
    out="${2:?Usage: $0 stop <outdir>}"
    mkdir -p "$out"
    ssh "$host" "sh -s" <<SH
cd /tmp/cap
kill \$(cat capture.pid) 2>/dev/null || true
sqlite3 $vocab "select count(*) from LOOKUPS" > lookups_after.txt 2>&1
find /mnt/us /var/local /var/tmp /tmp -newer marker -type f 2>/dev/null | grep -v '^/tmp/cap/' > changed_files.txt || true
SH
    ssh "$host" "tar -C /tmp/cap -cf - . && rm -rf /tmp/cap" | tar -C "$out" -xf -
    # IdentityService broadcasts the Amazon access token over LIPC/D-Bus: never keep it.
    LC_ALL=C sed -i '' -E 's/(Atza|Atzr|Atna)\|[^"[:space:]]+/\1|<redacted>/g' "$out"/*.log
    wc -l "$out"/*.log "$out"/*.txt
    ;;
*)
    echo "Usage: $0 start | stop <outdir>" >&2
    exit 1
    ;;
esac
